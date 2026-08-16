import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { formatIDR } from "@/lib/format";
import { toast } from "sonner";
import { Plus, Pencil, Trash2, X, Users, Shield, UserPlus, CalendarDays } from "lucide-react";

export const Route = createFileRoute("/_authenticated/events")({
  head: () => ({
    meta: [
      { title: "Event · Absensi SJR" },
      { name: "description", content: "Kelola event pertandingan, tarif per posisi, dan daftar peserta." },
    ],
  }),
  component: Page,
});

type EventRow = {
  id: string;
  name: string;
  field_id: string;
  event_date: string;
  gk_price: number;
  player_price: number;
  reserve_price: number;
  gk_slots: number;
  player_slots: number;
  reserve_slots: number;
  status: "open" | "closed";
  note: string | null;
};

type Position = "gk" | "player" | "reserve";

type EventParticipant = {
  id: string;
  event_id: string;
  participant_id: string;
  position: Position;
  participants: { id: string; name: string; card_uid: string; balance: number } | null;
};

const POS_LABEL: Record<Position, string> = { gk: "Goal Keeper", player: "Pemain", reserve: "Cadangan" };

function Page() {
  const qc = useQueryClient();
  const [editing, setEditing] = useState<Partial<EventRow> | null>(null);
  const [managing, setManaging] = useState<EventRow | null>(null);

  const fieldsQ = useQuery({
    queryKey: ["fields"],
    queryFn: async () => {
      const { data, error } = await supabase.from("fields").select("id,name,base_price").order("name");
      if (error) throw error;
      return data;
    },
  });

  const eventsQ = useQuery({
    queryKey: ["events"],
    queryFn: async () => {
      const { data, error } = await supabase.from("events").select("*").order("event_date", { ascending: false });
      if (error) throw error;
      return data as EventRow[];
    },
  });

  const fieldById = (id: string) => fieldsQ.data?.find((f) => f.id === id);

  async function save() {
    if (!editing) return;
    const name = editing.name?.trim();
    if (!name || !editing.field_id) { toast.error("Nama & lapangan wajib"); return; }
    const payload = {
      name,
      field_id: editing.field_id,
      event_date: editing.event_date ?? new Date().toISOString(),
      gk_price: Number(editing.gk_price) || 0,
      player_price: Number(editing.player_price) || 0,
      reserve_price: Number(editing.reserve_price) || 0,
      gk_slots: Number(editing.gk_slots) || 1,
      player_slots: Number(editing.player_slots) || 10,
      reserve_slots: Number(editing.reserve_slots) || 0,
      status: (editing.status ?? "open") as "open" | "closed",
      note: editing.note ?? null,
    };
    const { error } = editing.id
      ? await supabase.from("events").update(payload).eq("id", editing.id)
      : await supabase.from("events").insert(payload);
    if (error) { toast.error(error.message); return; }
    toast.success("Tersimpan");
    setEditing(null);
    qc.invalidateQueries({ queryKey: ["events"] });
  }

  async function remove(id: string) {
    if (!confirm("Hapus event ini? Semua daftar peserta di event ini akan ikut terhapus.")) return;
    const { error } = await supabase.from("events").delete().eq("id", id);
    if (error) { toast.error(error.message); return; }
    qc.invalidateQueries({ queryKey: ["events"] });
  }

  async function toggleStatus(ev: EventRow) {
    const { error } = await supabase.from("events").update({ status: ev.status === "open" ? "closed" : "open" }).eq("id", ev.id);
    if (error) { toast.error(error.message); return; }
    qc.invalidateQueries({ queryKey: ["events"] });
  }

  return (
    <div>
      <div className="flex flex-wrap items-center justify-between gap-3 mb-4">
        <div>
          <h1 className="text-2xl font-bold">Event Pertandingan</h1>
          <p className="text-sm text-muted-foreground">Buat event, atur tarif per posisi, dan daftarkan peserta.</p>
        </div>
        <button
          onClick={() =>
            setEditing({
              gk_price: 20000, player_price: 30000, reserve_price: 15000,
              gk_slots: 2, player_slots: 10, reserve_slots: 3,
              status: "open",
              event_date: new Date().toISOString().slice(0, 16),
            })
          }
          className="inline-flex items-center gap-2 rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground"
        >
          <Plus className="h-4 w-4" />Tambah event
        </button>
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        {eventsQ.data?.map((ev) => {
          const field = fieldById(ev.field_id);
          return (
            <div key={ev.id} className="card-surface p-5">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <div className="flex items-center gap-2">
                    <h3 className="font-bold text-lg">{ev.name}</h3>
                    <span className={`text-xs rounded px-2 py-0.5 ${ev.status === "open" ? "bg-success/15 text-success" : "bg-muted text-muted-foreground"}`}>
                      {ev.status === "open" ? "Buka" : "Tutup"}
                    </span>
                  </div>
                  <p className="mt-1 text-xs text-muted-foreground flex items-center gap-1">
                    <CalendarDays className="h-3 w-3" />
                    {new Date(ev.event_date).toLocaleString("id-ID", { dateStyle: "medium", timeStyle: "short" })}
                    {field && <> · {field.name}</>}
                  </p>
                </div>
                <div className="flex gap-1">
                  <button onClick={() => setEditing(ev)} className="rounded-md p-1.5 hover:bg-muted"><Pencil className="h-4 w-4" /></button>
                  <button onClick={() => remove(ev.id)} className="rounded-md p-1.5 hover:bg-destructive/10 text-destructive"><Trash2 className="h-4 w-4" /></button>
                </div>
              </div>

              <div className="mt-4 grid grid-cols-3 gap-2 text-center text-xs">
                <PriceCell label="GK" price={ev.gk_price} slots={ev.gk_slots} accent="warning" />
                <PriceCell label="Pemain" price={ev.player_price} slots={ev.player_slots} accent="primary" />
                <PriceCell label="Cadangan" price={ev.reserve_price} slots={ev.reserve_slots} accent="muted" />
              </div>

              {ev.note && <p className="mt-3 text-xs text-muted-foreground">{ev.note}</p>}

              <div className="mt-4 flex gap-2">
                <button onClick={() => setManaging(ev)} className="flex-1 inline-flex items-center justify-center gap-1.5 rounded-md bg-secondary py-2 text-sm font-medium hover:bg-muted">
                  <Users className="h-4 w-4" />Kelola peserta
                </button>
                <button onClick={() => toggleStatus(ev)} className="rounded-md border px-3 py-2 text-xs hover:bg-muted">
                  {ev.status === "open" ? "Tutup" : "Buka"}
                </button>
              </div>
            </div>
          );
        })}
        {eventsQ.data && eventsQ.data.length === 0 && (
          <div className="card-surface p-8 col-span-full text-center text-muted-foreground">Belum ada event.</div>
        )}
      </div>

      {editing && (
        <EditModal editing={editing} setEditing={setEditing} save={save} fields={fieldsQ.data ?? []} />
      )}
      {managing && (
        <ManageModal event={managing} close={() => setManaging(null)} />
      )}
    </div>
  );
}

