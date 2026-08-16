import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { formatIDR } from "@/lib/format";
import { toast } from "sonner";
import { Wallet } from "lucide-react";

export const Route = createFileRoute("/_authenticated/topup")({
  head: () => ({ meta: [{ title: "Top Up Saldo · Absensi SJR" }, { name: "description", content: "Tambah saldo prabayar peserta." }] }),
  component: Page,
});

type P = { id: string; name: string; card_uid: string; balance: number };

function Page() {
  const qc = useQueryClient();
  const [pid, setPid] = useState("");
  const [amount, setAmount] = useState<number>(50000);
  const [note, setNote] = useState("");
  const [loading, setLoading] = useState(false);

  const q = useQuery({
    queryKey: ["participants", "topup-list"],
    queryFn: async () => {
      const { data, error } = await supabase.from("participants").select("id,name,card_uid,balance").order("name");
      if (error) throw error;
      return data as P[];
    },
  });

  const selected = q.data?.find((p) => p.id === pid);

  async function submit() {
    if (!pid || amount <= 0) { toast.error("Pilih peserta & isi nominal"); return; }
    setLoading(true);
    try {
      const { data, error } = await supabase.rpc("topup_balance", { _participant_id: pid, _amount: amount, _note: note || undefined });
      if (error) throw error;
      const r = data as { ok: boolean; balance_after: number };
      toast.success(`Saldo baru: ${formatIDR(r.balance_after)}`);
      setAmount(50000); setNote("");
      qc.invalidateQueries({ queryKey: ["participants"] });
      qc.invalidateQueries({ queryKey: ["transactions"] });
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Gagal");
    } finally { setLoading(false); }
  }

  const presets = [20000, 50000, 100000, 200000];

  return (
    <div className="max-w-xl">
      <h1 className="text-2xl font-bold mb-1">Top Up Saldo</h1>
      <p className="text-sm text-muted-foreground mb-6">Tambah saldo prabayar untuk peserta.</p>
      <div className="card-surface p-6 space-y-4">
        <div>
          <label className="text-sm font-medium">Peserta</label>
          <select value={pid} onChange={(e)=>setPid(e.target.value)} className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm">
            <option value="">— pilih peserta —</option>
            {q.data?.map((p) => (
              <option key={p.id} value={p.id}>{p.name} · {p.card_uid} · {formatIDR(p.balance)}</option>
            ))}
          </select>
        </div>
        {selected && (
          <div className="rounded-lg bg-muted p-3 flex items-center gap-3">
            <Wallet className="h-5 w-5 text-primary" />
            <div className="flex-1">
              <p className="font-semibold">{selected.name}</p>
              <p className="text-xs text-muted-foreground">Saldo saat ini</p>
            </div>
            <p className="font-bold">{formatIDR(selected.balance)}</p>
          </div>
        )}
        <div>
          <label className="text-sm font-medium">Nominal</label>
          <input type="number" min="0" step="1000" value={amount} onChange={(e)=>setAmount(Number(e.target.value))} className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-lg font-semibold" />
          <div className="mt-2 flex flex-wrap gap-2">
            {presets.map((v) => (
              <button key={v} onClick={() => setAmount(v)} className="rounded-full border px-3 py-1 text-xs hover:bg-muted">{formatIDR(v)}</button>
            ))}
          </div>
        </div>
        <div>
          <label className="text-sm font-medium">Catatan (opsional)</label>
          <input value={note} onChange={(e)=>setNote(e.target.value)} placeholder="mis. tunai" className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm" />
        </div>
        {selected && amount > 0 && (
          <div className="text-sm text-muted-foreground">Saldo setelah top up: <span className="font-semibold text-foreground">{formatIDR(Number(selected.balance) + amount)}</span></div>
        )}
        <button onClick={submit} disabled={loading || !pid || amount <= 0} className="w-full rounded-md bg-primary py-3 font-semibold text-primary-foreground disabled:opacity-50">
          {loading ? "Memproses…" : "Top Up"}
        </button>
      </div>
    </div>
  );
}
