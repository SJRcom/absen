import { createFileRoute, Outlet, Link, useNavigate, redirect, useRouterState } from "@tanstack/react-router";
import { supabase } from "@/integrations/supabase/client";
import { useQueryClient, useQuery } from "@tanstack/react-query";
import { ScanLine, Users, MapPin, Receipt, Wallet, LogOut, CalendarDays, ShoppingBag, ShieldCheck, Clock, Nfc } from "lucide-react";
import logoAsset from "@/assets/logo-sjr.png.asset.json";

export const Route = createFileRoute("/_authenticated")({
  ssr: false,
  beforeLoad: async () => {
    const { data, error } = await supabase.auth.getUser();
    if (error || !data.user) throw redirect({ to: "/auth" });
    return { user: data.user };
  },
  component: Shell,
});

const NAV = [
  { to: "/scan", label: "Scan", icon: ScanLine },
  { to: "/nfc-scan", label: "NFC Absen", icon: Nfc },
  { to: "/events", label: "Event", icon: CalendarDays },
  { to: "/products", label: "Produk", icon: ShoppingBag },
  { to: "/topup", label: "Top Up", icon: Wallet },
  { to: "/participants", label: "Peserta", icon: Users },
  { to: "/fields", label: "Lapangan", icon: MapPin },
  { to: "/transactions", label: "Riwayat", icon: Receipt },
] as const;

const SUPER_NAV = { to: "/users", label: "Pengguna", icon: ShieldCheck } as const;


function Shell() {
  const navigate = useNavigate();
  const qc = useQueryClient();
  const pathname = useRouterState({ select: (s) => s.location.pathname });

  const accessQ = useQuery({
    queryKey: ["my-access"],
    queryFn: async () => {
      const { data, error } = await supabase.rpc("my_access");
      if (error) throw error;
      return data as { staff: boolean; super_admin: boolean };
    },
  });
  const isStaff = accessQ.data?.staff === true;
  const isSuper = accessQ.data?.super_admin === true;
  const nav = isSuper ? [...NAV, SUPER_NAV] : [...NAV];


  async function signOut() {
    await qc.cancelQueries();
    qc.clear();
    await supabase.auth.signOut();
    navigate({ to: "/auth", replace: true });
  }

  return (
    <div className="min-h-screen pitch-bg pb-24 md:pb-0">
      <header className="sticky top-0 z-30 border-b bg-background/80 backdrop-blur">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-4 py-3">
          <Link to={isStaff ? "/scan" : "/cek-saldo"} className="flex items-center gap-2 font-bold">
            <img src={logoAsset.url} alt="Logo SJR Cilegon" className="h-8 w-auto object-contain" />
            <span className="font-display text-lg">Absensi SJR</span>
          </Link>
          {isStaff && (
            <nav className="hidden md:flex items-center gap-1">
              {nav.map((n) => {
                const active = pathname.startsWith(n.to);
                return (
                  <Link key={n.to} to={n.to} className={`inline-flex items-center gap-2 rounded-md px-3 py-2 text-sm font-medium transition ${active ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:bg-muted hover:text-foreground"}`}>
                    <n.icon className="h-4 w-4" />{n.label}
                  </Link>
                );
              })}
            </nav>
          )}
          <button onClick={signOut} className="inline-flex items-center gap-1.5 rounded-md border px-3 py-1.5 text-sm hover:bg-muted">
            <LogOut className="h-4 w-4" /><span className="hidden sm:inline">Keluar</span>
          </button>
        </div>
      </header>
      <main className="mx-auto max-w-6xl px-4 py-6">
        {accessQ.isLoading ? (
          <p className="text-sm text-muted-foreground">Memuat…</p>
        ) : isStaff ? (
          <Outlet />
        ) : (
          <div className="card-surface mx-auto max-w-md p-8 text-center">
            <Clock className="mx-auto h-8 w-8 text-muted-foreground" />
            <h1 className="mt-3 text-lg font-bold">Akun Anda belum menjadi pengurus</h1>
            <p className="mt-2 text-sm text-muted-foreground">
              Akun baru berstatus member dan belum dapat menginput data. Hubungi super admin untuk diangkat menjadi pengurus.
            </p>
            <Link to="/cek-saldo" className="mt-5 inline-flex items-center gap-2 rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground">
              <Wallet className="h-4 w-4" />Cek saldo member
            </Link>
          </div>
        )}
      </main>
      {/* Bottom nav mobile */}
      {isStaff && (
        <nav className="md:hidden fixed bottom-0 inset-x-0 z-30 border-t bg-background">
          <div className={`grid ${isSuper ? "grid-cols-9" : "grid-cols-8"}`}>
            {nav.map((n) => {
              const active = pathname.startsWith(n.to);
              return (
                <Link key={n.to} to={n.to} className={`flex flex-col items-center gap-1 py-2 text-[11px] font-medium ${active ? "text-primary" : "text-muted-foreground"}`}>
                  <n.icon className="h-5 w-5" />{n.label}
                </Link>
              );
            })}
          </div>
        </nav>
      )}
    </div>

  );
}
