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