import { createFileRoute, useNavigate, redirect, Link } from "@tanstack/react-router";
import { useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "sonner";
import { Wallet } from "lucide-react";
import logoAsset from "@/assets/logo-sjr.png.asset.json";


export const Route = createFileRoute("/auth")({
  ssr: false,
  head: () => ({ meta: [{ title: "Masuk · Absensi SJR" }, { name: "description", content: "Masuk ke panel pengelola Absensi SJR." }] }),
  beforeLoad: async () => {
    const { data } = await supabase.auth.getSession();
    if (data.session) throw redirect({ to: "/scan" });
  },
  component: AuthPage,
});

function AuthPage() {
  const navigate = useNavigate();
  const [mode, setMode] = useState<"signin" | "signup">("signin");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [name, setName] = useState("");
  const [loading, setLoading] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    try {
      if (mode === "signup") {
        const { error } = await supabase.auth.signUp({
          email, password,
          options: { emailRedirectTo: window.location.origin, data: { full_name: name } },
        });
        if (error) throw error;
        toast.success("Akun dibuat. Silakan masuk.");
        setMode("signin");
      } else {
        const { error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) throw error;
        navigate({ to: "/scan" });
      }
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Gagal");
    } finally { setLoading(false); }
  }

  return (
    <div className="pitch-bg min-h-screen flex items-center justify-center px-4 py-10">
      <div className="w-full max-w-md">
        <div className="text-center mb-8">
          <img src={logoAsset.url} alt="Logo SJR Cilegon" className="mx-auto h-20 w-auto object-contain" />
          <div className="mt-4 inline-flex items-center gap-2 rounded-full bg-primary/10 text-primary px-3 py-1 text-xs font-semibold uppercase tracking-wider">⚽ Absensi SJR</div>
          <h1 className="mt-4 text-3xl font-bold">Panel Pengelola</h1>
          <p className="mt-2 text-sm text-muted-foreground">Kelola absensi & pembayaran lapangan dengan tap kartu.</p>
        </div>
        <form onSubmit={submit} className="card-surface p-6 space-y-4">
          <div className="flex rounded-lg bg-muted p-1 text-sm">
            <button type="button" onClick={() => setMode("signin")} className={`flex-1 rounded-md py-2 font-medium transition ${mode==="signin"?"bg-card shadow":"text-muted-foreground"}`}>Masuk</button>
            <button type="button" onClick={() => setMode("signup")} className={`flex-1 rounded-md py-2 font-medium transition ${mode==="signup"?"bg-card shadow":"text-muted-foreground"}`}>Daftar</button>
          </div>
          {mode === "signup" && (
            <div>
              <label className="text-sm font-medium">Nama lengkap</label>
              <input required value={name} onChange={(e)=>setName(e.target.value)} className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-ring" />
            </div>
          )}
          <div>
            <label className="text-sm font-medium">Email</label>
            <input type="email" required value={email} onChange={(e)=>setEmail(e.target.value)} className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-ring" />
          </div>
          <div>
            <label className="text-sm font-medium">Password</label>
            <input type="password" required minLength={6} value={password} onChange={(e)=>setPassword(e.target.value)} className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-ring" />
            {mode === "signin" && (
              <div className="mt-1.5 text-right">
                <Link to="/forgot-password" className="text-xs text-muted-foreground hover:text-foreground hover:underline">Lupa password?</Link>
              </div>
            )}
          </div>
          <button disabled={loading} className="w-full rounded-md bg-primary py-2.5 text-sm font-semibold text-primary-foreground hover:opacity-90 disabled:opacity-50">
            {loading ? "Memproses…" : mode === "signin" ? "Masuk" : "Buat akun"}
          </button>
          {mode === "signup" && <p className="text-xs text-muted-foreground text-center">Akun pertama otomatis menjadi admin.</p>}
        </form>
        <div className="mt-6 text-center">
          <Link to="/cek-saldo" className="inline-flex items-center gap-1.5 rounded-md border bg-card px-4 py-2 text-sm font-medium hover:bg-muted">
            <Wallet className="h-4 w-4" />Member: cek saldo & riwayat
          </Link>
        </div>
      </div>

    </div>
  );
}