function PriceCell({ label, price, slots, accent }: { label: string; price: number; slots: number; accent: "warning" | "primary" | "muted" }) {
  const color = accent === "warning" ? "text-warning" : accent === "primary" ? "text-primary" : "text-foreground";
  return (
    <div className="rounded-md border p-2">
      <p className="text-[10px] uppercase tracking-wider text-muted-foreground">{label}</p>
      <p className={`font-bold ${color}`}>{formatIDR(price)}</p>
      <p className="text-[10px] text-muted-foreground">{slots} slot</p>
    </div>
  );
}

function EditModal({
  editing, setEditing, save, fields,
}: {
  editing: Partial<EventRow>;
  setEditing: (v: Partial<EventRow> | null) => void;
  save: () => void;
  fields: { id: string; name: string; base_price: number }[];
}) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={() => setEditing(null)}>
      <div className="card-surface p-6 w-full max-w-lg max-h-[90vh] overflow-y-auto" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-lg font-bold">{editing.id ? "Edit event" : "Tambah event"}</h2>
          <button onClick={() => setEditing(null)}><X className="h-5 w-5" /></button>
        </div>
        <div className="space-y-3">
          <L label="Nama event">
            <input value={editing.name ?? ""} onChange={(e) => setEditing({ ...editing, name: e.target.value })} placeholder="mis. Latihan Rutin Jumat" className="w-full rounded-md border bg-background px-3 py-2 text-sm" />
          </L>
          <div className="grid grid-cols-2 gap-3">
            <L label="Lapangan">
              <select value={editing.field_id ?? ""} onChange={(e) => setEditing({ ...editing, field_id: e.target.value })} className="w-full rounded-md border bg-background px-3 py-2 text-sm">
                <option value="">Pilih…</option>
                {fields.map((f) => <option key={f.id} value={f.id}>{f.name}</option>)}
              </select>
            </L>
            <L label="Tanggal & jam">
              <input
                type="datetime-local"
                value={editing.event_date ? editing.event_date.slice(0, 16) : ""}
                onChange={(e) => setEditing({ ...editing, event_date: new Date(e.target.value).toISOString() })}
                className="w-full rounded-md border bg-background px-3 py-2 text-sm"
              />
            </L>
          </div>

          <div className="rounded-md border p-3">
            <p className="text-xs font-semibold mb-2">Tarif per posisi (Rp)</p>
            <div className="grid grid-cols-3 gap-2">
              <L label="GK">
                <input type="number" min="0" step="500" value={editing.gk_price ?? 0} onChange={(e) => setEditing({ ...editing, gk_price: Number(e.target.value) })} className="w-full rounded-md border bg-background px-2 py-1.5 text-sm" />
              </L>
              <L label="Pemain">
                <input type="number" min="0" step="500" value={editing.player_price ?? 0} onChange={(e) => setEditing({ ...editing, player_price: Number(e.target.value) })} className="w-full rounded-md border bg-background px-2 py-1.5 text-sm" />
              </L>
              <L label="Cadangan">
                <input type="number" min="0" step="500" value={editing.reserve_price ?? 0} onChange={(e) => setEditing({ ...editing, reserve_price: Number(e.target.value) })} className="w-full rounded-md border bg-background px-2 py-1.5 text-sm" />
              </L>
            </div>
          </div>

          <div className="rounded-md border p-3">
            <p className="text-xs font-semibold mb-2">Kuota slot</p>
            <div className="grid grid-cols-3 gap-2">
              <L label="GK">
                <input type="number" min="0" value={editing.gk_slots ?? 1} onChange={(e) => setEditing({ ...editing, gk_slots: Number(e.target.value) })} className="w-full rounded-md border bg-background px-2 py-1.5 text-sm" />
              </L>
              <L label="Pemain">
                <input type="number" min="0" value={editing.player_slots ?? 10} onChange={(e) => setEditing({ ...editing, player_slots: Number(e.target.value) })} className="w-full rounded-md border bg-background px-2 py-1.5 text-sm" />
              </L>
              <L label="Cadangan">
                <input type="number" min="0" value={editing.reserve_slots ?? 3} onChange={(e) => setEditing({ ...editing, reserve_slots: Number(e.target.value) })} className="w-full rounded-md border bg-background px-2 py-1.5 text-sm" />
              </L>
            </div>
          </div>

          <L label="Catatan (opsional)">
            <input value={editing.note ?? ""} onChange={(e) => setEditing({ ...editing, note: e.target.value })} className="w-full rounded-md border bg-background px-3 py-2 text-sm" />
          </L>
          <label className="inline-flex items-center gap-2 text-sm">
            <input type="checkbox" checked={(editing.status ?? "open") === "open"} onChange={(e) => setEditing({ ...editing, status: e.target.checked ? "open" : "closed" })} />
            Event terbuka (bisa scan)
          </label>
          <button onClick={save} className="w-full rounded-md bg-primary py-2.5 text-sm font-semibold text-primary-foreground">Simpan</button>
        </div>
      </div>
    </div>
  );
}

