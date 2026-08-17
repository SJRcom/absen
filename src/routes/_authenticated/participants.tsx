import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { formatIDR } from "@/lib/format";
import { buildMemberQr } from "@/lib/qr";
import { toast } from "sonner";
import { Plus, Pencil, Trash2, X, QrCode, Download, KeyRound } from "lucide-react";

export const Route = createFileRoute("/_authenticated/participants")({
  head: () => ({ meta: [{ title: "Peserta · Absensi SJR" }, { name: "description", content: "Kelola daftar peserta, UID kartu, nomor member, PIN, dan QR Code absensi." }] }),
  component: Page,
});

type Participant = {
  id: string; name: string; card_uid: string; rate_multiplier: number;
  balance: number; note: string | null; member_no: string | null; phone: string | null;
  pin_hash?: string | null;
};


function nextMemberNo(list: Participant[] | undefined): string {
  const max = (list ?? []).reduce((acc, p) => {
    const m = p.member_no?.match(/(\d+)\s*$/);
    return m ? Math.max(acc, Number(m[1])) : acc;
  }, 0);
  return `MBR-${String(max + 1).padStart(4, "0")}`;
}

function Page() {
  const qc = useQueryClient();
  const [editing, setEditing] = useState<Partial<Participant> | null>(null);
  const [qrFor, setQrFor] = useState<Participant | null>(null);
  const [pinFor, setPinFor] = useState<Participant | null>(null);
  const [search, setSearch] = useState("");


  const q = useQuery({
    queryKey: ["participants"],
    queryFn: async () => {
      const { data, error } = await supabase.from("participants").select("*").order("name");
      if (error) throw error;
      return data as Participant[];
    },
  });

  async function save() {
    if (!editing) return;
    const name = editing.name?.trim();
    const card_uid = editing.card_uid?.trim().toUpperCase();
    if (!name || !card_uid) { toast.error("Nama & UID wajib"); return; }
    const member_no = editing.member_no?.trim() || nextMemberNo(q.data);
    const payload = {
      name, card_uid, member_no,
      phone: editing.phone?.trim() || null,
      rate_multiplier: Number(editing.rate_multiplier) || 1,
      note: editing.note ?? null,
    };
    const { error } = editing.id
      ? await supabase.from("participants").update(payload).eq("id", editing.id)
      : await supabase.from("participants").insert({ ...payload, balance: 0 });
    if (error) { toast.error(error.message); return; }
    toast.success("Tersimpan");
    setEditing(null);
    qc.invalidateQueries({ queryKey: ["participants"] });
  }

  async function remove(id: string) {
    if (!confirm("Hapus peserta ini?")) return;
    const { error } = await supabase.from("participants").delete().eq("id", id);
    if (error) { toast.error(error.message); return; }
    toast.success("Terhapus");
    qc.invalidateQueries({ queryKey: ["participants"] });
  }

  const s = search.toLowerCase();
  const filtered = q.data?.filter((p) =>
    p.name.toLowerCase().includes(s) ||
    p.card_uid.includes(search.toUpperCase()) ||
    (p.member_no ?? "").toLowerCase().includes(s) ||
    (p.phone ?? "").includes(search),
  ) ?? [];

  return (
    <div>
      <div className="flex flex-wrap items-center justify-between gap-3 mb-4">
        <div>
          <h1 className="text-2xl font-bold">Peserta</h1>
          <p className="text-sm text-muted-foreground">Total: {q.data?.length ?? 0} orang</p>
        </div>
        <button onClick={() => setEditing({ rate_multiplier: 1, member_no: nextMemberNo(q.data) })} className="inline-flex items-center gap-2 rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground">
          <Plus className="h-4 w-4" />Tambah peserta
        </button>
      </div>
      <input value={search} onChange={(e)=>setSearch(e.target.value)} placeholder="Cari nama, no. member, HP, atau UID…" className="mb-4 w-full max-w-sm rounded-md border bg-background px-3 py-2 text-sm" />
      <div className="card-surface overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="bg-muted/50 text-left">
              <tr>
                <th className="px-4 py-3 font-semibold">Nama</th>
                <th className="px-4 py-3 font-semibold">No. Member</th>
                <th className="px-4 py-3 font-semibold">No. HP</th>
                <th className="px-4 py-3 font-semibold">UID Kartu</th>
                <th className="px-4 py-3 font-semibold text-right">Pengali</th>
                <th className="px-4 py-3 font-semibold text-right">Saldo</th>
                <th className="px-4 py-3"></th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((p) => (
                <tr key={p.id} className="border-t hover:bg-muted/30">
                  <td className="px-4 py-3 font-medium">{p.name}{p.note && <span className="ml-2 text-xs text-muted-foreground">· {p.note}</span>}</td>
                  <td className="px-4 py-3 font-mono text-xs">
                    {p.member_no ?? "—"}
                    {p.pin_hash && <span className="ml-2 rounded-full bg-primary/10 px-2 py-0.5 font-sans text-[10px] font-semibold text-primary">PIN</span>}
                  </td>
                  <td className="px-4 py-3 text-xs">{p.phone ?? "—"}</td>
                  <td className="px-4 py-3 font-mono text-xs">{p.card_uid}</td>
                  <td className="px-4 py-3 text-right">{Number(p.rate_multiplier).toFixed(2)}×</td>
                  <td className="px-4 py-3 text-right font-semibold">{formatIDR(p.balance)}</td>
                  <td className="px-4 py-3 text-right whitespace-nowrap">
                    <button title="QR Code" onClick={() => setQrFor(p)} className="inline-flex items-center gap-1 rounded-md p-1.5 hover:bg-muted"><QrCode className="h-4 w-4" /></button>
                    <button title="PIN cek saldo" onClick={() => setPinFor(p)} className="inline-flex items-center gap-1 rounded-md p-1.5 hover:bg-muted"><KeyRound className="h-4 w-4" /></button>
                    <button title="Edit" onClick={() => setEditing(p)} className="inline-flex items-center gap-1 rounded-md p-1.5 hover:bg-muted"><Pencil className="h-4 w-4" /></button>

                    <button title="Hapus" onClick={() => remove(p.id)} className="inline-flex items-center gap-1 rounded-md p-1.5 hover:bg-destructive/10 text-destructive"><Trash2 className="h-4 w-4" /></button>
                  </td>
                </tr>
              ))}
              {filtered.length === 0 && <tr><td colSpan={7} className="px-4 py-8 text-center text-muted-foreground">Belum ada peserta.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>

      {editing && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={() => setEditing(null)}>
          <div className="card-surface p-6 w-full max-w-md max-h-[90vh] overflow-y-auto" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-lg font-bold">{editing.id ? "Edit peserta" : "Tambah peserta"}</h2>
              <button onClick={() => setEditing(null)}><X className="h-5 w-5" /></button>
            </div>
            <div className="space-y-3">
              <Field label="Nama"><input value={editing.name ?? ""} onChange={(e)=>setEditing({ ...editing, name: e.target.value })} className="w-full rounded-md border bg-background px-3 py-2 text-sm" /></Field>
              <Field label="Nomor member (untuk QR Code)"><input value={editing.member_no ?? ""} onChange={(e)=>setEditing({ ...editing, member_no: e.target.value })} placeholder="mis. SJR24-00019" className="w-full rounded-md border bg-background px-3 py-2 text-sm font-mono" /></Field>
              <Field label="Nomor HP"><input value={editing.phone ?? ""} onChange={(e)=>setEditing({ ...editing, phone: e.target.value })} placeholder="08xxxxxxxxxx" className="w-full rounded-md border bg-background px-3 py-2 text-sm" /></Field>
              <Field label="UID kartu (hex)"><input value={editing.card_uid ?? ""} onChange={(e)=>setEditing({ ...editing, card_uid: e.target.value })} placeholder="04A1B2C3" className="w-full rounded-md border bg-background px-3 py-2 text-sm font-mono" /></Field>
              <Field label="Pengali tarif (0.5 = diskon 50%, 1 = normal, 1.5 = tambah 50%)">
                <input type="number" step="0.05" min="0" value={editing.rate_multiplier ?? 1} onChange={(e)=>setEditing({ ...editing, rate_multiplier: Number(e.target.value) })} className="w-full rounded-md border bg-background px-3 py-2 text-sm" />
              </Field>
              <Field label="Catatan (opsional)"><input value={editing.note ?? ""} onChange={(e)=>setEditing({ ...editing, note: e.target.value })} className="w-full rounded-md border bg-background px-3 py-2 text-sm" /></Field>
              <button onClick={save} className="w-full rounded-md bg-primary py-2.5 text-sm font-semibold text-primary-foreground">Simpan</button>
            </div>
          </div>
        </div>
      )}

      {qrFor && <QrModal participant={qrFor} onClose={() => setQrFor(null)} />}
      {pinFor && (
        <PinModal
          participant={pinFor}
          onClose={() => setPinFor(null)}
          onSaved={() => { setPinFor(null); qc.invalidateQueries({ queryKey: ["participants"] }); }}
        />
      )}
    </div>

  );
}

