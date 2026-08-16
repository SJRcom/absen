# Deployment Frontend — absen.sjr-komunitas.com

Panduan memindahkan frontend Absensi SJR dari Lovable ke hosting sendiri di
**https://absen.sjr-komunitas.com/**. Backend (database, auth, fungsi pemotongan
saldo) tetap berjalan di Supabase — hanya tampilan (frontend) yang pindah.

---

## 1. Prasyarat

- Node.js 20+ (atau Bun, karena repo ini memakai `bun.lock`).
- Isi file `.env` di root proyek dengan kredensial Supabase:

  ```env
  VITE_SUPABASE_URL=https://<proyek>.supabase.co
  VITE_SUPABASE_PUBLISHABLE_KEY=<anon/publishable key>
  ```

  Kedua nilai ini **aman dibundel ke frontend** (publishable key memang publik
  by design). Keamanan sebenarnya (RLS, fungsi database, bcrypt PIN) tetap
  dijaga di Supabase, jadi tidak ada rahasia yang perlu dijaga di server web.

## 2. Build

```sh
npm install    # atau: bun install
npm run build  # atau: bun run build
```

Hasil build ada di folder `.output/`. Target deployment ditentukan lewat preset
nitro (lihat `vite.config.ts`):

| Preset            | Untuk                                        | Cara pakai                          |
| ----------------- | -------------------------------------------- | ----------------------------------- |
| `cloudflare-module` | Cloudflare Workers (default, tanpa perlu konfigurasi) | `npm run build` |
| `node-server`     | VPS / server sendiri (Node + nginx)          | `NITRO_PRESET=node-server npm run build` |

> ⚠️ **Export statis (`NITRO_PRESET=static`) TIDAK didukung** oleh stack TanStack Start ini
> (gagal saat prerender). Jika hosting Anda tidak bisa menjalankan Node (mis. shared
> hosting cPanel), pakai **Cloudflare Workers** (Opsi B) — tidak butuh server Node.

---

## 3. Opsi A — VPS / server sendiri (Node + nginx) ⭐ disarankan

Paling fleksibel dan paling mudah di-debug.

```sh
NITRO_PRESET=node-server npm run build
```

Jalankan server di VPS (port 3000):

```sh
node .output/server/index.mjs
```

Uji dulu: `curl http://127.0.0.1:3000/cek-saldo`.

### systemd (agar jalan terus)

`/etc/systemd/system/absensjr.service`:

```ini
[Unit]
Description=Absensi SJR frontend
After=network.target

[Service]
WorkingDirectory=/opt/absensjr
ExecStart=/usr/bin/node /opt/absensjr/.output/server/index.mjs
Restart=always
Environment=PORT=3000

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now absensjr
```

### nginx (reverse proxy + HTTPS)

`/etc/nginx/sites-available/absensjr`:

