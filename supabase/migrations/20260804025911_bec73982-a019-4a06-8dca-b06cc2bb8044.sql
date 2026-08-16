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