function QrModal({ participant, onClose }: { participant: Participant; onClose: () => void }) {
  const [src, setSrc] = useState<string>("");

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const QRCode = (await import("qrcode")).default;
      const url = await QRCode.toDataURL(buildMemberQr(participant), { width: 512, margin: 1 });
      if (!cancelled) setSrc(url);
    })().catch(() => toast.error("Gagal membuat QR Code"));
    return () => { cancelled = true; };
  }, [participant]);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div className="card-surface p-6 w-full max-w-xs text-center" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-3">
          <h2 className="text-lg font-bold">QR Member</h2>
          <button onClick={onClose}><X className="h-5 w-5" /></button>
        </div>
        {src ? <img src={src} alt={`QR Code member ${participant.name}`} className="mx-auto w-full rounded-md border bg-white p-2" /> : <div className="aspect-square animate-pulse rounded-md bg-muted" />}
        <p className="mt-3 font-semibold">{participant.name}</p>
        <p className="font-mono text-xs text-muted-foreground">{participant.member_no ?? "—"}</p>
        <p className="text-xs text-muted-foreground">{participant.phone ?? "—"}</p>
        {src && (
          <a href={src} download={`qr-${participant.member_no ?? participant.name}.png`} className="mt-4 inline-flex w-full items-center justify-center gap-2 rounded-md bg-primary py-2 text-sm font-semibold text-primary-foreground">
            <Download className="h-4 w-4" />Unduh QR
          </a>
        )}
      </div>
    </div>
  );
}