```nginx
server {
    listen 80;
    server_name absen.sjr-komunitas.com;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

```sh
sudo ln -s /etc/nginx/sites-available/absensjr /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
# HTTPS:
sudo certbot --nginx -d absen.sjr-komunitas.com
```

---

## 4. Opsi B — Cloudflare Workers (tanpa konfigurasi tambahan)

Build default (`npm run build`) sudah menargetkan Cloudflare. Deploy hasil build
ke akun Cloudflare Anda (proyek Workers) lalu pasang custom domain
`absen.sjr-komunitas.com`. Setel env saat build: `VITE_SUPABASE_URL` dan
`VITE_SUPABASE_PUBLISHABLE_KEY`.

---

## 5. Hosting yang tidak bisa menjalankan Node (shared hosting / cPanel)

Export statis tidak didukung stack ini, sehingga shared hosting biasa (hanya
PHP/statis) **bukan** pilihan yang cocok. Gunakan salah satu dari:

- **Cloudflare Workers** (Opsi B) — gratis, otomatis HTTPS, cukup arahkan DNS
  `absen.sjr-komunitas.com` ke Cloudflare.
- **VPS murah** (Opsi A) — bisa dari Rp 50–100 ribu/bulan, jalankan Node + nginx.

---

## 6. Deploy otomatis via GitHub Actions

Workflow `.github/workflows/deploy.yml` sudah disiapkan: **setiap push ke
`main` otomatis build lalu deploy** ke target yang dipilih.

### Setup sekali saja di GitHub (repo `SJRcom/absen`)

**Settings → Secrets and variables → Actions → New repository variable:**

| Nama | Nilai |
| ---- | ----- |
| `DEPLOY_TARGET` | kosongkan / isi `cloudflare` → Cloudflare; isi `vps` → VPS |

**New repository secret:**

| Secret | Untuk | Dari mana |
| ------ | ----- | --------- |
| `VITE_SUPABASE_URL` | semua target | Supabase → Settings → API |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | semua target | Supabase → Settings → API |
| `CLOUDFLARE_API_TOKEN` | Cloudflare | Cloudflare dashboard → My Profile → API Tokens (izin `Workers Scripts: Edit`) |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare | Cloudflare dashboard (pojok kanan bawah, halaman overview) |
| `VPS_HOST` | VPS | IP/domain VPS (mis. `203.0.113.10`) |
| `VPS_USER` | VPS | user SSH (mis. `deploy`) |
| `VPS_PORT` | VPS | port SSH, default `22` (boleh dikosongkan) |
| `VPS_PATH` | VPS | folder deploy di VPS, mis. `/opt/absensjr` (isi build masuk ke `$VPS_PATH/.output`) |
| `VPS_SSH_KEY` | VPS | **private key** SSH (isi dengan seluruh isi file `id_ed25519`) |

### Catatan per target

- **Cloudflare**: setelah deploy pertama, pasang custom domain di dashboard
  **Workers & Pages → nama worker (mis. `sjrcom-absen`, lihat log deploy) →
  Settings → Domains & Routes** → Add custom domain →
  `absen.sjr-komunitas.com` (DNS harus dikelola/menunjuk ke Cloudflare).
  SSL otomatis.
- **VPS**: pastikan di VPS sudah ada user deploy dengan **passwordless sudo**
  untuk `systemctl restart absensjr`, folder `VPS_PATH` sudah ada & writable
  oleh user tersebut, dan service `absensjr` sudah dibuat (lihat Opsi A).
  Contoh persiapan:

  ```sh
  sudo mkdir -p /opt/absensjr
  sudo chown -R $USER /opt/absensjr   # user deploy jadi pemilik folder
  ```

---

## 7. Konfigurasi Supabase Auth (wajib!)

Agar link reset password & konfirmasi email mengarah ke domain baru:

1. Buka **Supabase Dashboard → Authentication → URL Configuration**.
2. **Site URL**: `https://absen.sjr-komunitas.com`
3. **Redirect URLs** — tambahkan:
   - `https://absen.sjr-komunitas.com/**`
   - `https://absen.sjr-komunitas.com/reset-password` (untuk link lupa password)
   - Biarkan URL preview Lovable (`https://absensjr.lovable.app/**`) jika masih dipakai untuk pengembangan.

Tanpa ini, email "reset password" akan gagal saat link diklik.

---

## 8. DNS

Arahkan `absen.sjr-komunitas.com` ke hosting Anda:

- **VPS**: record `A` → IP server (mis. `123.123.123.123`).
- **Cloudflare**: biarkan Cloudflare mengelola DNS, proyek Workers di-custom-domain-kan.
- **Shared hosting**: atur dari panel DNS / cPanel sesuai petunjuk penyedia.

Setelah DNS aktif, pastikan HTTPS tersedia (SSL), karena NFC di `/cek-saldo`
membutuhkan koneksi HTTPS (`getUserMedia`/`NDEFReader` tidak berjalan di HTTP).

---

## 9. Cek akhir

- [ ] `https://absen.sjr-komunitas.com/` → otomatis ke Cek Saldo.
- [ ] `/auth` → masuk/datar pengelola.
- [ ] `/forgot-password` → email reset terkirim, link mengarah ke `/reset-password`.
- [ ] `/reset-password` dengan link dari email → password bisa diganti.
- [ ] Cek saldo via nomor member & NFC berfungsi.
