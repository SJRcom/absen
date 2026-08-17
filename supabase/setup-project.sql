-- ============================================================================
-- SETUP LENGKAP DATABASE — ABSENSI SJR (untuk proyek Supabase baru)
-- ============================================================================
-- Cara pakai:
--   1. Buka https://supabase.com/dashboard  →  pilih proyek Anda
--   2. Menu SQL Editor  →  New query
--   3. Tempel SELURUH isi file ini  →  Run
--   ⚠️ JANGAN dijalankan ulang setelah sukses. Statement CREATE TYPE /
--      CREATE TABLE tidak idempoten — run ulang akan error 42710 (type
--      sudah ada). Kalau ada error: jalankan query verifikasi di bawah
--      (cek 8 tabel + enum + 18 fungsi). Kalau lengkap, abaikan error.
--
-- Setelah ini selesai: akun pertama yang mendaftar via /auth otomatis
-- menjadi super_admin, akun berikutnya menjadi member.
-- ============================================================================

-- ===================== 20260723061914_8a5801fe =====================

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

-- ===================== 20260724005008_62908747 =====================

-- Harden set_updated_at with fixed search_path
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = public
AS $$ BEGIN NEW.updated_at = now(); RETURN NEW; END $$;

-- participants: admin-only read/write
DROP POLICY IF EXISTS "auth read participants" ON public.participants;
DROP POLICY IF EXISTS "auth insert participants" ON public.participants;
DROP POLICY IF EXISTS "auth update participants" ON public.participants;

CREATE POLICY "admin read participants" ON public.participants
  FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "admin insert participants" ON public.participants
  FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "admin update participants" ON public.participants
  FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- fields: keep read for authenticated (needed for scan), admin-only write
DROP POLICY IF EXISTS "auth insert fields" ON public.fields;
DROP POLICY IF EXISTS "auth update fields" ON public.fields;