function ManageModal({ event, close }: { event: EventRow; close: () => void }) {
  const qc = useQueryClient();
  const [selectedId, setSelectedId] = useState("");
  const [position, setPosition] = useState<Position>("player");
  const [search, setSearch] = useState("");

  const partsQ = useQuery({
    queryKey: ["participants"],
    queryFn: async () => {
      const { data, error } = await supabase.from("participants").select("id,name,card_uid,balance").order("name");
      if (error) throw error;
      return data;
    },
  });

  const rosterQ = useQuery({
    queryKey: ["event_participants", event.id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from("event_participants")
        .select("id,event_id,participant_id,position,participants(id,name,card_uid,balance)")
        .eq("event_id", event.id);
      if (error) throw error;
      return data as unknown as EventParticipant[];
    },
  });

  const roster = rosterQ.data ?? [];
  const grouped: Record<Position, EventParticipant[]> = {
    gk: roster.filter((r) => r.position === "gk"),
    player: roster.filter((r) => r.position === "player"),
    reserve: roster.filter((r) => r.position === "reserve"),
  };
  const cap: Record<Position, number> = { gk: event.gk_slots, player: event.player_slots, reserve: event.reserve_slots };

  const takenIds = new Set(roster.map((r) => r.participant_id));
  const available = partsQ.data?.filter((p) => !takenIds.has(p.id) && (p.name.toLowerCase().includes(search.toLowerCase()) || p.card_uid.includes(search.toUpperCase()))) ?? [];

  async function add() {
    if (!selectedId) return;
    const { error } = await supabase.from("event_participants").insert({ event_id: event.id, participant_id: selectedId, position });
    if (error) { toast.error(error.message); return; }
    toast.success("Ditambahkan");
    setSelectedId("");
    setSearch("");
    qc.invalidateQueries({ queryKey: ["event_participants", event.id] });
  }

  async function changePosition(row: EventParticipant, newPos: Position) {
    const { error } = await supabase.from("event_participants").update({ position: newPos }).eq("id", row.id);
    if (error) { toast.error(error.message); return; }
    qc.invalidateQueries({ queryKey: ["event_participants", event.id] });
  }

  async function removeRow(id: string) {
    const { error } = await supabase.from("event_participants").delete().eq("id", id);
    if (error) { toast.error(error.message); return; }
    qc.invalidateQueries({ queryKey: ["event_participants", event.id] });
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4" onClick={close}>
      <div className="card-surface p-6 w-full max-w-3xl max-h-[90vh] overflow-y-auto" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-4">
          <div>
            <h2 className="text-lg font-bold">Kelola peserta · {event.name}</h2>
            <p className="text-xs text-muted-foreground">{new Date(event.event_date).toLocaleString("id-ID", { dateStyle: "medium", timeStyle: "short" })}</p>
          </div>
          <button onClick={close}><X className="h-5 w-5" /></button>
        </div>

        <div className="rounded-md border p-3 mb-4">
          <p className="text-sm font-semibold mb-2 flex items-center gap-1"><UserPlus className="h-4 w-4" />Tambah peserta ke event</p>
          <div className="flex flex-col gap-2 sm:flex-row">
            <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Cari nama / UID…" className="flex-1 rounded-md border bg-background px-3 py-2 text-sm" />
            <select value={selectedId} onChange={(e) => setSelectedId(e.target.value)} className="rounded-md border bg-background px-3 py-2 text-sm sm:w-56">
              <option value="">Pilih peserta…</option>
              {available.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
            <select value={position} onChange={(e) => setPosition(e.target.value as Position)} className="rounded-md border bg-background px-3 py-2 text-sm">
              <option value="gk">Goal Keeper ({grouped.gk.length}/{cap.gk})</option>
              <option value="player">Pemain ({grouped.player.length}/{cap.player})</option>
              <option value="reserve">Cadangan ({grouped.reserve.length}/{cap.reserve})</option>
            </select>
            <button onClick={add} disabled={!selectedId} className="rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground disabled:opacity-50">Tambah</button>
          </div>
        </div>

        <div className="grid gap-4 md:grid-cols-3">
          {(["gk", "player", "reserve"] as Position[]).map((pos) => (
            <div key={pos} className="rounded-md border">
              <div className="flex items-center justify-between px-3 py-2 border-b bg-muted/50">
                <p className="text-sm font-semibold flex items-center gap-1">
                  {pos === "gk" && <Shield className="h-4 w-4 text-warning" />}
                  {POS_LABEL[pos]}
                </p>
                <span className="text-xs text-muted-foreground">{grouped[pos].length}/{cap[pos]}</span>
              </div>
              <ul className="divide-y">
                {grouped[pos].map((r) => (
                  <li key={r.id} className="flex items-center justify-between px-3 py-2 text-sm">
                    <div className="min-w-0">
                      <p className="truncate font-medium">{r.participants?.name}</p>
                      <p className="truncate text-xs text-muted-foreground font-mono">{r.participants?.card_uid}</p>
                    </div>
                    <div className="flex items-center gap-1">
                      <select
                        value={r.position}
                        onChange={(e) => changePosition(r, e.target.value as Position)}
                        className="rounded border bg-background px-1 py-0.5 text-xs"
                      >
                        <option value="gk">GK</option>
                        <option value="player">P</option>
                        <option value="reserve">C</option>
                      </select>
                      <button onClick={() => removeRow(r.id)} className="text-destructive hover:bg-destructive/10 rounded p-1"><Trash2 className="h-3.5 w-3.5" /></button>
                    </div>
                  </li>
                ))}
                {grouped[pos].length === 0 && <li className="px-3 py-4 text-xs text-center text-muted-foreground">Kosong</li>}
              </ul>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function L({ label, children }: { label: string; children: React.ReactNode }) {
  return <div><label className="text-xs font-medium text-muted-foreground">{label}</label><div className="mt-1">{children}</div></div>;
}
