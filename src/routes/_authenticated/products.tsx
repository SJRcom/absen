import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { formatIDR } from "@/lib/format";
import { parseMemberQr } from "@/lib/qr";
import { QrScannerBox } from "@/components/QrScannerBox";
import { detectNfcSupport, startNfcScan, type NfcScanController } from "@/lib/nfc";
import { toast } from "sonner";
import {
  ShoppingBag, Plus, Trash2, Pencil, X, Radio, ScanLine, Loader2, CheckCircle2, XCircle, Minus,
} from "lucide-react";

export const Route = createFileRoute("/_authenticated/products")({
  head: () => ({
    meta: [
      { title: "Produk & Merchandise · Absensi SJR" },
      { name: "description", content: "Jual jersey dan minuman SJR. Pembayaran pakai saldo peserta via tap NFC atau scan QR Code member." },
      { property: "og:title", content: "Produk & Merchandise · Absensi SJR" },
      { property: "og:description", content: "Penjualan merchandise SJR dengan pembayaran saldo peserta." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: ProductsPage,
});

type Product = {
  id: string; name: string; category: string; price: number;
  description: string | null; active: boolean;
};

type BuyResult =
  | { ok: true; participant_name: string; product_name: string; qty: number; cost: number; balance_after: number }
  | { ok: false; error: string; cost?: number; participant?: { name: string; balance: number } };

const EMPTY = { name: "", category: "merchandise", price: "", description: "", active: true };

function ProductsPage() {
  const qc = useQueryClient();
  const support = typeof window === "undefined" ? "unsupported" : detectNfcSupport();

  const [form, setForm] = useState<typeof EMPTY>(EMPTY);
  const [editId, setEditId] = useState<string | null>(null);
  const [showForm, setShowForm] = useState(false);

  const [cartId, setCartId] = useState<string>("");
  const [qty, setQty] = useState(1);
  const [method, setMethod] = useState<"nfc" | "qr">("qr");
  const [manualMember, setManualMember] = useState("");
  const [manualUid, setManualUid] = useState("");
  const [scanning, setScanning] = useState(false);
  const [processing, setProcessing] = useState(false);
  const [result, setResult] = useState<BuyResult | null>(null);
  const ctrlRef = useRef<NfcScanController | null>(null);
  const lastRef = useRef<{ key: string; at: number }>({ key: "", at: 0 });

  useEffect(() => () => { ctrlRef.current?.stop(); }, []);

  const productsQ = useQuery({
    queryKey: ["products"],
    queryFn: async () => {
      const { data, error } = await supabase.from("products").select("*").order("category").order("name");
      if (error) throw error;
      return data as Product[];
    },
  });

  const selected = productsQ.data?.find((p) => p.id === cartId) ?? null;

  const save = useMutation({
    mutationFn: async () => {
      const payload = {
        name: form.name.trim(),
        category: form.category.trim() || "merchandise",
        price: Number(form.price || 0),
        description: form.description.trim() || null,
        active: form.active,
      };
      if (!payload.name) throw new Error("Nama produk wajib diisi");
      if (editId) {
        const { error } = await supabase.from("products").update(payload).eq("id", editId);
        if (error) throw error;
      } else {
        const { error } = await supabase.from("products").insert(payload);
        if (error) throw error;
      }
    },
    onSuccess: () => {
      toast.success(editId ? "Produk diperbarui" : "Produk ditambahkan");
      setForm(EMPTY); setEditId(null); setShowForm(false);
      qc.invalidateQueries({ queryKey: ["products"] });
    },
    onError: (e: Error) => toast.error(e.message),
  });

  const remove = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from("products").delete().eq("id", id);
      if (error) throw error;
    },
    onSuccess: () => { toast.success("Produk dihapus"); qc.invalidateQueries({ queryKey: ["products"] }); },
    onError: (e: Error) => toast.error(e.message),
  });

  async function buy(key: string, kind: "uid" | "member") {
    if (!cartId) { toast.error("Pilih produk dulu"); return; }
    const now = Date.now();
    if (key === lastRef.current.key && now - lastRef.current.at < 3000) return;
    lastRef.current = { key, at: now };

    setProcessing(true);
    setResult(null);
    try {
      const { data, error } = kind === "member"
        ? await supabase.rpc("buy_product_member", { _member_no: key, _product_id: cartId, _qty: qty })
        : await supabase.rpc("buy_product", { _card_uid: key, _product_id: cartId, _qty: qty });
      if (error) throw error;
      const r = data as unknown as BuyResult;
      setResult(r);
      if (r.ok) {
        toast.success(`${r.participant_name} · ${r.product_name} · ${formatIDR(r.cost)}`);
        qc.invalidateQueries({ queryKey: ["transactions"] });
        qc.invalidateQueries({ queryKey: ["participants"] });
      } else toast.error(r.error);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Gagal");
    } finally { setProcessing(false); }
  }

  function handleQr(text: string) {
    const parsed = parseMemberQr(text);
    if (!parsed) { toast.error("QR Code tidak dikenali"); return; }
    void buy(parsed.member_no, "member");
  }

  async function toggleNfc() {
    if (scanning) { ctrlRef.current?.stop(); ctrlRef.current = null; setScanning(false); return; }
    setScanning(true);
    ctrlRef.current = await startNfcScan((uid) => void buy(uid, "uid"), (err) => {
      toast.error(err.message || "NFC error");
      setScanning(false);
    });
  }

  const total = selected ? Number(selected.price) * qty : 0;

  return (
    <div className="grid gap-6 lg:grid-cols-[1fr_380px]">
      <div className="space-y-6">
        <div className="flex items-end justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold flex items-center gap-2"><ShoppingBag className="h-6 w-6 text-primary" />Produk SJR</h1>
            <p className="text-sm text-muted-foreground">Jersey, minuman, dan merchandise lain. Bayar dengan saldo peserta.</p>
          </div>
          <button
            onClick={() => { setShowForm((v) => !v); setEditId(null); setForm(EMPTY); }}
            className="inline-flex items-center gap-1.5 rounded-md bg-primary px-3 py-2 text-sm font-semibold text-primary-foreground"
          >
            {showForm ? <X className="h-4 w-4" /> : <Plus className="h-4 w-4" />}{showForm ? "Tutup" : "Produk baru"}
          </button>
        </div>

        {showForm && (
          <div className="card-surface p-5">
            <div className="grid gap-3 sm:grid-cols-2">
              <div className="sm:col-span-2">
                <label className="text-sm font-medium">Nama produk</label>
                <input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="mis. Jersey Home (Putih)" className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm" />
              </div>
              <div>
                <label className="text-sm font-medium">Kategori</label>
                <input value={form.category} onChange={(e) => setForm({ ...form, category: e.target.value })} placeholder="jersey / minuman" className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm" />
              </div>
              <div>
                <label className="text-sm font-medium">Harga (Rp)</label>
                <input type="number" min={0} value={form.price} onChange={(e) => setForm({ ...form, price: e.target.value })} className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm" />
              </div>
              <div className="sm:col-span-2">
                <label className="text-sm font-medium">Deskripsi</label>
                <input value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm" />
              </div>
              <label className="flex items-center gap-2 text-sm">
                <input type="checkbox" checked={form.active} onChange={(e) => setForm({ ...form, active: e.target.checked })} />Aktif dijual
              </label>
            </div>
            <button onClick={() => save.mutate()} disabled={save.isPending} className="mt-4 inline-flex items-center gap-2 rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground disabled:opacity-50">
              {save.isPending && <Loader2 className="h-4 w-4 animate-spin" />}{editId ? "Simpan perubahan" : "Tambah produk"}
            </button>
          </div>
        )}

        <div className="grid gap-3 sm:grid-cols-2">
          {productsQ.data?.map((p) => {
            const active = p.id === cartId;
            return (
              <div key={p.id} className={`card-surface p-4 transition ${active ? "ring-2 ring-primary" : ""} ${p.active ? "" : "opacity-60"}`}>
                <div className="flex items-start justify-between gap-2">
                  <div>
                    <p className="text-[10px] uppercase tracking-wider text-muted-foreground">{p.category}</p>
                    <p className="font-semibold">{p.name}</p>
                    <p className="text-lg font-bold text-primary">{formatIDR(p.price)}</p>
                    {p.description && <p className="mt-1 text-xs text-muted-foreground">{p.description}</p>}
                    {!p.active && <p className="mt-1 text-xs text-destructive">Tidak dijual</p>}
                  </div>
                  <div className="flex flex-col gap-1">
                    <button onClick={() => { setEditId(p.id); setShowForm(true); setForm({ name: p.name, category: p.category, price: String(p.price), description: p.description ?? "", active: p.active }); }} className="rounded p-1.5 hover:bg-muted" aria-label="Edit produk"><Pencil className="h-4 w-4" /></button>
                    <button onClick={() => { if (confirm(`Hapus ${p.name}?`)) remove.mutate(p.id); }} className="rounded p-1.5 text-destructive hover:bg-muted" aria-label="Hapus produk"><Trash2 className="h-4 w-4" /></button>
                  </div>
                </div>
                <button
                  onClick={() => { setCartId(p.id); setQty(1); setResult(null); }}
                  disabled={!p.active}
                  className="mt-3 w-full rounded-md bg-secondary px-3 py-2 text-sm font-medium hover:bg-muted disabled:opacity-50"
                >
                  {active ? "Dipilih" : "Pilih untuk dijual"}
                </button>
              </div>
            );
          })}
          {productsQ.data && productsQ.data.length === 0 && (
            <p className="text-sm text-muted-foreground">Belum ada produk. Tambahkan produk baru.</p>
          )}
        </div>
      </div>

      <div className="space-y-4">
        <div className="card-surface p-5">
          <h2 className="font-semibold">Kasir</h2>
          {!selected ? (
            <p className="mt-2 text-sm text-muted-foreground">Pilih produk di sebelah kiri untuk mulai transaksi.</p>
          ) : (
            <>
              <p className="mt-2 font-medium">{selected.name}</p>
              <p className="text-xs text-muted-foreground">{formatIDR(selected.price)} / item</p>
              <div className="mt-3 flex items-center gap-3">
                <button onClick={() => setQty((q) => Math.max(1, q - 1))} className="rounded-md border p-2" aria-label="Kurangi jumlah"><Minus className="h-4 w-4" /></button>
                <span className="w-8 text-center font-bold">{qty}</span>
                <button onClick={() => setQty((q) => q + 1)} className="rounded-md border p-2" aria-label="Tambah jumlah"><Plus className="h-4 w-4" /></button>
                <span className="ml-auto text-lg font-bold text-primary">{formatIDR(total)}</span>
              </div>

              <div className="mt-4 inline-flex rounded-md border p-0.5 text-sm">
                <button onClick={() => { if (scanning) { ctrlRef.current?.stop(); ctrlRef.current = null; setScanning(false); } setMethod("qr"); }} className={`px-3 py-1.5 rounded ${method === "qr" ? "bg-secondary" : "text-muted-foreground"}`}>QR Code</button>
                <button onClick={() => setMethod("nfc")} className={`px-3 py-1.5 rounded ${method === "nfc" ? "bg-secondary" : "text-muted-foreground"}`}>NFC</button>
              </div>

              {method === "qr" ? (
                <div className="mt-4 space-y-3">
                  <QrScannerBox onResult={handleQr} disabled={processing} />
                  <div>
                    <label className="text-sm font-medium">Nomor member manual</label>
                    <div className="mt-1 flex gap-2">
                      <input value={manualMember} onChange={(e) => setManualMember(e.target.value.toUpperCase())} placeholder="mis. SJR24-00019" className="flex-1 rounded-md border bg-background px-3 py-2 text-sm font-mono" />
                      <button onClick={() => manualMember && buy(manualMember.trim(), "member")} disabled={!manualMember || processing} className="rounded-md bg-secondary px-4 py-2 text-sm font-medium hover:bg-muted disabled:opacity-50">Bayar</button>
                    </div>
                  </div>
                </div>
              ) : (
                <div className="mt-4 space-y-3">
                  {support === "supported" ? (
                    <button onClick={toggleNfc} disabled={processing} className="inline-flex w-full items-center justify-center gap-2 rounded-full bg-primary px-6 py-3 text-sm font-semibold text-primary-foreground disabled:opacity-50">
                      {processing ? <Loader2 className="h-4 w-4 animate-spin" /> : <Radio className="h-4 w-4" />}
                      {scanning ? "Berhenti scan" : "Tap kartu / HP NFC"}
                    </button>
                  ) : (
                    <p className="text-xs text-muted-foreground">
                      {support === "insecure" ? "NFC butuh HTTPS." : "Perangkat ini tidak mendukung Web NFC. Pakai QR Code atau input UID manual."}
                    </p>
                  )}
                  <div>
                    <label className="text-sm font-medium">UID kartu manual</label>
                    <div className="mt-1 flex gap-2">
                      <input value={manualUid} onChange={(e) => setManualUid(e.target.value.toUpperCase())} placeholder="mis. 04A1B2C3" className="flex-1 rounded-md border bg-background px-3 py-2 text-sm font-mono" />
                      <button onClick={() => manualUid && buy(manualUid.trim(), "uid")} disabled={!manualUid || processing} className="rounded-md bg-secondary px-4 py-2 text-sm font-medium hover:bg-muted disabled:opacity-50">Bayar</button>
                    </div>
                  </div>
                </div>
              )}
              {processing && <p className="mt-3 flex items-center gap-2 text-xs text-muted-foreground"><Loader2 className="h-3 w-3 animate-spin" />Memproses…</p>}
            </>
          )}
        </div>

        {result && (
          <div className={`card-surface p-5 border-l-4 ${result.ok ? "border-l-success" : "border-l-destructive"}`}>
            <div className="flex items-start gap-3">
              {result.ok ? <CheckCircle2 className="h-6 w-6 text-success shrink-0" /> : <XCircle className="h-6 w-6 text-destructive shrink-0" />}
              <div className="flex-1">
                {result.ok ? (
                  <>
                    <p className="font-semibold text-success">Pembelian berhasil</p>
                    <p className="mt-1 text-lg font-bold">{result.participant_name}</p>
                    <p className="text-sm text-muted-foreground">{result.product_name} × {result.qty}</p>
                    <div className="mt-3 grid grid-cols-2 gap-3 text-sm">
                      <div><p className="text-xs text-muted-foreground">Dipotong</p><p className="font-semibold">{formatIDR(result.cost)}</p></div>
                      <div><p className="text-xs text-muted-foreground">Sisa saldo</p><p className="font-semibold">{formatIDR(result.balance_after)}</p></div>
                    </div>
                  </>
                ) : (
                  <>
                    <p className="font-semibold text-destructive">{result.error}</p>
                    {result.participant && (
                      <p className="mt-1 text-sm text-muted-foreground">
                        {result.participant.name} · saldo {formatIDR(result.participant.balance)}
                        {result.cost != null && <> · butuh {formatIDR(result.cost)}</>}
                      </p>
                    )}
                  </>
                )}
              </div>
            </div>
          </div>
        )}

        <div className="card-surface p-4 text-xs text-muted-foreground">
          <p className="mb-1 flex items-center gap-1.5 font-semibold text-foreground"><ScanLine className="h-3.5 w-3.5" />Cara pakai</p>
          <ul className="list-disc space-y-1 pl-4">
            <li>Pilih produk → atur jumlah → tap kartu atau scan QR member.</li>
            <li>Saldo peserta otomatis terpotong dan tercatat di Riwayat.</li>
          </ul>
        </div>
      </div>
    </div>
  );
}
