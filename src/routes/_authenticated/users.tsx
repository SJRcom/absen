import { createFileRoute } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "sonner";
import { ShieldCheck, UserCog, Users2 } from "lucide-react";
import { formatDateTime } from "@/lib/format";

export const Route = createFileRoute("/_authenticated/users")({
  head: () => ({
    meta: [
      { title: "Manajemen Pengguna · Absensi SJR" },
      { name: "description", content: "Kelola akun pengurus dan member aplikasi Absensi SJR. Khusus super admin." },
    ],
  }),
  component: Page,
});

type Row = {
  user_id: string;
  full_name: string | null;
  email: string | null;
  roles: string[] | null;
  created_at: string;
};

function Page() {
  const qc = useQueryClient();

  const accessQ = useQuery({
    queryKey: ["my-access"],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("my_access");
      if (error) throw error;
      return data as { staff: boolean; super_admin: boolean };
    },
  });

  const q = useQuery({
    queryKey: ["app-users"],
    enabled: accessQ.data?.super_admin === true,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("list_app_users");
      if (error) throw error;
      return (data ?? []) as Row[];
    },
  });

  async function toggleStaff(row: Row, makeStaff: boolean) {
    const { data, error } = await supabase.rpc("set_user_staff", { _user_id: row.user_id, _make_staff: makeStaff });
    if (error) { toast.error(error.message); return; }
    const r = data as { ok: boolean; error?: string };
    if (!r.ok) { toast.error(r.error ?? "Gagal"); return; }
    toast.success(makeStaff ? "Dijadikan pengurus" : "Peran pengurus dicabut");
    qc.invalidateQueries({ queryKey: ["app-users"] });
  }

  if (accessQ.isLoading) return <p className="text-sm text-muted-foreground">Memuat…</p>;

  if (!accessQ.data?.super_admin) {
    return (
      <div className="card-surface p-8 text-center">
        <ShieldCheck className="mx-auto h-8 w-8 text-muted-foreground" />
        <h1 className="mt-3 text-lg font-bold">Khusus Super Admin</h1>
        <p className="mt-1 text-sm text-muted-foreground">Halaman manajemen pengguna hanya dapat diakses oleh super admin.</p>
      </div>
    );
  }

  return (
    <div>
      <div className="mb-4">
        <h1 className="text-2xl font-bold">Manajemen Pengguna</h1>
        <p className="text-sm text-muted-foreground">
          Pendaftar baru berstatus <b>member</b> dan belum bisa menginput data. Angkat menjadi <b>pengurus</b> agar bisa mengelola absensi, produk, dan saldo.
        </p>
      </div>

      <div className="card-surface overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="bg-muted/50 text-left">
              <tr>
                <th className="px-4 py-3 font-semibold">Nama</th>
                <th className="px-4 py-3 font-semibold">Email</th>
                <th className="px-4 py-3 font-semibold">Peran</th>
                <th className="px-4 py-3 font-semibold">Terdaftar</th>
                <th className="px-4 py-3"></th>
              </tr>
            </thead>
            <tbody>
              {q.data?.map((u) => {
                const roles = u.roles ?? [];
                const isSuper = roles.includes("super_admin");
                const isStaff = isSuper || roles.includes("admin");
                return (
                  <tr key={u.user_id} className="border-t hover:bg-muted/30">
                    <td className="px-4 py-3 font-medium">{u.full_name ?? "—"}</td>
                    <td className="px-4 py-3 text-xs">{u.email ?? "—"}</td>
                    <td className="px-4 py-3">
                      <span className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[11px] font-semibold ${isSuper ? "bg-primary/10 text-primary" : isStaff ? "bg-success/10 text-success" : "bg-muted text-muted-foreground"}`}>
                        {isSuper ? <ShieldCheck className="h-3 w-3" /> : isStaff ? <UserCog className="h-3 w-3" /> : <Users2 className="h-3 w-3" />}
                        {isSuper ? "Super Admin" : isStaff ? "Pengurus" : "Member"}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-xs text-muted-foreground">{formatDateTime(u.created_at)}</td>
                    <td className="px-4 py-3 text-right whitespace-nowrap">
                      {isSuper ? (
                        <span className="text-xs text-muted-foreground">Tidak dapat diubah</span>
                      ) : (
                        <button
                          onClick={() => toggleStaff(u, !isStaff)}
                          className={`rounded-md px-3 py-1.5 text-xs font-semibold ${isStaff ? "border hover:bg-muted" : "bg-primary text-primary-foreground"}`}
                        >
                          {isStaff ? "Cabut pengurus" : "Jadikan pengurus"}
                        </button>
                      )}
                    </td>
                  </tr>
                );
              })}
              {q.data?.length === 0 && <tr><td colSpan={5} className="px-4 py-8 text-center text-muted-foreground">Belum ada pengguna.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
