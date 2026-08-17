import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { detectNfcSupport, startNfcScan, type NfcScanController } from "@/lib/nfc";
import { parseMemberQr } from "@/lib/qr";
import { QrScannerBox } from "@/components/QrScannerBox";
import { formatIDR } from "@/lib/format";
import { toast } from "sonner";
import { ScanLine, Radio, CheckCircle2, XCircle, Loader2, Shield } from "lucide-react";

export const Route = createFileRoute("/_authenticated/scan")({
  head: () => ({ meta: [{ title: "Scan Kartu · Absensi SJR" }, { name: "description", content: "Tap kartu e-toll, HP NFC, atau scan QR Code member untuk absen dan bayar tiket lapangan." }] }),
  component: ScanPage,
});

type ScanResult =
  | { ok: true; participant_name: string; field_name?: string; event_name?: string; position_label?: string; cost: number; balance_after: number }
  | { ok: false; error: string; cost?: number; participant?: { name: string; balance: number } };

type Mode = "field" | "event";
type Method = "nfc" | "qr";

function ScanPage() {
  const support = typeof window === "undefined" ? "unsupported" : detectNfcSupport();
  const [mode, setMode] = useState<Mode>("field");
  const [method, setMethod] = useState<Method>("nfc");
  const [fieldId, setFieldId] = useState<string>("");
  const [eventId, setEventId] = useState<string>("");
  const [manualUid, setManualUid] = useState("");
  const [manualMember, setManualMember] = useState("");

  const [scanning, setScanning] = useState(false);
  const [processing, setProcessing] = useState(false);
  const [result, setResult] = useState<ScanResult | null>(null);
  const [lastUid, setLastUid] = useState<string>("");
  const ctrlRef = useRef<NfcScanController | null>(null);
  const lastRef = useRef<{ uid: string; at: number }>({ uid: "", at: 0 });


  const fieldsQ = useQuery({
    queryKey: ["fields", "active"],
    queryFn: async () => {
      const { data, error } = await supabase.from("fields").select("*").eq("active", true).order("name");
      if (error) throw error;
      return data;
    },
  });

  const eventsQ = useQuery({
    queryKey: ["events", "open"],
    queryFn: async () => {
      const { data, error } = await supabase.from("events").select("*").eq("status", "open").order("event_date", { ascending: false });
      if (error) throw error;
      return data;
    },
  });

  useEffect(() => {
    if (mode === "field" && fieldsQ.data && fieldsQ.data.length && !fieldId) setFieldId(fieldsQ.data[0].id);
    if (mode === "event" && eventsQ.data && eventsQ.data.length && !eventId) setEventId(eventsQ.data[0].id);
  }, [fieldsQ.data, eventsQ.data, fieldId, eventId, mode]);

  useEffect(() => () => { ctrlRef.current?.stop(); }, []);

  async function runScan(key: string, kind: "uid" | "member") {
    if (processing) return;
    const target = mode === "event" ? eventId : fieldId;
    const dedupeKey = `${mode}:${target}:${kind}:${key}`;
    const now = Date.now();
    if (dedupeKey === lastRef.current.uid && now - lastRef.current.at < 3000) return;
    lastRef.current = { uid: dedupeKey, at: now };
    setLastUid(kind === "member" ? `Member ${key}` : key);

    if (mode === "field" && !fieldId) { toast.error("Pilih lapangan dulu"); return; }
    if (mode === "event" && !eventId) { toast.error("Pilih event dulu"); return; }

    setProcessing(true);
    setResult(null);
    try {
      const call = () => {
        if (kind === "member") {
          return mode === "event"
            ? supabase.rpc("scan_member_event_and_pay", { _member_no: key, _event_id: eventId })
            : supabase.rpc("scan_member_and_pay", { _member_no: key, _field_id: fieldId });
        }
        return mode === "event"
          ? supabase.rpc("scan_event_and_pay", { _card_uid: key, _event_id: eventId })
          : supabase.rpc("scan_and_pay", { _card_uid: key, _field_id: fieldId });
      };
      const { data, error } = await call();
      if (error) throw error;
      const r = data as unknown as ScanResult;
      setResult(r);
      if (r.ok) toast.success(`${r.participant_name} · ${formatIDR(r.cost)}`);
      else toast.error(r.error);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Gagal");
    } finally { setProcessing(false); }
  }

  function handleUid(uid: string) {
    void runScan(uid, "uid");
  }

  function handleQr(text: string) {
    const parsed = parseMemberQr(text);
    if (!parsed) { toast.error("QR Code tidak dikenali"); return; }
    void runScan(parsed.member_no, "member");
  }


  async function toggleScan() {
    if (scanning) { ctrlRef.current?.stop(); ctrlRef.current = null; setScanning(false); return; }
    setScanning(true);
    ctrlRef.current = await startNfcScan(handleUid, (err) => {
      toast.error(err.message || "NFC error");
      setScanning(false);
    });
  }

  const selectedField = fieldsQ.data?.find((f) => f.id === fieldId);
  const selectedEvent = eventsQ.data?.find((e) => e.id === eventId);

  return (
    <div className="grid gap-6 lg:grid-cols-[1fr_360px]">
      <div className="card-surface p-6">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-2xl font-bold">Absen peserta</h1>
            <p className="text-sm text-muted-foreground">Tap kartu e-toll / HP NFC, atau scan QR Code member. Saldo peserta otomatis terpotong.</p>
          </div>
        </div>

        <div className="mt-6 flex flex-wrap gap-3">
          <div className="inline-flex rounded-md border p-0.5 text-sm">
            <button onClick={() => setMode("field")} className={`px-3 py-1.5 rounded ${mode === "field" ? "bg-primary text-primary-foreground" : "text-muted-foreground"}`}>Lapangan</button>
            <button onClick={() => setMode("event")} className={`px-3 py-1.5 rounded ${mode === "event" ? "bg-primary text-primary-foreground" : "text-muted-foreground"}`}>Event</button>
          </div>
          <div className="inline-flex rounded-md border p-0.5 text-sm">
            <button onClick={() => setMethod("nfc")} className={`px-3 py-1.5 rounded ${method === "nfc" ? "bg-secondary" : "text-muted-foreground"}`}>NFC</button>
            <button onClick={() => { if (scanning) { ctrlRef.current?.stop(); ctrlRef.current = null; setScanning(false); } setMethod("qr"); }} className={`px-3 py-1.5 rounded ${method === "qr" ? "bg-secondary" : "text-muted-foreground"}`}>QR Code</button>
          </div>
        </div>


        {mode === "field" ? (
          <div className="mt-4">
            <label className="text-sm font-medium">Lapangan aktif</label>
            {fieldsQ.data && fieldsQ.data.length === 0 ? (
              <p className="mt-2 text-sm text-muted-foreground">Belum ada lapangan. Buat dulu di menu Lapangan.</p>
            ) : (
              <select value={fieldId} onChange={(e) => setFieldId(e.target.value)} className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm">
                {fieldsQ.data?.map((f) => (
                  <option key={f.id} value={f.id}>{f.name} — {formatIDR(f.base_price)}</option>
                ))}
              </select>
            )}
          </div>
        ) : (
          <div className="mt-4">
            <label className="text-sm font-medium">Event aktif</label>
            {eventsQ.data && eventsQ.data.length === 0 ? (
              <p className="mt-2 text-sm text-muted-foreground">Belum ada event terbuka. Buat dulu di menu Event.</p>
            ) : (
              <select value={eventId} onChange={(e) => setEventId(e.target.value)} className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm">
                {eventsQ.data?.map((e) => (
                  <option key={e.id} value={e.id}>
                    {e.name} — {new Date(e.event_date).toLocaleDateString("id-ID", { day: "2-digit", month: "short" })}
                  </option>
                ))}
              </select>
            )}
          </div>
        )}

        {method === "nfc" ? (
          <div className="mt-8 flex flex-col items-center gap-4 py-8">
            <div className={`relative flex h-40 w-40 items-center justify-center rounded-full ${scanning ? "bg-primary/10" : "bg-muted"}`}>
              {scanning && <span className="absolute inset-0 rounded-full border-4 border-primary/50 animate-ping" />}
              {processing ? <Loader2 className="h-16 w-16 animate-spin text-primary" /> : <ScanLine className="h-16 w-16 text-primary" />}
            </div>
            {support === "supported" ? (
              <button onClick={toggleScan} disabled={processing || (mode === "field" ? !fieldId : !eventId)} className="inline-flex items-center gap-2 rounded-full bg-primary px-6 py-3 text-sm font-semibold text-primary-foreground disabled:opacity-50">
                <Radio className="h-4 w-4" />{scanning ? "Berhenti scan" : "Mulai scan NFC"}
              </button>
            ) : (
              <div className="text-center text-xs text-muted-foreground max-w-xs">
                {support === "insecure" ? "NFC butuh HTTPS." : "Perangkat/browser ini tidak mendukung Web NFC. Pakai mode QR Code, atau masukkan UID manual di bawah."}
              </div>
            )}
            {lastUid && <p className="text-xs text-muted-foreground">Terakhir: <span className="font-mono">{lastUid}</span></p>}
          </div>
        ) : (
          <div className="mt-6 space-y-4">
            <QrScannerBox onResult={handleQr} disabled={processing || (mode === "field" ? !fieldId : !eventId)} />
            <div>
              <label className="text-sm font-medium">Input nomor member manual</label>
              <div className="mt-1 flex gap-2">
                <input value={manualMember} onChange={(e) => setManualMember(e.target.value.toUpperCase())} placeholder="mis. SJR24-00019" className="flex-1 rounded-md border bg-background px-3 py-2 text-sm font-mono" />
                <button onClick={() => manualMember && runScan(manualMember.trim(), "member")} disabled={!manualMember || processing || (mode === "field" ? !fieldId : !eventId)} className="rounded-md bg-secondary px-4 py-2 text-sm font-medium hover:bg-muted disabled:opacity-50">Proses</button>
              </div>
            </div>
            {processing && <p className="flex items-center gap-2 text-xs text-muted-foreground"><Loader2 className="h-3 w-3 animate-spin" />Memproses…</p>}
            {lastUid && <p className="text-xs text-muted-foreground">Terakhir: <span className="font-mono">{lastUid}</span></p>}
          </div>
        )}
        {method === "nfc" && (
          <div className="mt-6 border-t pt-4">
            <label className="text-sm font-medium">Input UID manual</label>
            <div className="mt-1 flex gap-2">
              <input value={manualUid} onChange={(e)=>setManualUid(e.target.value.toUpperCase())} placeholder="mis. 04A1B2C3" className="flex-1 rounded-md border bg-background px-3 py-2 text-sm font-mono" />
              <button onClick={() => manualUid && handleUid(manualUid)} disabled={!manualUid || processing || (mode === "field" ? !fieldId : !eventId)} className="rounded-md bg-secondary px-4 py-2 text-sm font-medium hover:bg-muted disabled:opacity-50">
                Proses
              </button>
            </div>
          </div>
        )}

      </div>

      <div className="space-y-4">
        {mode === "field" && selectedField && (
          <div className="card-surface p-4">
            <p className="text-xs uppercase tracking-wider text-muted-foreground">Lapangan aktif</p>
            <p className="mt-1 font-semibold">{selectedField.name}</p>
            <p className="text-2xl font-bold text-primary">{formatIDR(selectedField.base_price)}</p>
            {selectedField.description && <p className="mt-1 text-xs text-muted-foreground">{selectedField.description}</p>}
          </div>
        )}
        {mode === "event" && selectedEvent && (
          <div className="card-surface p-4">
            <p className="text-xs uppercase tracking-wider text-muted-foreground">Event aktif</p>
            <p className="mt-1 font-semibold">{selectedEvent.name}</p>
            <p className="text-xs text-muted-foreground">
              {new Date(selectedEvent.event_date).toLocaleString("id-ID", { dateStyle: "medium", timeStyle: "short" })}
            </p>
            <div className="mt-3 grid grid-cols-3 gap-2 text-center text-xs">
              <div className="rounded border p-2">
                <p className="text-[10px] text-muted-foreground flex items-center justify-center gap-1"><Shield className="h-3 w-3" />GK</p>
                <p className="font-bold text-warning">{formatIDR(selectedEvent.gk_price)}</p>
              </div>
              <div className="rounded border p-2">
                <p className="text-[10px] text-muted-foreground">Pemain</p>
                <p className="font-bold text-primary">{formatIDR(selectedEvent.player_price)}</p>
              </div>
              <div className="rounded border p-2">
                <p className="text-[10px] text-muted-foreground">Cadangan</p>
                <p className="font-bold">{formatIDR(selectedEvent.reserve_price)}</p>
              </div>
            </div>
          </div>
        )}
        {result && (
          <div className={`card-surface p-5 border-l-4 ${result.ok ? "border-l-success" : "border-l-destructive"}`}>
            <div className="flex items-start gap-3">
              {result.ok ? <CheckCircle2 className="h-6 w-6 text-success shrink-0" /> : <XCircle className="h-6 w-6 text-destructive shrink-0" />}
              <div className="flex-1">
                {result.ok ? (
                  <>
                    <p className="font-semibold text-success">Absen berhasil</p>
                    <p className="mt-1 text-lg font-bold">{result.participant_name}</p>
                    <p className="text-sm text-muted-foreground">
                      {result.event_name ?? result.field_name}
                      {result.position_label && <> · {result.position_label}</>}
                    </p>
                    <div className="mt-3 grid grid-cols-2 gap-3 text-sm">
                      <div><p className="text-muted-foreground text-xs">Dipotong</p><p className="font-semibold">{formatIDR(result.cost)}</p></div>
                      <div><p className="text-muted-foreground text-xs">Sisa saldo</p><p className="font-semibold">{formatIDR(result.balance_after)}</p></div>
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
          <p className="font-semibold text-foreground mb-1">💡 Tips</p>
          <ul className="list-disc pl-4 space-y-1">
            <li>Mode <b>Event</b>: tarif otomatis mengikuti posisi peserta (GK/Pemain/Cadangan).</li>
            <li>Mode <b>Lapangan</b>: pakai harga dasar lapangan × pengali peserta.</li>
            <li>Peserta harus terdaftar di event dulu (menu Event → Kelola peserta).</li>
          </ul>
        </div>
      </div>
    </div>
  );
}
