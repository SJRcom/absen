import { useCallback, useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { detectNfcSupport, type NfcSupport } from "@/lib/nfc";
import {
  CheckCircle2,
  History,
  Loader2,
  Nfc,
  Radio,
  ScanLine,
  Smartphone,
  XCircle,
} from "lucide-react";

// Endpoint PHP di server website utama (warlist.sjr-komunitas.com).
// Bisa diganti saat build via env VITE_BAYAR_ENDPOINT (mis. api_bayar.php),
// tanpa mengubah kode — lihat .env.example & DEPLOYMENT.md.
const BAYAR_ENDPOINT =
  import.meta.env.VITE_BAYAR_ENDPOINT || "https://warlist.sjr-komunitas.com/bayarmabol.php";
const REQUEST_TIMEOUT_MS = 10_000;
const MAX_HISTORY = 30;

type HistoryEntry = {
  id: number;
  member: string;
  status: "success" | "error";
  message: string;
  time: string;
};

// decode NDEF text record: status byte (lang code length) + language + text
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function decodeTextRecord(record: any): string | null {
  if (!record || record.recordType !== "text") return null;
  const data = record.data;
  if (typeof data === "string") return data;
  if (data instanceof DataView) {
    try {
      const bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
      if (bytes.length === 0) return null;
      const langLen = bytes[0] & 0x3f;
      return new TextDecoder().decode(bytes.subarray(langLen + 1));
    } catch {
      return null;
    }
  }
  return null;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.trim() ? v.trim() : undefined;
}

export function NfcAbsenScanner() {
  const support: NfcSupport = typeof window === "undefined" ? "unsupported" : detectNfcSupport();

  const [input, setInput] = useState("");
  const [processing, setProcessing] = useState(false);
  const [webNfcScanning, setWebNfcScanning] = useState(false);
  const [history, setHistory] = useState<HistoryEntry[]>([]);

  const inputRef = useRef<HTMLInputElement>(null);
  const webNfcCtrlRef = useRef<AbortController | null>(null);
  const idRef = useRef(0);

  useEffect(() => () => webNfcCtrlRef.current?.abort(), []);

  const pushHistory = useCallback(
    (member: string, status: "success" | "error", message: string) => {
      const entry: HistoryEntry = {
        id: ++idRef.current,
        member,
        status,
        message,
        time: new Date().toLocaleTimeString("id-ID", {
          hour: "2-digit",
          minute: "2-digit",
          second: "2-digit",
        }),
      };
      setHistory((prev) => [entry, ...prev].slice(0, MAX_HISTORY));
    },
    [],
  );

  const submit = useCallback(
    async (raw: string) => {
      const member = raw.trim().toUpperCase();
      if (!member) {
        toast.error("Nomor member kosong");
        return;
      }
      if (processing) return;

      setProcessing(true);
      try {
        const res = await fetch(BAYAR_ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ id_member: member }),
          signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        });

        // Respons PHP ini berupa teks polos (bukan JSON) — baca sekali sebagai teks,
        // lalu coba parse sebagai JSON untuk berjaga-jaga.
        const rawText = await res.text();
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        let data: any = {};
        try {
          data = JSON.parse(rawText);
        } catch {
          /* bukan JSON */
        }

        // Beberapa endpoint membungkus respons di dalam JSON {"respon": "…"} —
        // jika ada, gunakan isinya; kalau tidak, pakai body mentah.
        const inner = typeof data?.respon === "string" ? data.respon : rawText;

        // PHP membungkus respons dengan blok <script>…</script> (di awal & akhir) —
        // buang semua blok itu, sisanya adalah pesan teks dari server.
        const plain = inner
          .replace(/<script[\s\S]*?<\/script>/gi, "")
          .replace(/\r?\n/g, " ")
          .replace(/\s+/g, " ")
          .trim();

        const failText = /submit gagal|tidak boleh kosong/i.test(plain);
        const explicitFail =
          data?.success === false ||
          data?.ok === false ||
          data?.status === "error" ||
          typeof data?.error === "string";

        let message: string;
        if (explicitFail) {
          message =
            str(data?.error) ?? str(data?.message) ?? str(data?.pesan) ?? "Server menolak data";
        } else {
          const structured = str(data?.message) ?? str(data?.pesan) ?? str(data?.msg);
          if (structured) {
            message = structured;
          } else if (failText) {
            message = plain || "Server menolak data";
          } else if (plain) {
            message = plain;
          } else if (!res.ok) {
            message = `Server merespon ${res.status}`;
          } else {
            message = "Absen berhasil — data terkirim ke server";
          }
        }

        if (res.ok && !explicitFail && !failText) {
          toast.success(`${member} · ${message}`);
          pushHistory(member, "success", message);
        } else {
          toast.error(`${member} · ${message}`);
          pushHistory(member, "error", message);
        }
      } catch (e) {
        const message =
          e instanceof DOMException && e.name === "TimeoutError"
            ? "Koneksi timeout — server tidak merespon"
            : "Gagal terhubung ke server. Periksa koneksi internet.";
        toast.error(`${member} · ${message}`);
        pushHistory(member, "error", message);
      } finally {
        setProcessing(false);
        setInput("");
        inputRef.current?.focus();
      }
    },
    [processing, pushHistory],
  );

  function handleKeyDown(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key === "Enter" && input.trim()) {
      e.preventDefault();
      void submit(input);
    }
  }

  async function toggleWebNfc() {
    if (webNfcScanning) {
      webNfcCtrlRef.current?.abort();
      webNfcCtrlRef.current = null;
      setWebNfcScanning(false);
      return;
    }
    try {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const Reader = (window as any).NDEFReader;
      const ctrl = new AbortController();
      const reader = new Reader();
      await reader.scan({ signal: ctrl.signal });
      webNfcCtrlRef.current = ctrl;
      setWebNfcScanning(true);
      toast.info("NFC aktif — tempelkan kartu ke bagian belakang HP");

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      reader.onreading = (event: any) => {
        let value = "";
        try {
          const records = event?.message?.records ?? [];
          for (const rec of records) {
            const text = decodeTextRecord(rec);
            if (text) {
              value = text.trim();
              break;
            }
          }
        } catch {
          /* abaikan error parsing record */
        }
        if (!value && event?.serialNumber) {
          value = String(event.serialNumber).replace(/:/g, "");
        }
        if (value) void submit(value);
      };
      reader.onreadingerror = () => toast.error("Gagal membaca kartu. Coba tempel ulang.");
    } catch (e) {
      webNfcCtrlRef.current?.abort();
      webNfcCtrlRef.current = null;
      setWebNfcScanning(false);
      toast.error(e instanceof Error ? e.message : "Gagal memulai Web NFC");
    }
  }

  return (
    <div className="grid gap-6 lg:grid-cols-[1fr_340px]">
      <div className="card-surface p-6">
        <h2 className="text-lg font-bold">Tap kartu NFC</h2>
        <p className="mt-1 text-sm text-muted-foreground">
          Tempelkan kartu pada reader USB — nomor member terkirim otomatis ke server{" "}
          <span className="font-mono text-xs">bayarmabol.php</span>.
        </p>

        <div className="mt-5">
          <label className="text-sm font-medium">Nomor member (hasil scan)</label>
          <input
            ref={inputRef}
            value={input}
            onChange={(e) => setInput(e.target.value.toUpperCase())}
            onKeyDown={handleKeyDown}
            autoFocus
            autoComplete="off"
            autoCapitalize="characters"
            spellCheck={false}
            disabled={processing}
            placeholder="mis. SJR24-00013 — tap kartu pada reader…"
            className="mt-1 w-full rounded-md border bg-background px-3 py-3 font-mono text-base tracking-wider disabled:opacity-60"
          />
          <p className="mt-1 text-xs text-muted-foreground">
            Reader USB: fokus otomatis di kotak ini, lalu tap kartu. Tekan{" "}
            <kbd className="rounded border px-1 font-mono text-[10px]">Enter</kbd> untuk kirim
            manual.
          </p>
        </div>

        {support === "supported" && (
          <button
            onClick={() => void toggleWebNfc()}
            disabled={processing}
            className={`mt-4 inline-flex items-center gap-2 rounded-md px-4 py-2 text-sm font-semibold disabled:opacity-50 ${
              webNfcScanning ? "bg-secondary text-foreground" : "bg-primary text-primary-foreground"
            }`}
          >
            {webNfcScanning ? (
              <>
                <Radio className="h-4 w-4 animate-pulse" /> Scan aktif — tap kartu ke HP
              </>
            ) : (
              <>
                <Smartphone className="h-4 w-4" /> Scan via HP (Web NFC)
              </>
            )}
          </button>
        )}
        {support === "unsupported" && (
          <p className="mt-4 flex items-center gap-2 text-xs text-muted-foreground">
            <Smartphone className="h-3.5 w-3.5" /> Web NFC tidak didukung browser ini — pakai reader
            USB atau Chrome Android.
          </p>
        )}
        {support === "insecure" && (
          <p className="mt-4 flex items-center gap-2 text-xs text-muted-foreground">
            <Smartphone className="h-3.5 w-3.5" /> Web NFC butuh koneksi HTTPS.
          </p>
        )}

        {processing && (
          <p className="mt-4 flex items-center gap-2 text-sm text-muted-foreground">
            <Loader2 className="h-4 w-4 animate-spin" /> Mengirim ke server…
          </p>
        )}

        <div className="mt-6 flex items-center gap-3 border-t pt-4">
          <div className="flex h-12 w-12 items-center justify-center rounded-full bg-muted">
            {processing ? (
              <Loader2 className="h-6 w-6 animate-spin text-primary" />
            ) : (
              <Nfc className="h-6 w-6 text-primary" />
            )}
          </div>
          <p className="text-xs text-muted-foreground">
            Status terakhir:{" "}
            {history[0] ? (
              <span
                className={
                  history[0].status === "success"
                    ? "font-semibold text-success"
                    : "font-semibold text-destructive"
                }
              >
                {history[0].member} — {history[0].message}
              </span>
            ) : (
              "belum ada scan"
            )}
          </p>
        </div>
      </div>

      <div className="card-surface p-4">
        <div className="flex items-center justify-between">
          <h3 className="flex items-center gap-2 text-sm font-semibold">
            <History className="h-4 w-4" /> Riwayat scan
          </h3>
          <span className="rounded-full bg-muted px-2 py-0.5 text-[10px] text-muted-foreground">
            {history.length}/{MAX_HISTORY}
          </span>
        </div>
        {history.length === 0 ? (
          <p className="mt-3 text-xs text-muted-foreground">
            Belum ada scan. Tap kartu untuk mulai.
          </p>
        ) : (
          <ul className="mt-3 max-h-96 space-y-2 overflow-y-auto pr-1">
            {history.map((h) => (
              <li key={h.id} className="flex items-start gap-2 rounded-md border p-2">
                {h.status === "success" ? (
                  <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-success" />
                ) : (
                  <XCircle className="mt-0.5 h-4 w-4 shrink-0 text-destructive" />
                )}
                <div className="min-w-0 flex-1">
                  <p className="truncate font-mono text-xs font-semibold">{h.member}</p>
                  <p className="truncate text-[11px] text-muted-foreground">{h.message}</p>
                </div>
                <span className="shrink-0 text-[10px] text-muted-foreground">{h.time}</span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