function PinModal({ participant, onClose, onSaved }: { participant: Participant; onClose: () => void; onSaved: () => void }) {
  const [pin, setPin] = useState("");
  const [busy, setBusy] = useState(false);

  async function save(value: string) {
    setBusy(true);
    try {
      const { data, error } = await supabase.rpc("set_member_pin", { _participant_id: participant.id, _pin: value });
      if (error) throw error;
      const r = data as unknown as { ok: boolean; error?: string };
      if (!r.ok) { toast.error(r.error ?? "Gagal"); return; }
      toast.success(value ? "PIN tersimpan" : "PIN dihapus");
      onSaved();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Gagal");
    } finally { setBusy(false); }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div className="card-surface w-full max-w-xs p-6" onClick={(e) => e.stopPropagation()}>
        <div className="mb-3 flex items-center justify-between">
          <h2 className="text-lg font-bold">PIN Cek Saldo</h2>
          <button onClick={onClose}><X className="h-5 w-5" /></button>
        </div>
        <p className="text-xs text-muted-foreground">
          PIN 4 digit opsional untuk <b>{participant.name}</b>. Bila diisi, halaman cek saldo publik wajib meminta PIN ini.
        </p>
        <input
          value={pin}
          onChange={(e) => setPin(e.target.value.replace(/\D/g, "").slice(0, 4))}
          inputMode="numeric"
          maxLength={4}
          placeholder="••••"
          className="mt-4 w-full rounded-md border bg-background px-3 py-2 text-center text-lg font-semibold tracking-[0.5em]"
        />
        <button
          disabled={busy || pin.length !== 4}
          onClick={() => save(pin)}
          className="mt-3 w-full rounded-md bg-primary py-2.5 text-sm font-semibold text-primary-foreground disabled:opacity-50"
        >
          Simpan PIN
        </button>
        {participant.pin_hash && (
          <button disabled={busy} onClick={() => save("")} className="mt-2 w-full rounded-md border py-2 text-sm font-medium hover:bg-muted disabled:opacity-50">
            Hapus PIN
          </button>
        )}
      </div>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {

  return <div><label className="text-xs font-medium text-muted-foreground">{label}</label><div className="mt-1">{children}</div></div>;
}
