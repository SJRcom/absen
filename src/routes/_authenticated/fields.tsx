import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { formatIDR } from "@/lib/format";
import { toast } from "sonner";
import { Plus, Pencil, Trash2, X, MapPin } from "lucide-react";

export const Route = createFileRoute("/_authenticated/fields")({
  head: () => ({ meta: [{ title: "Lapangan · Absensi SJR" }, { name: "description", content: "Kelola daftar lapangan dan harga tiket." }] }),
  component: Page,
});

type Field = { id: string; name: string; base_price: number; description: string | null; active: boolean };

function Page() {
  const qc = useQueryClient();
  const [editing, setEditing] = useState<Partial<Field> | null>(null);

  const q = useQuery({
    queryKey: ["fields"],
    queryFn: async () => {
      const { data, error } = await supabase.from("fields").select("*").order("name");
      if (error) throw error;
      return data as Field[];
    },
  });

  async function save() {
    if (!editing) return;
    const name = editing.name?.trim();
    const base_price = Number(editing.base_price) || 0;
    if (!name || base_price <= 0) { toast.error("Nama & harga wajib"); return; }
    const payload = {
      name, base_price,
      description: editing.description ?? null,
      active: editing.active ?? true,
    };
    const { error } = editing.id
      ? await supabase.from("fields").update(payload).eq("id", editing.id)
      : await supabase.from("fields").insert(payload);
    if (error) { toast.error(error.message); return; }
    toast.success("Tersimpan");
    setEditing(null);
    qc.invalidateQueries({ queryKey: ["fields"] });
  }

  async function remove(id: string) {
    if (!confirm("Hapus lapangan ini?")) return;
    const { error } = await supabase.from("fields").delete().eq("id", id);
    if (error) { toast.error(error.message); return; }
    qc.invalidateQueries({ queryKey: ["fields"] });
  }

  async function toggleActive(f: Field) {
    const { error } = await supabase.from("fields").update({ active: !f.active }).eq("id", f.id);
    if (error) { toast.error(error.message); return; }
    qc.invalidateQueries({ queryKey: ["fields"] });
  }

  return (
    <div>
      <div className="flex flex-wrap items-center justify-between gap-3 mb-4">
        <div>
          <h1 className="text-2xl font-bold">Lapangan</h1>
          <p className="text-sm text-muted-foreground">Atur harga tiket per lapangan.</p>
        </div>
        <button onClick={() => setEditing({ base_price: 25000, active: true })} className="inline-flex items-center gap-2 rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground">
          <Plus className="h-4 w-4" />Tambah lapangan
        </button>
      </div>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {q.data?.map((f) => (
          <div key={f.id} className={`card-surface p-5 ${!f.active && "opacity-60"}`}>
            <div className="flex items-start justify-between">
              <div className="inline-flex h-10 w-10 items-center justify-center rounded-lg bg-primary/10 text-primary"><MapPin className="h-5 w-5" /></div>
              <label className="inline-flex items-center gap-1 text-xs cursor-pointer">
                <input type="checkbox" checked={f.active} onChange={() => toggleActive(f)} />Aktif
              </label>
            </div>
            <h3 className="mt-3 font-bold text-lg">{f.name}</h3>
            {f.description && <p className="text-xs text-muted-foreground mt-1">{f.description}</p>}
            <p className="mt-3 text-2xl font-bold text-primary">{formatIDR(f.base_price)}</p>
            <p className="text-xs text-muted-foreground">per sesi</p>
            <div className="mt-4 flex gap-2">
              <button onClick={() => setEditing(f)} className="flex-1 inline-flex items-center justify-center gap-1 rounded-md border py-1.5 text-xs hover:bg-muted"><Pencil className="h-3 w-3" />Edit</button>
              <button onClick={() => remove(f.id)} className="inline-flex items-center justify-center rounded-md border border-destructive/30 p-1.5 text-destructive hover:bg-destructive/10"><Trash2 className="h-4 w-4" /></button>
            </div>
          </div>
        ))}
        {q.data && q.data.length === 0 && (
          <div className="card-surface p-8 col-span-full text-center text-muted-foreground">Belum ada lapangan.</div>
        )}
      </div>

      {editing && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={() => setEditing(null)}>
          <div className="card-surface p-6 w-full max-w-md" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-lg font-bold">{editing.id ? "Edit lapangan" : "Tambah lapangan"}</h2>
              <button onClick={() => setEditing(null)}><X className="h-5 w-5" /></button>
            </div>
            <div className="space-y-3">
              <div><label className="text-xs font-medium text-muted-foreground">Nama</label><input value={editing.name ?? ""} onChange={(e)=>setEditing({ ...editing, name: e.target.value })} className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm" /></div>
              <div><label className="text-xs font-medium text-muted-foreground">Harga dasar (Rp)</label><input type="number" min="0" step="500" value={editing.base_price ?? 0} onChange={(e)=>setEditing({ ...editing, base_price: Number(e.target.value) })} className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm" /></div>
              <div><label className="text-xs font-medium text-muted-foreground">Deskripsi</label><input value={editing.description ?? ""} onChange={(e)=>setEditing({ ...editing, description: e.target.value })} className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm" /></div>
              <label className="inline-flex items-center gap-2 text-sm"><input type="checkbox" checked={editing.active ?? true} onChange={(e)=>setEditing({ ...editing, active: e.target.checked })} />Aktif</label>
              <button onClick={save} className="w-full rounded-md bg-primary py-2.5 text-sm font-semibold text-primary-foreground">Simpan</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
