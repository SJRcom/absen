import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { formatIDR, formatDateTime } from "@/lib/format";
import { ArrowDownRight, ArrowUpRight } from "lucide-react";

export const Route = createFileRoute("/_authenticated/transactions")({
  head: () => ({ meta: [{ title: "Riwayat Transaksi · Absensi SJR" }, { name: "description", content: "Riwayat absensi dan top up saldo." }] }),
  component: Page,
});

type Tx = {
  id: string; tx_type: "attendance" | "topup" | "adjustment" | "purchase"; amount: number;
  balance_after: number; note: string | null; created_at: string;
  participants: { name: string; card_uid: string } | null;
  fields: { name: string } | null;
};

function Page() {
  const q = useQuery({
    queryKey: ["transactions"],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("transactions")
        .select("id,tx_type,amount,balance_after,note,created_at,participants(name,card_uid),fields(name)")
        .order("created_at", { ascending: false })
        .limit(200);
      if (error) throw error;
      return data as unknown as Tx[];
    },
  });

  const totalToday = q.data?.filter((t) => new Date(t.created_at).toDateString() === new Date().toDateString() && t.tx_type === "attendance").reduce((s, t) => s + Math.abs(Number(t.amount)), 0) ?? 0;
  const countToday = q.data?.filter((t) => new Date(t.created_at).toDateString() === new Date().toDateString() && t.tx_type === "attendance").length ?? 0;

  return (
    <div>
      <h1 className="text-2xl font-bold mb-1">Riwayat Transaksi</h1>
      <p className="text-sm text-muted-foreground mb-6">200 transaksi terakhir.</p>

      <div className="grid gap-4 sm:grid-cols-3 mb-6">
        <Stat label="Absen hari ini" value={String(countToday)} />
        <Stat label="Pendapatan hari ini" value={formatIDR(totalToday)} />
        <Stat label="Total transaksi" value={String(q.data?.length ?? 0)} />
      </div>

      <div className="card-surface overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="bg-muted/50 text-left">
              <tr>
                <th className="px-4 py-3 font-semibold">Waktu</th>
                <th className="px-4 py-3 font-semibold">Peserta</th>
                <th className="px-4 py-3 font-semibold">Keterangan</th>
                <th className="px-4 py-3 font-semibold text-right">Jumlah</th>
                <th className="px-4 py-3 font-semibold text-right">Saldo Akhir</th>
              </tr>
            </thead>
            <tbody>
              {q.data?.map((t) => {
                const neg = Number(t.amount) < 0;
                return (
                  <tr key={t.id} className="border-t hover:bg-muted/30">
                    <td className="px-4 py-3 text-xs text-muted-foreground whitespace-nowrap">{formatDateTime(t.created_at)}</td>
                    <td className="px-4 py-3">
                      <div className="font-medium">{t.participants?.name ?? "—"}</div>
                      <div className="font-mono text-[10px] text-muted-foreground">{t.participants?.card_uid}</div>
                    </td>
                    <td className="px-4 py-3">
                      <span className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium ${t.tx_type === "attendance" ? "bg-primary/10 text-primary" : t.tx_type === "topup" ? "bg-success/10 text-success" : t.tx_type === "purchase" ? "bg-warning/10 text-warning" : "bg-muted"}`}>
                        {t.tx_type === "attendance" ? "Absen" : t.tx_type === "topup" ? "Top Up" : t.tx_type === "purchase" ? "Produk" : "Adjust"}
                      </span>
                      {t.fields?.name && <span className="ml-2 text-xs text-muted-foreground">{t.fields.name}</span>}
                      {!t.fields?.name && t.note && <span className="ml-2 text-xs text-muted-foreground">{t.note}</span>}
                    </td>
                    <td className={`px-4 py-3 text-right font-semibold ${neg ? "text-destructive" : "text-success"}`}>
                      <span className="inline-flex items-center gap-1 justify-end">
                        {neg ? <ArrowDownRight className="h-3 w-3" /> : <ArrowUpRight className="h-3 w-3" />}
                        {formatIDR(Math.abs(Number(t.amount)))}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-right">{formatIDR(t.balance_after)}</td>
                  </tr>
                );
              })}
              {q.data && q.data.length === 0 && <tr><td colSpan={5} className="px-4 py-8 text-center text-muted-foreground">Belum ada transaksi.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="card-surface p-4">
      <p className="text-xs uppercase tracking-wider text-muted-foreground">{label}</p>
      <p className="mt-1 text-2xl font-bold">{value}</p>
    </div>
  );
}
