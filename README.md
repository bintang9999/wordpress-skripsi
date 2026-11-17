# Portal Kampus — WordPress Docker Compose Stack

> **Keperluan:** Bahan uji skripsi  
> *"Analisis Performa dan Stabilitas Xiaomi Redmi Note 4 Berbasis postmarketOS sebagai Low-Power Docker Host"*

---

## Arsitektur Stack

```
[Browser / k6 Load Tester]
         |
         ▼
 Host Port 8083 (exposed)
         |
         ▼
 ┌─────────────────────┐
 │   wordpress         │  wordpress:6.7-php8.3-apache
 │   mem: 768m         │  PHP memory_limit=256M
 │   cpus: 2.0         │  OPcache aktif
 └────────┬────────────┘
          │  portal_net (bridge)
     ┌────┴────────────────────────┐
     │                             │
     ▼                             ▼
 ┌────────────────┐    ┌─────────────────────┐
 │  wordpress_db  │    │       redis          │
 │  mariadb:11.4  │    │  redis:7-alpine      │
 │  mem: 384m     │    │  mem: 128m           │
 │  cpus: 1.0     │    │  cpus: 0.5           │
 │  (port TIDAK   │    │  (profile: redis)    │
 │  di-expose)    │    └─────────────────────┘
 └────────────────┘
 
 [profile: tools]
 ┌─────────────────────┐
 │       wpcli         │  wordpress:cli-php8.3
 │  (hanya saat seed)  │
 └─────────────────────┘
```

---

## Prasyarat

| Komponen | Versi Minimum |
|---|---|
| Docker Engine | 20.x (server: 29.5.2 ✓) |
| Docker Compose | v2.x (server: v5.1.4 ✓) |
| SSH key | Terdaftar di server |
| rsync | Di mesin lokal (untuk deploy) |
| curl | Di mesin lokal (untuk health check) |

---

## Struktur Folder

```
portal-kampus/
├── docker-compose.yml          # Orkestrasi utama
├── .env.example                # Template variabel lingkungan
├── .env.deploy.example         # Template konfigurasi deploy
├── .gitignore                  # Abaikan .env, logs, backup
├── Makefile                    # Perintah make yang nyaman
│
├── config/
│   ├── mysql/
│   │   └── my.cnf              # Tuning MariaDB untuk RAM kecil
│   ├── php/
│   │   └── uploads.ini         # Tuning PHP + OPcache
│   └── nginx/
│       └── portal-kampus.conf  # Snippet nginx reverse proxy (opsional)
│
├── scripts/
│   ├── seed.sh                 # Setup konten Portal Kampus (idempotent)
│   ├── deploy.sh               # Deploy ke server via rsync + SSH
│   ├── backup.sh               # Backup database + wp-content
│   ├── monitor.sh              # Koleksi metrik untuk skripsi (CSV)
│   └── loadtest.sh             # Uji beban bertahap (k6/wrk)
│
├── logs/                       # Output monitor.sh & loadtest.sh
│   └── .gitkeep
│
└── backup/                     # Output backup.sh
    └── .gitkeep
```

---

## Langkah Deploy Pertama Kali

> Jalankan perintah ini **secara berurutan** dari terminal VS Code di folder `portal-kampus/`.

### Langkah 1 — Siapkan File Konfigurasi

```powershell
# 1a. Buat file .env dari template
Copy-Item .env.example .env

# 1b. Edit .env — WAJIB ganti password!
#     Minimal ubah: MYSQL_ROOT_PASSWORD, MYSQL_PASSWORD, WP_ADMIN_PASSWORD
notepad .env

# 1c. Buat file .env.deploy
Copy-Item .env.deploy.example .env.deploy
notepad .env.deploy
# Pastikan SSH_USER sesuai username di server (contoh: bintang)
```

### Langkah 2 — Pastikan Koneksi SSH

```powershell
# Uji koneksi ke server (harus masuk tanpa password)
ssh bintang@192.168.0.108 "echo OK"

# Jika belum, copy SSH key:
ssh-copy-id bintang@192.168.0.108
```

### Langkah 3 — Buat Direktori di Server

```powershell
ssh bintang@192.168.0.108 "mkdir -p ~/portal-kampus"
```

### Langkah 4 — Jalankan Deploy

```powershell
# Dry-run dulu (tidak ada yang diubah, hanya preview)
bash scripts/deploy.sh --dry-run

# Deploy sesungguhnya
bash scripts/deploy.sh
```

> Pada Windows, gunakan Git Bash atau WSL untuk menjalankan script bash.

### Langkah 5 — Verifikasi Container Berjalan

```bash
# Di server:
ssh bintang@192.168.0.108 "cd ~/portal-kampus && docker compose ps"

# Dari lokal:
curl -I http://192.168.0.108:8083
# Expected: HTTP/1.1 302 Found (redirect ke setup WordPress)
```

### Langkah 6 — Seed Konten Portal Kampus