CREATE POLICY "admin insert fields" ON public.fields
  FOR INSERT TO authenticated WITH CHECK (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "admin update fields" ON public.fields
  FOR UPDATE TO authenticated
  USING (public.has_role(auth.uid(), 'admin'))
  WITH CHECK (public.has_role(auth.uid(), 'admin'));

-- transactions: admin-only read; direct insert admin-only (regular flow via SECURITY DEFINER RPCs)
DROP POLICY IF EXISTS "auth read transactions" ON public.transactions;
DROP POLICY IF EXISTS "auth insert transactions" ON public.transactions;

CREATE POLICY "admin read transactions" ON public.transactions
  FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "admin insert transactions" ON public.transactions
  FOR INSERT TO authenticated
  WITH CHECK (public.has_role(auth.uid(), 'admin') AND operator_id = auth.uid());

-- Lock down SECURITY DEFINER functions: no anonymous execution
REVOKE ALL ON FUNCTION public.scan_and_pay(text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.topup_balance(uuid, numeric, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.has_role(uuid, public.app_role) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.scan_and_pay(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.topup_balance(uuid, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) TO authenticated;

-- ===================== 20260724005033_eef1cd9e =====================

REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.set_updated_at() FROM PUBLIC, anon;

-- ===================== 20260724013933_76390659 =====================

-- Enum posisi
CREATE TYPE public.event_position AS ENUM ('gk', 'player', 'reserve');

-- EVENTS
CREATE TABLE public.events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  field_id uuid NOT NULL REFERENCES public.fields(id) ON DELETE RESTRICT,
  event_date timestamptz NOT NULL DEFAULT now(),
  gk_price numeric(12,2) NOT NULL DEFAULT 0,
  player_price numeric(12,2) NOT NULL DEFAULT 0,
  reserve_price numeric(12,2) NOT NULL DEFAULT 0,
  gk_slots integer NOT NULL DEFAULT 1,
  player_slots integer NOT NULL DEFAULT 10,
  reserve_slots integer NOT NULL DEFAULT 3,
  status text NOT NULL DEFAULT 'open',
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT events_status_chk CHECK (status IN ('open','closed'))
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.events TO authenticated;
GRANT ALL ON public.events TO service_role;

ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "auth read events" ON public.events FOR SELECT TO authenticated USING (true);
CREATE POLICY "admin insert events" ON public.events FOR INSERT TO authenticated WITH CHECK (has_role(auth.uid(),'admin'));
CREATE POLICY "admin update events" ON public.events FOR UPDATE TO authenticated USING (has_role(auth.uid(),'admin')) WITH CHECK (has_role(auth.uid(),'admin'));
CREATE POLICY "admin delete events" ON public.events FOR DELETE TO authenticated USING (has_role(auth.uid(),'admin'));

CREATE TRIGGER events_set_updated_at BEFORE UPDATE ON public.events
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- EVENT PARTICIPANTS
CREATE TABLE public.event_participants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
  participant_id uuid NOT NULL REFERENCES public.participants(id) ON DELETE CASCADE,
  position public.event_position NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, participant_id)
);

CREATE INDEX event_participants_event_idx ON public.event_participants(event_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.event_participants TO authenticated;
GRANT ALL ON public.event_participants TO service_role;

ALTER TABLE public.event_participants ENABLE ROW LEVEL SECURITY;

CREATE POLICY "admin read event_participants" ON public.event_participants FOR SELECT TO authenticated USING (has_role(auth.uid(),'admin'));
CREATE POLICY "admin insert event_participants" ON public.event_participants FOR INSERT TO authenticated WITH CHECK (has_role(auth.uid(),'admin'));
CREATE POLICY "admin update event_participants" ON public.event_participants FOR UPDATE TO authenticated USING (has_role(auth.uid(),'admin')) WITH CHECK (has_role(auth.uid(),'admin'));
CREATE POLICY "admin delete event_participants" ON public.event_participants FOR DELETE TO authenticated USING (has_role(auth.uid(),'admin'));

-- Trigger enforce kuota per posisi
CREATE OR REPLACE FUNCTION public.enforce_event_slot()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ev RECORD; used INT; cap INT;
BEGIN
  SELECT * INTO ev FROM public.events WHERE id = NEW.event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Event tidak ditemukan'; END IF;
  SELECT COUNT(*) INTO used FROM public.event_participants
    WHERE event_id = NEW.event_id AND position = NEW.position
      AND (TG_OP = 'INSERT' OR id <> NEW.id);
  cap := CASE NEW.position
    WHEN 'gk' THEN ev.gk_slots
    WHEN 'player' THEN ev.player_slots
    WHEN 'reserve' THEN ev.reserve_slots
  END;
  IF used >= cap THEN
    RAISE EXCEPTION 'Kuota posisi % penuh (%/%)', NEW.position, used, cap;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER event_participants_slot_chk
BEFORE INSERT OR UPDATE ON public.event_participants
FOR EACH ROW EXECUTE FUNCTION public.enforce_event_slot();

-- Kolom event_id & position di transactions
ALTER TABLE public.transactions
  ADD COLUMN event_id uuid REFERENCES public.events(id) ON DELETE SET NULL,
  ADD COLUMN position public.event_position;

-- RPC scan_event_and_pay
CREATE OR REPLACE FUNCTION public.scan_event_and_pay(_card_uid text, _event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p RECORD; ev RECORD; ep RECORD; cost NUMERIC(12,2); new_balance NUMERIC(12,2); tx_id UUID; pos_label TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthorized'; END IF;

  SELECT * INTO p FROM public.participants WHERE card_uid = _card_uid FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terdaftar');
  END IF;

  SELECT * INTO ev FROM public.events WHERE id = _event_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Event tidak ditemukan');
  END IF;
  IF ev.status <> 'open' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Event sudah ditutup');
  END IF;

  SELECT * INTO ep FROM public.event_participants
    WHERE event_id = _event_id AND participant_id = p.id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Peserta belum terdaftar di event ini',
      'participant', to_jsonb(p));
  END IF;

  cost := CASE ep.position
    WHEN 'gk' THEN ev.gk_price
    WHEN 'player' THEN ev.player_price
    WHEN 'reserve' THEN ev.reserve_price
  END;
  pos_label := CASE ep.position
    WHEN 'gk' THEN 'Goal Keeper'
    WHEN 'player' THEN 'Pemain'
    WHEN 'reserve' THEN 'Cadangan'
  END;

  -- Cegah double-charge di event yang sama
  IF EXISTS (SELECT 1 FROM public.transactions
             WHERE event_id = _event_id AND participant_id = p.id AND tx_type = 'attendance') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Peserta sudah absen di event ini',
      'participant', to_jsonb(p));
  END IF;

  IF p.balance < cost THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Saldo tidak cukup',
      'participant', to_jsonb(p), 'cost', cost);
  END IF;

  new_balance := p.balance - cost;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;

  INSERT INTO public.transactions
    (participant_id, field_id, event_id, position, tx_type, amount, balance_after, operator_id, note)
  VALUES
    (p.id, ev.field_id, ev.id, ep.position, 'attendance', -cost, new_balance, auth.uid(),
     ev.name || ' · ' || pos_label)
  RETURNING id INTO tx_id;

  RETURN jsonb_build_object('ok', true, 'tx_id', tx_id, 'participant_name', p.name,
    'event_name', ev.name, 'position', ep.position, 'position_label', pos_label,
    'cost', cost, 'balance_after', new_balance);
END $$;

REVOKE ALL ON FUNCTION public.scan_event_and_pay(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.scan_event_and_pay(text, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.enforce_event_slot() FROM PUBLIC, anon, authenticated;

-- ===================== 20260802133422_49fad42b =====================

ALTER TABLE public.participants
  ADD COLUMN IF NOT EXISTS member_no TEXT,
  ADD COLUMN IF NOT EXISTS phone TEXT;

UPDATE public.participants p
SET member_no = 'MBR-' || LPAD(s.rn::text, 4, '0')
FROM (SELECT id, ROW_NUMBER() OVER (ORDER BY created_at) rn FROM public.participants) s
WHERE p.id = s.id AND p.member_no IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS participants_member_no_key ON public.participants (member_no) WHERE member_no IS NOT NULL;

CREATE OR REPLACE FUNCTION public.scan_member_and_pay(_member_no text, _field_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE uid TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT card_uid INTO uid FROM public.participants WHERE member_no = _member_no;
  IF uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Nomor member tidak terdaftar');
  END IF;
  RETURN public.scan_and_pay(uid, _field_id);
END $$;

CREATE OR REPLACE FUNCTION public.scan_member_event_and_pay(_member_no text, _event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE uid TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT card_uid INTO uid FROM public.participants WHERE member_no = _member_no;
  IF uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Nomor member tidak terdaftar');
  END IF;
  RETURN public.scan_event_and_pay(uid, _event_id);
END $$;

REVOKE EXECUTE ON FUNCTION public.scan_member_and_pay(text, uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.scan_member_event_and_pay(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.scan_member_and_pay(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.scan_member_event_and_pay(text, uuid) TO authenticated;

-- ===================== 20260803040936_b5c4d7e6 =====================

-- Products table
CREATE TABLE public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  category text NOT NULL DEFAULT 'merchandise',
  price numeric(12,2) NOT NULL DEFAULT 0,
  description text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.products TO authenticated;
GRANT ALL ON public.products TO service_role;

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

CREATE POLICY "auth read products" ON public.products FOR SELECT TO authenticated USING (true);
CREATE POLICY "admin insert products" ON public.products FOR INSERT TO authenticated WITH CHECK (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "admin update products" ON public.products FOR UPDATE TO authenticated USING (has_role(auth.uid(), 'admin'::app_role)) WITH CHECK (has_role(auth.uid(), 'admin'::app_role));
CREATE POLICY "admin delete products" ON public.products FOR DELETE TO authenticated USING (has_role(auth.uid(), 'admin'::app_role));

CREATE TRIGGER products_set_updated_at BEFORE UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- New transaction type + columns
ALTER TYPE tx_type ADD VALUE IF NOT EXISTS 'purchase';
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS product_id uuid REFERENCES public.products(id);
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS qty integer;

-- Seed contoh produk
INSERT INTO public.products (name, category, price, description) VALUES
  ('Jersey Home (Putih)', 'jersey', 175000, 'Jersey kandang warna putih'),
  ('Jersey Away (Kuning)', 'jersey', 175000, 'Jersey tandang warna kuning'),
  ('Jersey 3rd (Hitam)', 'jersey', 175000, 'Jersey ketiga warna hitam'),
  ('Es Teh', 'minuman', 5000, NULL),
  ('Jus Alfalah', 'minuman', 10000, NULL);

-- ===================== 20260803041013_d4940f87 =====================

CREATE OR REPLACE FUNCTION public.buy_product(_card_uid text, _product_id uuid, _qty integer DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p RECORD; pr RECORD; cost NUMERIC(12,2); new_balance NUMERIC(12,2); tx_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF _qty IS NULL OR _qty < 1 THEN RETURN jsonb_build_object('ok', false, 'error', 'Jumlah tidak valid'); END IF;

  SELECT * INTO p FROM public.participants WHERE card_uid = _card_uid FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terdaftar'); END IF;

  SELECT * INTO pr FROM public.products WHERE id = _product_id AND active = true;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Produk tidak ditemukan'); END IF;

  cost := ROUND(pr.price * _qty, 2);
  IF p.balance < cost THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Saldo tidak cukup', 'participant', to_jsonb(p), 'cost', cost);
  END IF;

  new_balance := p.balance - cost;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;

  INSERT INTO public.transactions (participant_id, product_id, qty, tx_type, amount, balance_after, operator_id, note)
  VALUES (p.id, pr.id, _qty, 'purchase', -cost, new_balance, auth.uid(), pr.name || ' x' || _qty)
  RETURNING id INTO tx_id;

  RETURN jsonb_build_object('ok', true, 'tx_id', tx_id, 'participant_name', p.name,
    'product_name', pr.name, 'qty', _qty, 'cost', cost, 'balance_after', new_balance);
END $$;

CREATE OR REPLACE FUNCTION public.buy_product_member(_member_no text, _product_id uuid, _qty integer DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT card_uid INTO uid FROM public.participants WHERE member_no = _member_no;
  IF uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Nomor member tidak terdaftar'); END IF;
  RETURN public.buy_product(uid, _product_id, _qty);
END $$;

REVOKE ALL ON FUNCTION public.buy_product(text, uuid, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.buy_product_member(text, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.buy_product(text, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.buy_product_member(text, uuid, integer) TO authenticated;

-- ===================== 20260804025911_bec73982 =====================

CREATE OR REPLACE FUNCTION public.member_lookup(_card_uid text DEFAULT NULL, _member_no text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE p RECORD; txs jsonb;
BEGIN
  IF (_card_uid IS NULL OR btrim(_card_uid) = '') AND (_member_no IS NULL OR btrim(_member_no) = '') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Masukkan nomor member atau tempel kartu');
  END IF;

  SELECT * INTO p FROM public.participants
  WHERE (_card_uid IS NOT NULL AND btrim(_card_uid) <> '' AND upper(card_uid) = upper(btrim(_card_uid)))
     OR (_member_no IS NOT NULL AND btrim(_member_no) <> '' AND upper(member_no) = upper(btrim(_member_no)))
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Data member tidak ditemukan');
  END IF;

  SELECT COALESCE(jsonb_agg(t ORDER BY t.created_at DESC), '[]'::jsonb) INTO txs
  FROM (
    SELECT tr.id, tr.tx_type, tr.amount, tr.balance_after, tr.note, tr.qty, tr.created_at
    FROM public.transactions tr
    WHERE tr.participant_id = p.id
    ORDER BY tr.created_at DESC
    LIMIT 30
  ) t;

  RETURN jsonb_build_object('ok', true, 'name', p.name, 'member_no', p.member_no,
    'balance', p.balance, 'transactions', txs);
END $$;

REVOKE ALL ON FUNCTION public.member_lookup(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.member_lookup(text, text) TO anon, authenticated;

-- ===================== 20260804031503_13d18104 =====================

-- Harden SECURITY DEFINER functions: require admin role, not just any signed-in user

CREATE OR REPLACE FUNCTION public.topup_balance(_participant_id uuid, _amount numeric, _note text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE p RECORD; new_balance NUMERIC(12,2);
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF _amount <= 0 THEN RAISE EXCEPTION 'Jumlah harus > 0'; END IF;
  SELECT * INTO p FROM public.participants WHERE id = _participant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Peserta tidak ditemukan'; END IF;
  new_balance := p.balance + _amount;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;
  INSERT INTO public.transactions (participant_id, tx_type, amount, balance_after, operator_id, note)
    VALUES (p.id, 'topup', _amount, new_balance, auth.uid(), _note);
  RETURN jsonb_build_object('ok', true, 'balance_after', new_balance);
END $function$;

CREATE OR REPLACE FUNCTION public.scan_and_pay(_card_uid text, _field_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE p RECORD; f RECORD; cost NUMERIC(12,2); new_balance NUMERIC(12,2); tx_id UUID;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT * INTO p FROM public.participants WHERE card_uid = _card_uid FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terdaftar'); END IF;
  SELECT * INTO f FROM public.fields WHERE id = _field_id AND active = true;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Lapangan tidak ditemukan'); END IF;
  cost := ROUND(f.base_price * p.rate_multiplier, 2);
  IF p.balance < cost THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Saldo tidak cukup', 'participant', to_jsonb(p), 'cost', cost);
  END IF;
  new_balance := p.balance - cost;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;
  INSERT INTO public.transactions (participant_id, field_id, tx_type, amount, balance_after, operator_id, note)
    VALUES (p.id, f.id, 'attendance', -cost, new_balance, auth.uid(), f.name)
    RETURNING id INTO tx_id;
  RETURN jsonb_build_object('ok', true, 'tx_id', tx_id, 'participant_name', p.name,
    'field_name', f.name, 'cost', cost, 'balance_after', new_balance);
END $function$;

CREATE OR REPLACE FUNCTION public.scan_event_and_pay(_card_uid text, _event_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE p RECORD; ev RECORD; ep RECORD; cost NUMERIC(12,2); new_balance NUMERIC(12,2); tx_id UUID; pos_label TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT * INTO p FROM public.participants WHERE card_uid = _card_uid FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terdaftar'); END IF;
  SELECT * INTO ev FROM public.events WHERE id = _event_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Event tidak ditemukan'); END IF;
  IF ev.status <> 'open' THEN RETURN jsonb_build_object('ok', false, 'error', 'Event sudah ditutup'); END IF;
  SELECT * INTO ep FROM public.event_participants WHERE event_id = _event_id AND participant_id = p.id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Peserta belum terdaftar di event ini', 'participant', to_jsonb(p));
  END IF;
  cost := CASE ep.position WHEN 'gk' THEN ev.gk_price WHEN 'player' THEN ev.player_price WHEN 'reserve' THEN ev.reserve_price END;
  pos_label := CASE ep.position WHEN 'gk' THEN 'Goal Keeper' WHEN 'player' THEN 'Pemain' WHEN 'reserve' THEN 'Cadangan' END;
  IF EXISTS (SELECT 1 FROM public.transactions WHERE event_id = _event_id AND participant_id = p.id AND tx_type = 'attendance') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Peserta sudah absen di event ini', 'participant', to_jsonb(p));
  END IF;
  IF p.balance < cost THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Saldo tidak cukup', 'participant', to_jsonb(p), 'cost', cost);
  END IF;
  new_balance := p.balance - cost;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;
  INSERT INTO public.transactions
    (participant_id, field_id, event_id, position, tx_type, amount, balance_after, operator_id, note)
  VALUES (p.id, ev.field_id, ev.id, ep.position, 'attendance', -cost, new_balance, auth.uid(), ev.name || ' · ' || pos_label)
  RETURNING id INTO tx_id;
  RETURN jsonb_build_object('ok', true, 'tx_id', tx_id, 'participant_name', p.name,
    'event_name', ev.name, 'position', ep.position, 'position_label', pos_label,
    'cost', cost, 'balance_after', new_balance);
END $function$;

CREATE OR REPLACE FUNCTION public.buy_product(_card_uid text, _product_id uuid, _qty integer DEFAULT 1)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE p RECORD; pr RECORD; cost NUMERIC(12,2); new_balance NUMERIC(12,2); tx_id UUID;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF _qty IS NULL OR _qty < 1 THEN RETURN jsonb_build_object('ok', false, 'error', 'Jumlah tidak valid'); END IF;
  SELECT * INTO p FROM public.participants WHERE card_uid = _card_uid FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terdaftar'); END IF;
  SELECT * INTO pr FROM public.products WHERE id = _product_id AND active = true;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Produk tidak ditemukan'); END IF;
  cost := ROUND(pr.price * _qty, 2);
  IF p.balance < cost THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Saldo tidak cukup', 'participant', to_jsonb(p), 'cost', cost);
  END IF;
  new_balance := p.balance - cost;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;
  INSERT INTO public.transactions (participant_id, product_id, qty, tx_type, amount, balance_after, operator_id, note)
  VALUES (p.id, pr.id, _qty, 'purchase', -cost, new_balance, auth.uid(), pr.name || ' x' || _qty)
  RETURNING id INTO tx_id;
  RETURN jsonb_build_object('ok', true, 'tx_id', tx_id, 'participant_name', p.name,
    'product_name', pr.name, 'qty', _qty, 'cost', cost, 'balance_after', new_balance);
END $function$;

CREATE OR REPLACE FUNCTION public.buy_product_member(_member_no text, _product_id uuid, _qty integer DEFAULT 1)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE uid TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT card_uid INTO uid FROM public.participants WHERE member_no = _member_no;
  IF uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Nomor member tidak terdaftar'); END IF;
  RETURN public.buy_product(uid, _product_id, _qty);
END $function$;

CREATE OR REPLACE FUNCTION public.scan_member_and_pay(_member_no text, _field_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE uid TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT card_uid INTO uid FROM public.participants WHERE member_no = _member_no;
  IF uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Nomor member tidak terdaftar'); END IF;
  RETURN public.scan_and_pay(uid, _field_id);
END $function$;

CREATE OR REPLACE FUNCTION public.scan_member_event_and_pay(_member_no text, _event_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE uid TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT card_uid INTO uid FROM public.participants WHERE member_no = _member_no;
  IF uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Nomor member tidak terdaftar'); END IF;
  RETURN public.scan_event_and_pay(uid, _event_id);
END $function$;

-- Ensure event_participants access is admin-only for every command, including DELETE
DROP POLICY IF EXISTS "admin delete event_participants" ON public.event_participants;
CREATE POLICY "admin delete event_participants" ON public.event_participants
  FOR DELETE TO authenticated
  USING (public.has_role(auth.uid(), 'admin'));

REVOKE EXECUTE ON FUNCTION public.enforce_event_slot() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;

-- ===================== 20260805024731_9d067110 =====================

-- 1) Integritas data peserta
CREATE UNIQUE INDEX IF NOT EXISTS participants_member_no_uniq
  ON public.participants (upper(btrim(member_no))) WHERE member_no IS NOT NULL;
ALTER TABLE public.participants DROP CONSTRAINT IF EXISTS participants_balance_nonneg;
ALTER TABLE public.participants ADD CONSTRAINT participants_balance_nonneg CHECK (balance >= 0);

-- 2) Kunci baris event saat validasi kuota (hindari race condition)
CREATE OR REPLACE FUNCTION public.enforce_event_slot()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE ev RECORD; used INT; cap INT;
BEGIN
  SELECT * INTO ev FROM public.events WHERE id = NEW.event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Event tidak ditemukan'; END IF;
  SELECT COUNT(*) INTO used FROM public.event_participants
    WHERE event_id = NEW.event_id AND position = NEW.position
      AND (TG_OP = 'INSERT' OR id <> NEW.id);
  cap := CASE NEW.position WHEN 'gk' THEN ev.gk_slots WHEN 'player' THEN ev.player_slots WHEN 'reserve' THEN ev.reserve_slots END;
  IF used >= cap THEN RAISE EXCEPTION 'Kuota posisi % penuh (%/%)', NEW.position, used, cap; END IF;
  RETURN NEW;
END $function$;

-- 3) scan_and_pay: normalisasi UID + anti dobel potong
CREATE OR REPLACE FUNCTION public.scan_and_pay(_card_uid text, _field_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE p RECORD; f RECORD; cost NUMERIC(12,2); new_balance NUMERIC(12,2); tx_id UUID;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF _card_uid IS NULL OR btrim(_card_uid) = '' THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terbaca'); END IF;
  SELECT * INTO p FROM public.participants WHERE upper(card_uid) = upper(btrim(_card_uid)) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terdaftar'); END IF;
  SELECT * INTO f FROM public.fields WHERE id = _field_id AND active = true;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Lapangan tidak ditemukan'); END IF;
  IF EXISTS (SELECT 1 FROM public.transactions
             WHERE participant_id = p.id AND field_id = f.id AND event_id IS NULL
               AND tx_type = 'attendance' AND created_at > now() - interval '6 hours') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Peserta sudah absen di lapangan ini', 'participant', to_jsonb(p));
  END IF;
  cost := ROUND(f.base_price * p.rate_multiplier, 2);
  IF p.balance < cost THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Saldo tidak cukup', 'participant', to_jsonb(p), 'cost', cost);
  END IF;
  new_balance := p.balance - cost;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;
  INSERT INTO public.transactions (participant_id, field_id, tx_type, amount, balance_after, operator_id, note)
    VALUES (p.id, f.id, 'attendance', -cost, new_balance, auth.uid(), f.name) RETURNING id INTO tx_id;
  RETURN jsonb_build_object('ok', true, 'tx_id', tx_id, 'participant_name', p.name,
    'field_name', f.name, 'cost', cost, 'balance_after', new_balance);
END $function$;

-- 4) scan_event_and_pay: normalisasi UID
CREATE OR REPLACE FUNCTION public.scan_event_and_pay(_card_uid text, _event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE p RECORD; ev RECORD; ep RECORD; cost NUMERIC(12,2); new_balance NUMERIC(12,2); tx_id UUID; pos_label TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF _card_uid IS NULL OR btrim(_card_uid) = '' THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terbaca'); END IF;
  SELECT * INTO p FROM public.participants WHERE upper(card_uid) = upper(btrim(_card_uid)) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terdaftar'); END IF;
  SELECT * INTO ev FROM public.events WHERE id = _event_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Event tidak ditemukan'); END IF;
  IF ev.status <> 'open' THEN RETURN jsonb_build_object('ok', false, 'error', 'Event sudah ditutup'); END IF;
  SELECT * INTO ep FROM public.event_participants WHERE event_id = _event_id AND participant_id = p.id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Peserta belum terdaftar di event ini', 'participant', to_jsonb(p));
  END IF;
  cost := CASE ep.position WHEN 'gk' THEN ev.gk_price WHEN 'player' THEN ev.player_price WHEN 'reserve' THEN ev.reserve_price END;
  pos_label := CASE ep.position WHEN 'gk' THEN 'Goal Keeper' WHEN 'player' THEN 'Pemain' WHEN 'reserve' THEN 'Cadangan' END;
  IF EXISTS (SELECT 1 FROM public.transactions WHERE event_id = _event_id AND participant_id = p.id AND tx_type = 'attendance') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Peserta sudah absen di event ini', 'participant', to_jsonb(p));
  END IF;
  IF p.balance < cost THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Saldo tidak cukup', 'participant', to_jsonb(p), 'cost', cost);
  END IF;
  new_balance := p.balance - cost;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;
  INSERT INTO public.transactions
    (participant_id, field_id, event_id, position, tx_type, amount, balance_after, operator_id, note)
  VALUES (p.id, ev.field_id, ev.id, ep.position, 'attendance', -cost, new_balance, auth.uid(), ev.name || ' · ' || pos_label)
  RETURNING id INTO tx_id;
  RETURN jsonb_build_object('ok', true, 'tx_id', tx_id, 'participant_name', p.name,
    'event_name', ev.name, 'position', ep.position, 'position_label', pos_label,
    'cost', cost, 'balance_after', new_balance);
END $function$;

-- 5) buy_product: normalisasi UID + batas qty
CREATE OR REPLACE FUNCTION public.buy_product(_card_uid text, _product_id uuid, _qty integer DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE p RECORD; pr RECORD; cost NUMERIC(12,2); new_balance NUMERIC(12,2); tx_id UUID;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF _qty IS NULL OR _qty < 1 OR _qty > 100 THEN RETURN jsonb_build_object('ok', false, 'error', 'Jumlah tidak valid (1-100)'); END IF;
  IF _card_uid IS NULL OR btrim(_card_uid) = '' THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terbaca'); END IF;
  SELECT * INTO p FROM public.participants WHERE upper(card_uid) = upper(btrim(_card_uid)) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terdaftar'); END IF;
  SELECT * INTO pr FROM public.products WHERE id = _product_id AND active = true;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Produk tidak ditemukan'); END IF;
  cost := ROUND(pr.price * _qty, 2);
  IF p.balance < cost THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Saldo tidak cukup', 'participant', to_jsonb(p), 'cost', cost);
  END IF;
  new_balance := p.balance - cost;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;
  INSERT INTO public.transactions (participant_id, product_id, qty, tx_type, amount, balance_after, operator_id, note)
  VALUES (p.id, pr.id, _qty, 'purchase', -cost, new_balance, auth.uid(), pr.name || ' x' || _qty)
  RETURNING id INTO tx_id;
  RETURN jsonb_build_object('ok', true, 'tx_id', tx_id, 'participant_name', p.name,
    'product_name', pr.name, 'qty', _qty, 'cost', cost, 'balance_after', new_balance);
END $function$;

-- 6) Wrapper nomor member: normalisasi
CREATE OR REPLACE FUNCTION public.scan_member_and_pay(_member_no text, _field_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE uid TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT card_uid INTO uid FROM public.participants WHERE upper(member_no) = upper(btrim(_member_no));
  IF uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Nomor member tidak terdaftar'); END IF;
  RETURN public.scan_and_pay(uid, _field_id);
END $function$;

CREATE OR REPLACE FUNCTION public.scan_member_event_and_pay(_member_no text, _event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE uid TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT card_uid INTO uid FROM public.participants WHERE upper(member_no) = upper(btrim(_member_no));
  IF uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Nomor member tidak terdaftar'); END IF;
  RETURN public.scan_event_and_pay(uid, _event_id);
END $function$;

CREATE OR REPLACE FUNCTION public.buy_product_member(_member_no text, _product_id uuid, _qty integer DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE uid TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT card_uid INTO uid FROM public.participants WHERE upper(member_no) = upper(btrim(_member_no));
  IF uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Nomor member tidak terdaftar'); END IF;
  RETURN public.buy_product(uid, _product_id, _qty);
END $function$;

-- 7) topup: batas nominal wajar
CREATE OR REPLACE FUNCTION public.topup_balance(_participant_id uuid, _amount numeric, _note text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE p RECORD; new_balance NUMERIC(12,2); amt NUMERIC(12,2);
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_role(auth.uid(), 'admin') THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  amt := ROUND(COALESCE(_amount, 0), 2);
  IF amt <= 0 THEN RAISE EXCEPTION 'Jumlah harus > 0'; END IF;
  IF amt > 10000000 THEN RAISE EXCEPTION 'Jumlah maksimal Rp 10.000.000 per transaksi'; END IF;
  SELECT * INTO p FROM public.participants WHERE id = _participant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Peserta tidak ditemukan'; END IF;
  new_balance := p.balance + amt;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;
  INSERT INTO public.transactions (participant_id, tx_type, amount, balance_after, operator_id, note)
    VALUES (p.id, 'topup', amt, new_balance, auth.uid(), left(COALESCE(_note,''), 200));
  RETURN jsonb_build_object('ok', true, 'balance_after', new_balance);
END $function$;

-- ===================== 20260806024839_5a80af92 =====================

-- 1. New role labels (safe: only referenced from plpgsql bodies in this migration)
ALTER TYPE public.app_role ADD VALUE IF NOT EXISTS 'super_admin';
ALTER TYPE public.app_role ADD VALUE IF NOT EXISTS 'member';

-- 2. Role helper functions (plpgsql so new enum labels resolve at runtime)
CREATE OR REPLACE FUNCTION public.is_super_admin(_user_id uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF _user_id IS NULL THEN RETURN false; END IF;
  RETURN EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role::text = 'super_admin');
END $$;

CREATE OR REPLACE FUNCTION public.is_staff(_user_id uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF _user_id IS NULL THEN RETURN false; END IF;
  RETURN EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role::text IN ('super_admin','admin'));
END $$;

REVOKE EXECUTE ON FUNCTION public.is_super_admin(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.is_staff(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_super_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_staff(uuid) TO authenticated;

-- 3. Signup: first account = super_admin, everyone else = member
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE existing_roles INT;
BEGIN
  INSERT INTO public.profiles (id, full_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email));
  SELECT COUNT(*) INTO existing_roles FROM public.user_roles;
  IF existing_roles = 0 THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'super_admin'::public.app_role);
  ELSE
    INSERT INTO public.user_roles (user_id, role) VALUES (NEW.id, 'member'::public.app_role);
  END IF;
  RETURN NEW;
END $$;

-- 5. Member PIN (bcrypt hashed)
ALTER TABLE public.participants ADD COLUMN IF NOT EXISTS pin_hash text;

CREATE OR REPLACE FUNCTION public.set_member_pin(_participant_id uuid, _pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE cleaned text;
BEGIN
  IF NOT public.is_staff(auth.uid()) THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  cleaned := btrim(COALESCE(_pin, ''));
  IF cleaned = '' THEN
    UPDATE public.participants SET pin_hash = NULL WHERE id = _participant_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Peserta tidak ditemukan'); END IF;
    RETURN jsonb_build_object('ok', true, 'pin_set', false);
  END IF;
  IF cleaned !~ '^[0-9]{4}$' THEN RETURN jsonb_build_object('ok', false, 'error', 'PIN harus 4 digit angka'); END IF;
  UPDATE public.participants
    SET pin_hash = extensions.crypt(cleaned, extensions.gen_salt('bf'))
    WHERE id = _participant_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Peserta tidak ditemukan'); END IF;
  RETURN jsonb_build_object('ok', true, 'pin_set', true);
END $$;

REVOKE EXECUTE ON FUNCTION public.set_member_pin(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_member_pin(uuid, text) TO authenticated;

-- 6. Public member lookup with optional PIN + stricter input validation
DROP FUNCTION IF EXISTS public.member_lookup(text, text);

CREATE OR REPLACE FUNCTION public.member_lookup(_card_uid text DEFAULT NULL, _member_no text DEFAULT NULL, _pin text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE p RECORD; txs jsonb; c text; m text; pin text;
BEGIN
  c := upper(btrim(COALESCE(_card_uid, '')));
  m := upper(btrim(COALESCE(_member_no, '')));
  pin := btrim(COALESCE(_pin, ''));

  IF c = '' AND m = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Masukkan nomor member atau tempel kartu');
  END IF;
  IF length(c) > 64 OR length(m) > 64 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Input tidak valid');
  END IF;
  IF c <> '' AND c !~ '^[0-9A-F]{4,64}$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terbaca');
  END IF;
  IF m <> '' AND m !~ '^[0-9A-Z\\-/]{3,64}$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Format nomor member tidak valid');
  END IF;

  SELECT * INTO p FROM public.participants
  WHERE (c <> '' AND upper(card_uid) = c) OR (m <> '' AND upper(member_no) = m)
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Data member tidak ditemukan');
  END IF;

  IF p.pin_hash IS NOT NULL THEN
    IF pin = '' THEN
      RETURN jsonb_build_object('ok', false, 'pin_required', true, 'error', 'Masukkan PIN 4 digit');
    END IF;
    IF pin !~ '^[0-9]{4}$' OR extensions.crypt(pin, p.pin_hash) <> p.pin_hash THEN
      RETURN jsonb_build_object('ok', false, 'pin_required', true, 'error', 'PIN salah');
    END IF;
  END IF;

  SELECT COALESCE(jsonb_agg(t ORDER BY t.created_at DESC), '[]'::jsonb) INTO txs
  FROM (
    SELECT tr.id, tr.tx_type, tr.amount, tr.balance_after, tr.note, tr.qty, tr.created_at
    FROM public.transactions tr WHERE tr.participant_id = p.id
    ORDER BY tr.created_at DESC LIMIT 30
  ) t;

  RETURN jsonb_build_object('ok', true, 'name', p.name, 'member_no', p.member_no,
    'balance', p.balance, 'has_pin', p.pin_hash IS NOT NULL, 'transactions', txs);
END $$;

REVOKE EXECUTE ON FUNCTION public.member_lookup(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.member_lookup(text, text, text) TO anon, authenticated;

-- 7. Transaction RPCs: staff (admin OR super_admin) only
CREATE OR REPLACE FUNCTION public.topup_balance(_participant_id uuid, _amount numeric, _note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE p RECORD; new_balance NUMERIC(12,2); amt NUMERIC(12,2);
BEGIN
  IF NOT public.is_staff(auth.uid()) THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  amt := ROUND(COALESCE(_amount, 0), 2);
  IF amt <= 0 THEN RAISE EXCEPTION 'Jumlah harus > 0'; END IF;
  IF amt > 10000000 THEN RAISE EXCEPTION 'Jumlah maksimal Rp 10.000.000 per transaksi'; END IF;
  SELECT * INTO p FROM public.participants WHERE id = _participant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Peserta tidak ditemukan'; END IF;
  new_balance := p.balance + amt;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;
  INSERT INTO public.transactions (participant_id, tx_type, amount, balance_after, operator_id, note)
    VALUES (p.id, 'topup', amt, new_balance, auth.uid(), left(COALESCE(_note,''), 200));
  RETURN jsonb_build_object('ok', true, 'balance_after', new_balance);
END $$;

CREATE OR REPLACE FUNCTION public.scan_and_pay(_card_uid text, _field_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE p RECORD; f RECORD; cost NUMERIC(12,2); new_balance NUMERIC(12,2); tx_id UUID;
BEGIN
  IF NOT public.is_staff(auth.uid()) THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF _card_uid IS NULL OR btrim(_card_uid) = '' THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terbaca'); END IF;
  SELECT * INTO p FROM public.participants WHERE upper(card_uid) = upper(btrim(_card_uid)) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terdaftar'); END IF;
  SELECT * INTO f FROM public.fields WHERE id = _field_id AND active = true;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Lapangan tidak ditemukan'); END IF;
  IF EXISTS (SELECT 1 FROM public.transactions
             WHERE participant_id = p.id AND field_id = f.id AND event_id IS NULL
               AND tx_type = 'attendance' AND created_at > now() - interval '6 hours') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Peserta sudah absen di lapangan ini', 'participant', to_jsonb(p));
  END IF;
  cost := ROUND(f.base_price * p.rate_multiplier, 2);
  IF p.balance < cost THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Saldo tidak cukup', 'participant', to_jsonb(p), 'cost', cost);
  END IF;
  new_balance := p.balance - cost;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;
  INSERT INTO public.transactions (participant_id, field_id, tx_type, amount, balance_after, operator_id, note)
    VALUES (p.id, f.id, 'attendance', -cost, new_balance, auth.uid(), f.name) RETURNING id INTO tx_id;
  RETURN jsonb_build_object('ok', true, 'tx_id', tx_id, 'participant_name', p.name,
    'field_name', f.name, 'cost', cost, 'balance_after', new_balance);
END $$;

CREATE OR REPLACE FUNCTION public.scan_event_and_pay(_card_uid text, _event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE p RECORD; ev RECORD; ep RECORD; cost NUMERIC(12,2); new_balance NUMERIC(12,2); tx_id UUID; pos_label TEXT;
BEGIN
  IF NOT public.is_staff(auth.uid()) THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF _card_uid IS NULL OR btrim(_card_uid) = '' THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terbaca'); END IF;
  SELECT * INTO p FROM public.participants WHERE upper(card_uid) = upper(btrim(_card_uid)) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terdaftar'); END IF;
  SELECT * INTO ev FROM public.events WHERE id = _event_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Event tidak ditemukan'); END IF;
  IF ev.status <> 'open' THEN RETURN jsonb_build_object('ok', false, 'error', 'Event sudah ditutup'); END IF;
  SELECT * INTO ep FROM public.event_participants WHERE event_id = _event_id AND participant_id = p.id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Peserta belum terdaftar di event ini', 'participant', to_jsonb(p));
  END IF;
  cost := CASE ep.position WHEN 'gk' THEN ev.gk_price WHEN 'player' THEN ev.player_price WHEN 'reserve' THEN ev.reserve_price END;
  pos_label := CASE ep.position WHEN 'gk' THEN 'Goal Keeper' WHEN 'player' THEN 'Pemain' WHEN 'reserve' THEN 'Cadangan' END;
  IF EXISTS (SELECT 1 FROM public.transactions WHERE event_id = _event_id AND participant_id = p.id AND tx_type = 'attendance') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Peserta sudah absen di event ini', 'participant', to_jsonb(p));
  END IF;
  IF p.balance < cost THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Saldo tidak cukup', 'participant', to_jsonb(p), 'cost', cost);
  END IF;
  new_balance := p.balance - cost;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;
  INSERT INTO public.transactions
    (participant_id, field_id, event_id, position, tx_type, amount, balance_after, operator_id, note)
  VALUES (p.id, ev.field_id, ev.id, ep.position, 'attendance', -cost, new_balance, auth.uid(), ev.name || ' · ' || pos_label)
  RETURNING id INTO tx_id;
  RETURN jsonb_build_object('ok', true, 'tx_id', tx_id, 'participant_name', p.name,
    'event_name', ev.name, 'position', ep.position, 'position_label', pos_label,
    'cost', cost, 'balance_after', new_balance);
END $$;

CREATE OR REPLACE FUNCTION public.buy_product(_card_uid text, _product_id uuid, _qty integer DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE p RECORD; pr RECORD; cost NUMERIC(12,2); new_balance NUMERIC(12,2); tx_id UUID;
BEGIN
  IF NOT public.is_staff(auth.uid()) THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF _qty IS NULL OR _qty < 1 OR _qty > 100 THEN RETURN jsonb_build_object('ok', false, 'error', 'Jumlah tidak valid (1-100)'); END IF;
  IF _card_uid IS NULL OR btrim(_card_uid) = '' THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terbaca'); END IF;
  SELECT * INTO p FROM public.participants WHERE upper(card_uid) = upper(btrim(_card_uid)) FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Kartu tidak terdaftar'); END IF;
  SELECT * INTO pr FROM public.products WHERE id = _product_id AND active = true;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Produk tidak ditemukan'); END IF;
  cost := ROUND(pr.price * _qty, 2);
  IF p.balance < cost THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Saldo tidak cukup', 'participant', to_jsonb(p), 'cost', cost);
  END IF;
  new_balance := p.balance - cost;
  UPDATE public.participants SET balance = new_balance WHERE id = p.id;
  INSERT INTO public.transactions (participant_id, product_id, qty, tx_type, amount, balance_after, operator_id, note)
  VALUES (p.id, pr.id, _qty, 'purchase', -cost, new_balance, auth.uid(), pr.name || ' x' || _qty)
  RETURNING id INTO tx_id;
  RETURN jsonb_build_object('ok', true, 'tx_id', tx_id, 'participant_name', p.name,
    'product_name', pr.name, 'qty', _qty, 'cost', cost, 'balance_after', new_balance);
END $$;

CREATE OR REPLACE FUNCTION public.buy_product_member(_member_no text, _product_id uuid, _qty integer DEFAULT 1)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE uid TEXT;
BEGIN
  IF NOT public.is_staff(auth.uid()) THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT card_uid INTO uid FROM public.participants WHERE upper(member_no) = upper(btrim(_member_no));
  IF uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Nomor member tidak terdaftar'); END IF;
  RETURN public.buy_product(uid, _product_id, _qty);
END $$;

CREATE OR REPLACE FUNCTION public.scan_member_and_pay(_member_no text, _field_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE uid TEXT;
BEGIN
  IF NOT public.is_staff(auth.uid()) THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT card_uid INTO uid FROM public.participants WHERE upper(member_no) = upper(btrim(_member_no));
  IF uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Nomor member tidak terdaftar'); END IF;
  RETURN public.scan_and_pay(uid, _field_id);
END $$;

CREATE OR REPLACE FUNCTION public.scan_member_event_and_pay(_member_no text, _event_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE uid TEXT;
BEGIN
  IF NOT public.is_staff(auth.uid()) THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  SELECT card_uid INTO uid FROM public.participants WHERE upper(member_no) = upper(btrim(_member_no));
  IF uid IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'Nomor member tidak terdaftar'); END IF;
  RETURN public.scan_event_and_pay(uid, _event_id);
END $$;

-- 8. RLS: staff-only across operational tables
DROP POLICY IF EXISTS "admin read participants" ON public.participants;
DROP POLICY IF EXISTS "admin insert participants" ON public.participants;
DROP POLICY IF EXISTS "admin update participants" ON public.participants;
DROP POLICY IF EXISTS "admin delete participants" ON public.participants;
CREATE POLICY "staff read participants" ON public.participants FOR SELECT TO authenticated USING (public.is_staff(auth.uid()));
CREATE POLICY "staff insert participants" ON public.participants FOR INSERT TO authenticated WITH CHECK (public.is_staff(auth.uid()));
CREATE POLICY "staff update participants" ON public.participants FOR UPDATE TO authenticated USING (public.is_staff(auth.uid())) WITH CHECK (public.is_staff(auth.uid()));
CREATE POLICY "staff delete participants" ON public.participants FOR DELETE TO authenticated USING (public.is_staff(auth.uid()));

DROP POLICY IF EXISTS "auth read fields" ON public.fields;
DROP POLICY IF EXISTS "admin insert fields" ON public.fields;
DROP POLICY IF EXISTS "admin update fields" ON public.fields;
DROP POLICY IF EXISTS "admin delete fields" ON public.fields;
CREATE POLICY "staff read fields" ON public.fields FOR SELECT TO authenticated USING (public.is_staff(auth.uid()));
CREATE POLICY "staff insert fields" ON public.fields FOR INSERT TO authenticated WITH CHECK (public.is_staff(auth.uid()));
CREATE POLICY "staff update fields" ON public.fields FOR UPDATE TO authenticated USING (public.is_staff(auth.uid())) WITH CHECK (public.is_staff(auth.uid()));
CREATE POLICY "staff delete fields" ON public.fields FOR DELETE TO authenticated USING (public.is_staff(auth.uid()));

DROP POLICY IF EXISTS "auth read events" ON public.events;
DROP POLICY IF EXISTS "admin insert events" ON public.events;
DROP POLICY IF EXISTS "admin update events" ON public.events;
DROP POLICY IF EXISTS "admin delete events" ON public.events;
CREATE POLICY "staff read events" ON public.events FOR SELECT TO authenticated USING (public.is_staff(auth.uid()));
CREATE POLICY "staff insert events" ON public.events FOR INSERT TO authenticated WITH CHECK (public.is_staff(auth.uid()));
CREATE POLICY "staff update events" ON public.events FOR UPDATE TO authenticated USING (public.is_staff(auth.uid())) WITH CHECK (public.is_staff(auth.uid()));
CREATE POLICY "staff delete events" ON public.events FOR DELETE TO authenticated USING (public.is_staff(auth.uid()));

DROP POLICY IF EXISTS "auth read products" ON public.products;
DROP POLICY IF EXISTS "admin insert products" ON public.products;
DROP POLICY IF EXISTS "admin update products" ON public.products;
DROP POLICY IF EXISTS "admin delete products" ON public.products;
CREATE POLICY "staff read products" ON public.products FOR SELECT TO authenticated USING (public.is_staff(auth.uid()));
CREATE POLICY "staff insert products" ON public.products FOR INSERT TO authenticated WITH CHECK (public.is_staff(auth.uid()));
CREATE POLICY "staff update products" ON public.products FOR UPDATE TO authenticated USING (public.is_staff(auth.uid())) WITH CHECK (public.is_staff(auth.uid()));
CREATE POLICY "staff delete products" ON public.products FOR DELETE TO authenticated USING (public.is_staff(auth.uid()));

DROP POLICY IF EXISTS "admin read event_participants" ON public.event_participants;
DROP POLICY IF EXISTS "admin insert event_participants" ON public.event_participants;
DROP POLICY IF EXISTS "admin update event_participants" ON public.event_participants;
DROP POLICY IF EXISTS "admin delete event_participants" ON public.event_participants;
CREATE POLICY "staff read event_participants" ON public.event_participants FOR SELECT TO authenticated USING (public.is_staff(auth.uid()));
CREATE POLICY "staff insert event_participants" ON public.event_participants FOR INSERT TO authenticated WITH CHECK (public.is_staff(auth.uid()));
CREATE POLICY "staff update event_participants" ON public.event_participants FOR UPDATE TO authenticated USING (public.is_staff(auth.uid())) WITH CHECK (public.is_staff(auth.uid()));
CREATE POLICY "staff delete event_participants" ON public.event_participants FOR DELETE TO authenticated USING (public.is_staff(auth.uid()));

DROP POLICY IF EXISTS "admin read transactions" ON public.transactions;
DROP POLICY IF EXISTS "admin insert transactions" ON public.transactions;
CREATE POLICY "staff read transactions" ON public.transactions FOR SELECT TO authenticated USING (public.is_staff(auth.uid()));

-- 9. Profiles + user_roles management for super admin
DROP POLICY IF EXISTS "super admin read profiles" ON public.profiles;
CREATE POLICY "super admin read profiles" ON public.profiles FOR SELECT TO authenticated USING (public.is_super_admin(auth.uid()));

DROP POLICY IF EXISTS "super admin read roles" ON public.user_roles;
DROP POLICY IF EXISTS "super admin insert roles" ON public.user_roles;
DROP POLICY IF EXISTS "super admin update roles" ON public.user_roles;
DROP POLICY IF EXISTS "super admin delete roles" ON public.user_roles;
CREATE POLICY "super admin read roles" ON public.user_roles FOR SELECT TO authenticated USING (public.is_super_admin(auth.uid()));
CREATE POLICY "super admin insert roles" ON public.user_roles FOR INSERT TO authenticated
  WITH CHECK (public.is_super_admin(auth.uid()) AND role::text <> 'super_admin');
CREATE POLICY "super admin delete roles" ON public.user_roles FOR DELETE TO authenticated
  USING (public.is_super_admin(auth.uid()) AND role::text <> 'super_admin');

GRANT SELECT, INSERT, DELETE ON public.user_roles TO authenticated;
GRANT ALL ON public.user_roles TO service_role;

-- 10. Directory of accounts visible to super admin only
CREATE OR REPLACE FUNCTION public.list_app_users()
RETURNS TABLE (user_id uuid, full_name text, email text, roles text[], created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.is_super_admin(auth.uid()) THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  RETURN QUERY
    SELECT u.id, p.full_name, u.email::text,
           COALESCE(ARRAY(SELECT r.role::text FROM public.user_roles r WHERE r.user_id = u.id ORDER BY r.role::text), '{}'::text[]),
           u.created_at
    FROM auth.users u
    LEFT JOIN public.profiles p ON p.id = u.id
    ORDER BY u.created_at ASC;
END $$;

REVOKE EXECUTE ON FUNCTION public.list_app_users() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_app_users() TO authenticated;

CREATE OR REPLACE FUNCTION public.set_user_staff(_user_id uuid, _make_staff boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.is_super_admin(auth.uid()) THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF _user_id IS NULL THEN RAISE EXCEPTION 'User tidak valid'; END IF;
  IF public.is_super_admin(_user_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Peran super admin tidak dapat diubah');
  END IF;
  IF _make_staff THEN
    DELETE FROM public.user_roles WHERE user_id = _user_id AND role::text = 'member';
    INSERT INTO public.user_roles (user_id, role) VALUES (_user_id, 'admin'::public.app_role)
      ON CONFLICT (user_id, role) DO NOTHING;
  ELSE
    DELETE FROM public.user_roles WHERE user_id = _user_id AND role::text IN ('admin','operator');
    INSERT INTO public.user_roles (user_id, role) VALUES (_user_id, 'member'::public.app_role)
      ON CONFLICT (user_id, role) DO NOTHING;
  END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

REVOKE EXECUTE ON FUNCTION public.set_user_staff(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_user_staff(uuid, boolean) TO authenticated;

CREATE OR REPLACE FUNCTION public.my_access()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('staff', false, 'super_admin', false); END IF;
  RETURN jsonb_build_object('staff', public.is_staff(auth.uid()), 'super_admin', public.is_super_admin(auth.uid()));
END $$;

REVOKE EXECUTE ON FUNCTION public.my_access() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_access() TO authenticated;

-- ============================================================================
-- SELESAI. Cek dengan query berikut:
--   SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY 1;
--   SELECT proname FROM pg_proc WHERE pronamespace='public'::regnamespace ORDER BY 1;
-- ============================================================================
