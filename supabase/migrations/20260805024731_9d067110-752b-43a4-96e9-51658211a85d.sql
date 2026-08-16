
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
