
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
