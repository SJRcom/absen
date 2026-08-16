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
  IF m <> '' AND m !~ '^[0-9A-Z\-/]{3,64}$' THEN
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