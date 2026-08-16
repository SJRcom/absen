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