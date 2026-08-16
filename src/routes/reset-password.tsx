import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "sonner";
import { ArrowLeft, CheckCircle2, KeyRound, ShieldAlert } from "lucide-react";
import logoAsset from "@/assets/logo-sjr.png.asset.json";

export const Route = createFileRoute("/reset-password")({
  ssr: false,
  head: () => ({
    meta: [
      { title: "Atur Ulang Password · Absensi SJR" },
      { name: "description", content: "Buat password baru untuk akun pengelola Absensi SJR." },
    ],
  }),
  component: ResetPasswordPage,
});

function ResetPasswordPage() {
  const navigate = useNavigate();
  const [checking, setChecking] = useState(true);
  const [ready, setReady] = useState(false);
  const [invalid, setInvalid] = useState(false);
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [loading, setLoading] = useState(false);
  const [done, setDone] = useState(false);

  useEffect(() => {
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;

    const { data: authSub } = supabase.auth.onAuthStateChange((event) => {
      if (cancelled) return;
      if (event === "PASSWORD_RECOVERY") {
        if (timer) clearTimeout(timer);
        setReady(true);
        setChecking(false);
      }
    });

    (async () => {
      // supabase-js processes the recovery token (type=recovery) in the URL
      // hash during client init and stores a session. If it's already gone
      // from the URL, the session check below still catches it.
      const hashParams = new URLSearchParams(window.location.hash.slice(1));
      const hasRecovery = hashParams.get("type") === "recovery";

      const { data } = await supabase.auth.getSession();
      if (cancelled) return;

      if (hasRecovery || data.session) {
        if (timer) clearTimeout(timer);
        setReady(true);
        setChecking(false);
        return;
      }

      // Give the async recovery processing a moment before declaring the link invalid.
      timer = setTimeout(() => {
        if (cancelled) return;
        setChecking(false);
        setInvalid(true);
      }, 3000);
    })();

    return () => {
      cancelled = true;
      authSub.subscription.unsubscribe();
      if (timer) clearTimeout(timer);
    };
  }, []);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (password.length < 6) {
      toast.error("Password minimal 6 karakter");
      return;
    }
    if (password !== confirm) {
      toast.error("Konfirmasi password tidak cocok");
      return;
    }
    setLoading(true);
    try {
      const { error } = await supabase.auth.updateUser({ password });
      if (error) throw error;
      // Sign out so the user logs back in with the new password.
      await supabase.auth.signOut().catch(() => {});
      setDone(true);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Gagal mengatur ulang password");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="pitch-bg min-h-screen flex items-center justify-center px-4 py-10">
      <div className="w-full max-w-md">
        <div className="text-center mb-8">
          <img src={logoAsset.url} alt="Logo SJR Cilegon" className="mx-auto h-20 w-auto object-contain" />
          <div className="mt-4 inline-flex items-center gap-2 rounded-full bg-primary/10 text-primary px-3 py-1 text-xs font-semibold uppercase tracking-wider">⚽ Absensi SJR</div>
          <h1 className="mt-4 text-3xl font-bold">Atur Ulang Password</h1>
        </div>

        {done ? (
          <div className="card-surface p-6 text-center space-y-4">
            <CheckCircle2 className="mx-auto h-10 w-10 text-success" />
            <p className="text-sm">Password berhasil diubah. Silakan masuk dengan password baru Anda.</p>
            <button
              onClick={() => navigate({ to: "/auth" })}
              className="w-full rounded-md bg-primary py-2.5 text-sm font-semibold text-primary-foreground hover:opacity-90"
            >
              Masuk sekarang
            </button>
          </div>
        ) : invalid ? (
          <div className="card-surface p-6 text-center space-y-4">
            <ShieldAlert className="mx-auto h-10 w-10 text-destructive" />
            <p className="text-sm">
              Link reset tidak valid atau sudah kedaluwarsa. Silakan minta link baru.
            </p>
            <Link to="/forgot-password" className="inline-flex items-center gap-1.5 rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground">
              <KeyRound className="h-4 w-4" />Minta link baru
            </Link>
            <div className="text-center">
              <Link to="/auth" className="inline-flex items-center gap-1.5 text-xs text-muted-foreground hover:text-foreground">
                <ArrowLeft className="h-3.5 w-3.5" />Kembali ke halaman masuk
              </Link>
            </div>
          </div>
        ) : (
          <form onSubmit={submit} className="card-surface p-6 space-y-4">
            {checking && <p className="text-center text-sm text-muted-foreground">Memeriksa link…</p>}
            {ready && (
              <>
                <div>
                  <label className="text-sm font-medium">Password baru</label>
                  <input
                    type="password"
                    required
                    minLength={6}
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    placeholder="Minimal 6 karakter"
                    className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-ring"
                  />
                </div>
                <div>
                  <label className="text-sm font-medium">Konfirmasi password</label>
                  <input
                    type="password"
                    required
                    minLength={6}
                    value={confirm}
                    onChange={(e) => setConfirm(e.target.value)}
                    placeholder="Ulangi password baru"
                    className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-ring"
                  />
                </div>
                <button disabled={loading} className="w-full rounded-md bg-primary py-2.5 text-sm font-semibold text-primary-foreground hover:opacity-90 disabled:opacity-50">
                  {loading ? "Menyimpan…" : "Simpan password baru"}
                </button>
              </>
            )}
          </form>
        )}
      </div>
    </div>
  );
}
