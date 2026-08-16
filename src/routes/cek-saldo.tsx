import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useRef, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { formatIDR, formatDateTime } from "@/lib/format";
import { detectNfcSupport, startNfcScan, type NfcScanController } from "@/lib/nfc";
import { toast } from "sonner";
import { ArrowDownRight, ArrowUpRight, Nfc, Search, Lock } from "lucide-react";
import logoAsset from "@/assets/logo-sjr.png.asset.json";

export const Route = createFileRoute("/cek-saldo")({
  head: () => ({
    meta: [
      { title: "Cek Saldo Member · Absensi SJR" },
      { name: "description", content: "Cek sisa saldo dan riwayat transaksi member Absensi SJR dengan tempel kartu NFC atau isi nomor member." },
      { property: "og:title", content: "Cek Saldo Member · Absensi SJR" },
      { property: "og:description", content: "Cek sisa saldo dan riwayat transaksi member dengan kartu NFC atau nomor member." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: Page,
});

type Tx = {
  id: string;
  tx_type: "attendance" | "topup" | "adjustment" | "purchase";
  amount: number;
  balance_after: number;
  note: string | null;
  qty: number | null;
  created_at: string;
};

type Result =
  | { ok: true; name: string; member_no: string | null; balance: number; has_pin?: boolean; transactions: Tx[] }
  | { ok: false; error: string; pin_required?: boolean };

const LABEL: Record<Tx["tx_type"], string> = {
  attendance: "Absen",
  topup: "Top Up",
  purchase: "Produk",
  adjustment: "Penyesuaian",
};

function Page() {
  const [memberNo, setMemberNo] = useState("");
  const [loading, setLoading] = useState(false);
  const [nfcOn, setNfcOn] = useState(false);
  const [data, setData] = useState<Extract<Result, { ok: true }> | null>(null);
  const [pin, setPin] = useState("");
  const [pendingPin, setPendingPin] = useState<{ _card_uid?: string; _member_no?: string } | null>(null);
  const ctrlRef = useRef<NfcScanController | null>(null);
  const [nfc, setNfc] = useState<ReturnType<typeof detectNfcSupport>>("unsupported");

  useEffect(() => { setNfc(detectNfcSupport()); }, []);
  useEffect(() => () => ctrlRef.current?.stop(), []);

  async function lookup(args: { _card_uid?: string; _member_no?: string }, pinValue?: string) {
    setLoading(true);
    try {
      const { data: res, error } = await supabase.rpc("member_lookup", {
        _card_uid: args._card_uid ?? undefined,
        _member_no: args._member_no ?? undefined,
        _pin: pinValue ?? undefined,

      });
      if (error) throw error;
      const r = res as unknown as Result;
      if (!r.ok) {
        setData(null);
        if (r.pin_required) {
          setPendingPin(args);
          setPin("");
        } else {
          setPendingPin(null);
        }
        toast.error(r.error);
        return;
      }
      setPendingPin(null);
      setPin("");
      setData(r);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Gagal mengambil data");
    } finally {
      setLoading(false);
    }
  }

  async function toggleNfc() {
    if (nfcOn) {
      ctrlRef.current?.stop();
      ctrlRef.current = null;
      setNfcOn(false);
      return;
    }
    if (nfc !== "supported") {
      toast.error(nfc === "insecure" ? "NFC butuh koneksi HTTPS." : "HP/browser ini tidak mendukung NFC. Gunakan nomor member.");
      return;
    }
    setNfcOn(true);
    ctrlRef.current = await startNfcScan(
      (uid) => lookup({ _card_uid: uid }),
      (err) => {
        toast.error(err.message);
        setNfcOn(false);
      },
    );
  }


  return (
    <div className="pitch-bg min-h-screen px-4 py-8">
      <div className="mx-auto w-full max-w-xl">
        <div className="text-center mb-6">
          <img src={logoAsset.url} alt="Logo SJR Cilegon" className="mx-auto h-20 w-auto object-contain" />
          <div className="mt-4 inline-flex items-center gap-2 rounded-full bg-primary/10 text-primary px-3 py-1 text-xs font-semibold uppercase tracking-wider">⚽ Absensi SJR</div>
          <h1 className="mt-4 text-3xl font-bold">Cek Saldo Member</h1>
          <p className="mt-2 text-sm text-muted-foreground">Tempelkan kartu ke HP (NFC) atau masukkan nomor member Anda.</p>
        </div>

        <div className="card-surface p-5 space-y-4">
          <button
            onClick={toggleNfc}
            className={`w-full inline-flex items-center justify-center gap-2 rounded-md py-3 text-sm font-semibold transition ${nfcOn ? "bg-destructive text-destructive-foreground" : "bg-primary text-primary-foreground hover:opacity-90"}`}
          >
            <Nfc className="h-4 w-4" />
            {nfcOn ? "Berhenti memindai — tempel kartu…" : "Tempel Kartu (NFC)"}
          </button>

          <div className="flex items-center gap-3 text-xs text-muted-foreground">
            <span className="h-px flex-1 bg-border" />atau<span className="h-px flex-1 bg-border" />
          </div>

          <form
            onSubmit={(e) => {
              e.preventDefault();
              if (memberNo.trim()) lookup({ _member_no: memberNo.trim() });
            }}
            className="flex gap-2"
          >
            <input
              value={memberNo}
              onChange={(e) => setMemberNo(e.target.value)}
              placeholder="Nomor member, mis. SJR24-00001"
              className="flex-1 rounded-md border bg-background px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-ring"
            />
            <button disabled={loading} className="inline-flex items-center gap-1.5 rounded-md border px-4 py-2 text-sm font-semibold hover:bg-muted disabled:opacity-50">
              <Search className="h-4 w-4" />Cek
            </button>
          </form>

          {pendingPin && (
            <form
              onSubmit={(e) => {
                e.preventDefault();
                if (/^\d{4}$/.test(pin)) lookup(pendingPin, pin);
                else toast.error("PIN harus 4 digit angka");
              }}
              className="rounded-lg border bg-muted/40 p-4"
            >
              <div className="flex items-center gap-2 text-sm font-semibold">
                <Lock className="h-4 w-4 text-primary" />Akun ini dilindungi PIN
              </div>
              <p className="mt-1 text-xs text-muted-foreground">Masukkan 4 digit PIN member untuk melihat saldo dan riwayat.</p>
              <div className="mt-3 flex gap-2">
                <input
                  value={pin}
                  onChange={(e) => setPin(e.target.value.replace(/\D/g, "").slice(0, 4))}
                  inputMode="numeric"
                  autoComplete="off"
                  maxLength={4}
                  placeholder="••••"
                  className="flex-1 rounded-md border bg-background px-3 py-2 text-center text-lg font-semibold tracking-[0.5em] outline-none focus:ring-2 focus:ring-ring"
                />
                <button disabled={loading} className="rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground disabled:opacity-50">Buka</button>
              </div>
            </form>
          )}
        </div>


        {data && (
          <div className="mt-6 space-y-4">
            <div className="card-surface p-5">
              <p className="text-xs uppercase tracking-wider text-muted-foreground">Saldo saat ini</p>
              <p className="mt-1 text-3xl font-bold">{formatIDR(data.balance)}</p>
              <p className="mt-2 text-sm font-medium">{data.name}</p>
              {data.member_no && <p className="font-mono text-xs text-muted-foreground">{data.member_no}</p>}
            </div>

            <div className="card-surface overflow-hidden">
              <div className="border-b px-4 py-3 text-sm font-semibold">Riwayat Transaksi (30 terakhir)</div>
              <ul className="divide-y">
                {data.transactions.map((t) => {
                  const neg = Number(t.amount) < 0;
                  return (
                    <li key={t.id} className="flex items-center justify-between gap-3 px-4 py-3">
                      <div className="min-w-0">
                        <div className="flex items-center gap-2">
                          <span className="rounded-full bg-muted px-2 py-0.5 text-[11px] font-medium">{LABEL[t.tx_type]}</span>
                          <span className="truncate text-xs text-muted-foreground">{t.note ?? "—"}</span>
                        </div>
                        <div className="mt-1 text-[11px] text-muted-foreground">{formatDateTime(t.created_at)}</div>
                      </div>
                      <div className="text-right">
                        <div className={`inline-flex items-center gap-1 font-semibold ${neg ? "text-destructive" : "text-success"}`}>
                          {neg ? <ArrowDownRight className="h-3 w-3" /> : <ArrowUpRight className="h-3 w-3" />}
                          {formatIDR(Math.abs(Number(t.amount)))}
                        </div>
                        <div className="text-[11px] text-muted-foreground">Sisa {formatIDR(t.balance_after)}</div>
                      </div>
                    </li>
                  );
                })}
                {data.transactions.length === 0 && <li className="px-4 py-8 text-center text-sm text-muted-foreground">Belum ada transaksi.</li>}
              </ul>
            </div>
          </div>
        )}

      </div>
    </div>
  );
}