```bash
# Di server:
ssh bintang@192.168.0.108 "cd ~/portal-kampus && docker compose --profile tools run --rm wpcli bash /scripts/seed.sh"

# ATAU dari lokal via Makefile (jika make tersedia):
make seed
```

> Script seed memakan waktu 5–15 menit tergantung jumlah POSTS (default 500).

---

## Verifikasi Setelah Deploy

```bash
# 1. Cek semua container berjalan
docker compose ps
# Expected: wordpress, wordpress_db semua status "Up (healthy)"

# 2. Cek port 8083 bisa diakses
curl -I http://192.168.0.108:8083
# Expected: HTTP/1.1 200 OK atau 302 (redirect setup)

# 3. Cek log WordPress (tidak ada error fatal)
docker compose logs wordpress --tail=50

# 4. Cek log database
docker compose logs wordpress_db --tail=20

# 5. Setelah seed selesai, buka browser:
# http://192.168.0.108:8083        → Frontend Portal Kampus
# http://192.168.0.108:8083/wp-admin → Login admin
```

---

## Perintah Harian (via Makefile)

```bash
make up           # Jalankan stack
make up-redis     # Jalankan stack + Redis
make down         # Hentikan (data AMAN)
make status       # Cek status container
make logs         # Lihat semua log
make logs-wp      # Lihat log WordPress saja

make seed         # Jalankan seed konten (idempotent)
make backup       # Backup database + wp-content
make deploy       # Deploy ulang ke server

make monitor INTERVAL=10 DURATION=3600   # Monitor 1 jam
make loadtest                            # Uji beban
```

---

## Koleksi Data untuk Skripsi

### Monitor Metrik Sistem

```bash
# Di server, monitor selama 1 jam (3600 detik), interval 10 detik:
bash scripts/monitor.sh 10 3600

# Hasil tersimpan di: logs/metrics_YYYYMMDD_HHMMSS.csv
# Kolom: timestamp, load_avg, memory, cpu_temp, cpu_freq, docker_stats per container
```

### Uji Beban (Load Testing)

```bash
# Pastikan k6 atau wrk sudah terinstal di mesin penguji
# Install k6: https://k6.io/docs/get-started/installation/
# Install wrk: apt install wrk

bash scripts/loadtest.sh http://192.168.0.108:8083

# Hasil tersimpan di: logs/loadtest_YYYYMMDD_HHMMSS/
# - stage1_10vus.json  (10 pengguna)
# - stage2_50vus.json  (50 pengguna)
# - stage3_100vus.json (100 pengguna)
# - stage4_200vus.json (200 pengguna)
# - summary.txt        (ringkasan)
```

---

## Reverse Proxy via Nginx (Opsional)

Jika ingin WordPress diakses via domain/nama host melalui Nginx yang sudah berjalan:

```bash
# 1. Copy konfigurasi (di server):
sudo cp ~/portal-kampus/config/nginx/portal-kampus.conf /etc/nginx/conf.d/

# 2. Validasi konfigurasi Nginx:
sudo nginx -t

# 3. Reload Nginx (TANPA restart, agar container lain tidak terganggu):
sudo nginx -s reload
```

> **Catatan:** Konfigurasi ini hanya MENAMBAH server block baru di port 8084,  
> TIDAK mengubah konfigurasi Nginx yang sudah ada.

---

## Rollback

Jika terjadi masalah setelah deploy:

```bash
# Opsi 1: Restart container WordPress saja (tercepat)
docker compose restart wordpress

# Opsi 2: Hentikan stack (data database AMAN di volume)
docker compose down

# Opsi 3: Restore dari backup
# Lihat backup yang tersedia:
bash scripts/backup.sh --list

# Restore database (manual):
gunzip -c backup/TIMESTAMP/database.sql.gz | \
  docker compose exec -T wordpress_db mysql -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"

# Restart setelah restore:
docker compose up -d
```

---

## Resource Allocation

| Service | RAM Limit | CPU Limit | Keterangan |
|---|---|---|---|
| wordpress | 768 MB | 2.0 core | PHP + Apache |
| wordpress_db | 384 MB | 1.0 core | MariaDB |
| redis | 128 MB | 0.5 core | (profile: redis) |
| **Total** | **~1.28 GB** | **3.5 core** | Dari budget 1.5 GB |

> Sisa ~220 MB sebagai buffer untuk overhead Docker dan OS.

---

## Keamanan

- ✅ Semua password di `.env` (tidak di-commit ke Git)
- ✅ Port database (3306) tidak terbuka ke host
- ✅ `DISALLOW_FILE_EDIT = true` (tidak bisa edit tema/plugin via dashboard)
- ✅ `WP_DEBUG = false` di production
- ✅ Direktori upload diblokir dari eksekusi PHP (via Nginx)

---

## Lisensi

Proyek ini dibuat untuk keperluan akademis (skripsi). Bebas digunakan dan dimodifikasi.

