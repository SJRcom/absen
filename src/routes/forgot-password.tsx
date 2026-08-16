import { createFileRoute, Link } from "@tanstack/react-router";
import { useState } from "react";
import { supabase } from "@/integrations/supabase/client";
import { toast } from "sonner";
import { ArrowLeft, KeyRound, MailCheck } from "lucide-react";
import logoAsset from "@/assets/logo-sjr.png.asset.json";

export const Route = createFileRoute("/forgot-password")({
  ssr: false,
  head: () => ({
    meta: [
      { title: "Lupa Password · Absensi SJR" },
      { name: "description", content: "Atur ulang password akun pengelola Absensi SJR." },
    ],
  }),
  component: ForgotPasswordPage,
});

function ForgotPasswordPage() {
  const [email, setEmail] = useState("");
  const [loading, setLoading] = useState(false);
  const [sent, setSent] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    try {
      const { error } = await supabase.auth.resetPasswordForEmail(email, {
        redirectTo: `${window.location.origin}/reset-password`,
      });
      if (error) throw error;
      setSent(true);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Gagal mengirim email reset");
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
          <h1 className="mt-4 text-3xl font-bold">Lupa Password</h1>
          <p className="mt-2 text-sm text-muted-foreground">Masukkan email akun Anda, kami kirimkan link untuk membuat password baru.</p>
        </div>

        {sent ? (
          <div className="card-surface p-6 text-center space-y-4">
            <MailCheck className="mx-auto h-10 w-10 text-success" />
            <p className="text-sm">
              Jika email <span className="font-semibold">{email}</span> terdaftar, link reset password sudah dikirim. Periksa kotak masuk (dan folder spam) Anda.
            </p>
            <Link to="/auth" className="inline-flex items-center gap-1.5 rounded-md border px-4 py-2 text-sm font-medium hover:bg-muted">
              <ArrowLeft className="h-4 w-4" />Kembali ke halaman masuk
            </Link>
          </div>
        ) : (
          <form onSubmit={submit} className="card-surface p-6 space-y-4">
            <div>
              <label className="text-sm font-medium">Email</label>
              <input
                type="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="nama@email.com"
                className="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-ring"
              />
            </div>
            <button disabled={loading} className="w-full rounded-md bg-primary py-2.5 text-sm font-semibold text-primary-foreground hover:opacity-90 disabled:opacity-50">
              {loading ? "Mengirim…" : "Kirim link reset"}
            </button>
            <div className="text-center">
              <Link to="/auth" className="inline-flex items-center gap-1.5 text-xs text-muted-foreground hover:text-foreground">
                <ArrowLeft className="h-3.5 w-3.5" />Kembali ke halaman masuk
              </Link>
            </div>
          </form>
        )}

        <div className="mt-6 text-center">
          <Link to="/cek-saldo" className="inline-flex items-center gap-1.5 text-xs text-muted-foreground hover:text-foreground">
            <KeyRound className="h-3.5 w-3.5" />Cek saldo member tanpa login
          </Link>
        </div>
      </div>
    </div>
  );
}
