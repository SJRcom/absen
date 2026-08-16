
-- Roles
CREATE TYPE public.app_role AS ENUM ('admin', 'operator');

CREATE TABLE public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles TO authenticated;
GRANT ALL ON public.profiles TO service_role;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "profiles self read" ON public.profiles FOR SELECT TO authenticated USING (auth.uid() = id);
CREATE POLICY "profiles self upsert" ON public.profiles FOR INSERT TO authenticated WITH CHECK (auth.uid() = id);
CREATE POLICY "profiles self update" ON public.profiles FOR UPDATE TO authenticated USING (auth.uid() = id);

CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role app_role NOT NULL,
  UNIQUE (user_id, role)
);
GRANT SELECT ON public.user_roles TO authenticated;
GRANT ALL ON public.user_roles TO service_role;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "read own roles" ON public.user_roles FOR SELECT TO authenticated USING (auth.uid() = user_id);

CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role app_role)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role);
$$;

-- Auto create profile & grant first user as admin
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE user_count INT;
BEGIN
  INSERT INTO public.profiles (id, full_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email));
  SELECT COUNT(*) INTO user_count FROM auth.users;
  IF user_count = 1 THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'admin');
  ELSE
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'operator');
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Participants
CREATE TABLE public.participants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  card_uid TEXT NOT NULL UNIQUE,
  rate_multiplier NUMERIC(6,3) NOT NULL DEFAULT 1.000,
  balance NUMERIC(12,2) NOT NULL DEFAULT 0,
  note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.participants TO authenticated;
GRANT ALL ON public.participants TO service_role;
ALTER TABLE public.participants ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth read participants" ON public.participants FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth insert participants" ON public.participants FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "auth update participants" ON public.participants FOR UPDATE TO authenticated USING (true);
CREATE POLICY "admin delete participants" ON public.participants FOR DELETE TO authenticated USING (public.has_role(auth.uid(), 'admin'));

-- Fields
CREATE TABLE public.fields (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  base_price NUMERIC(12,2) NOT NULL,
  description TEXT,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.fields TO authenticated;
GRANT ALL ON public.fields TO service_role;
ALTER TABLE public.fields ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth read fields" ON public.fields FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth insert fields" ON public.fields FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "auth update fields" ON public.fields FOR UPDATE TO authenticated USING (true);
CREATE POLICY "admin delete fields" ON public.fields FOR DELETE TO authenticated USING (public.has_role(auth.uid(), 'admin'));

-- Transactions
CREATE TYPE public.tx_type AS ENUM ('attendance', 'topup', 'adjustment');

CREATE TABLE public.transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  participant_id UUID NOT NULL REFERENCES public.participants(id) ON DELETE CASCADE,
  field_id UUID REFERENCES public.fields(id) ON DELETE SET NULL,
  tx_type tx_type NOT NULL,
  amount NUMERIC(12,2) NOT NULL,
  balance_after NUMERIC(12,2) NOT NULL,
  operator_id UUID REFERENCES auth.users(id),
  note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.transactions TO authenticated;
GRANT ALL ON public.transactions TO service_role;
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth read transactions" ON public.transactions FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth insert transactions" ON public.transactions FOR INSERT TO authenticated WITH CHECK (true);

CREATE INDEX idx_tx_created ON public.transactions(created_at DESC);
CREATE INDEX idx_tx_participant ON public.transactions(participant_id);

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.set_updated_at() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;
CREATE TRIGGER trg_participants_updated BEFORE UPDATE ON public.participants FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_fields_updated BEFORE UPDATE ON public.fields FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Scan & pay RPC
CREATE OR REPLACE FUNCTION public.scan_and_pay(_card_uid TEXT, _field_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p RECORD; f RECORD; cost NUMERIC(12,2); new_balance NUMERIC(12,2); tx_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT * INTO p FROM public.participants WHERE card_uid = _card_uid FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terdaftar');
  END IF;
  SELECT * INTO f FROM public.fields WHERE id = _field_id AND active = true;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Lapangan tidak ditemukan');
  END IF;
  cost := ROUND(f.base_price * p.rate_multiplier, 2);
  IF p.balance < cost THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Saldo tidak cukup',
      'participant', to_jsonb(p), 'cost', cost);
  END IF;
  new_balance := p.balance - cost;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;
  INSERT INTO public.transactions (participant_id, field_id, tx_type, amount, balance_after, operator_id, note)
    VALUES (p.id, f.id, 'attendance', -cost, new_balance, auth.uid(), f.name)
    RETURNING id INTO tx_id;
  RETURN jsonb_build_object('ok', true, 'tx_id', tx_id, 'participant_name', p.name,
    'field_name', f.name, 'cost', cost, 'balance_after', new_balance);
END $$;

-- Top up RPC
CREATE OR REPLACE FUNCTION public.topup_balance(_participant_id UUID, _amount NUMERIC, _note TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p RECORD; new_balance NUMERIC(12,2);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF _amount <= 0 THEN RAISE EXCEPTION 'Jumlah harus > 0'; END IF;
  SELECT * INTO p FROM public.participants WHERE id = _participant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Peserta tidak ditemukan'; END IF;
  new_balance := p.balance + _amount;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;
  INSERT INTO public.transactions (participant_id, tx_type, amount, balance_after, operator_id, note)
    VALUES (p.id, 'topup', _amount, new_balance, auth.uid(), _note);
  RETURN jsonb_build_object('ok', true, 'balance_after', new_balance);
END $$;

GRANT EXECUTE ON FUNCTION public.scan_and_pay(TEXT, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.topup_balance(UUID, NUMERIC, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_role(UUID, app_role) TO authenticated;
