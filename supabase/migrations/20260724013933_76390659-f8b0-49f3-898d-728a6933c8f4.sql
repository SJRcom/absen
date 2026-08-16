
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

-- Update policy insert transactions untuk mengizinkan event scan (tetap admin only sesuai state saat ini)
-- (policy existing sudah menerima has_role admin, tak perlu diubah)

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
