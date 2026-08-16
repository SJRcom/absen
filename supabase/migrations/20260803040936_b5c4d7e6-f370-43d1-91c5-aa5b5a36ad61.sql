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