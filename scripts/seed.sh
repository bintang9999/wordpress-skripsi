#!/bin/bash
# ==============================================================================
# seed.sh - Setup Konten Portal Kampus WordPress
# Dijalankan via WP-CLI container:
#   docker compose --profile tools run --rm wpcli bash /scripts/seed.sh
#
# IDEMPOTENT: Aman dijalankan berulang kali tanpa membuat duplikat.
# ==============================================================================
set -euo pipefail

# --- Warna output ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ts() { date '+%H:%M:%S'; }
info()    { echo -e "$(ts) ${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "$(ts) ${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "$(ts) ${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "$(ts) ${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- Env defaults ---
WP_HOME="${WP_HOME:-http://192.168.0.108:8083}"
WP_SITEURL="${WP_SITEURL:-http://192.168.0.108:8083}"
WP_ADMIN_USER="${WP_ADMIN_USER:-admin}"
WP_ADMIN_PASSWORD="${WP_ADMIN_PASSWORD:-Admin@Portal2024}"
WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-admin@portal-kampus.local}"
WP_TITLE="${WP_TITLE:-Portal Kampus Demo}"
WP_LOCALE="${WP_LOCALE:-id_ID}"
POSTS="${POSTS:-500}"
PAGES="${PAGES:-20}"

WP="wp --allow-root"

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  Portal Kampus - WordPress Seed Script${NC}"
echo -e "${CYAN}  URL: ${WP_HOME}${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ==============================================================================
# LANGKAH 1: Tunggu WordPress siap
# ==============================================================================
info "Menunggu WordPress dan database siap..."
MAX_WAIT=60
COUNT=0
until $WP core is-installed 2>/dev/null; do
  COUNT=$((COUNT+1))
  if [ $COUNT -ge $MAX_WAIT ]; then
    error "Timeout: WordPress belum siap setelah ${MAX_WAIT} detik. Pastikan container berjalan."
  fi
  echo -n "."
  sleep 2
done
echo ""
success "WordPress siap!"

# ==============================================================================
# LANGKAH 2: Install WordPress (jika belum)
# ==============================================================================
if ! $WP core is-installed 2>/dev/null; then
  info "Menginstal WordPress..."
  $WP core install \
    --url="$WP_HOME" \
    --title="$WP_TITLE" \
    --admin_user="$WP_ADMIN_USER" \
    --admin_password="$WP_ADMIN_PASSWORD" \
    --admin_email="$WP_ADMIN_EMAIL" \
    --locale="$WP_LOCALE" \
    --skip-email
  success "WordPress berhasil diinstal!"
else
  success "WordPress sudah terinstal, lewati."
fi

# ==============================================================================
# LANGKAH 3: Update konfigurasi wp-config.php
# ==============================================================================
info "Mengatur konfigurasi WordPress..."
$WP config set WP_DEBUG false --raw --quiet
$WP config set DISALLOW_FILE_EDIT true --raw --quiet
$WP config set WP_CACHE true --raw --quiet
success "Konfigurasi diperbarui."

# ==============================================================================
# LANGKAH 4: Pasang bahasa Indonesia
# ==============================================================================
if [ "$WP_LOCALE" = "id_ID" ]; then
  info "Memasang bahasa Indonesia..."
  $WP language core install id_ID --activate 2>/dev/null || true
  success "Bahasa Indonesia aktif."
fi

# ==============================================================================
# LANGKAH 5: Instal & aktifkan tema Astra
# ==============================================================================
info "Memeriksa tema Astra..."
if ! $WP theme is-installed astra 2>/dev/null; then
  info "Mengunduh dan menginstal tema Astra..."
  $WP theme install astra --activate
  success "Tema Astra terpasang dan aktif."
else
  $WP theme activate astra --quiet 2>/dev/null || true
  success "Tema Astra sudah ada, diaktifkan."
fi

# ==============================================================================
# LANGKAH 6: Instal plugin
# ==============================================================================
declare -A PLUGINS=(
  ["contact-form-7"]="Contact Form 7 (formulir kontak)"
  ["wordpress-seo"]="Yoast SEO (optimasi mesin pencari)"
  ["redis-cache"]="Redis Object Cache (caching)"
  ["classic-editor"]="Classic Editor"
  ["regenerate-thumbnails"]="Regenerate Thumbnails"
)

info "Memasang plugin..."
for SLUG in "${!PLUGINS[@]}"; do
  DESC="${PLUGINS[$SLUG]}"
  if ! $WP plugin is-installed "$SLUG" 2>/dev/null; then
    info "  Menginstal: $DESC..."
    $WP plugin install "$SLUG" --activate --quiet && success "  $SLUG terpasang." || warn "  Gagal memasang $SLUG, lanjut..."
  else
    $WP plugin activate "$SLUG" --quiet 2>/dev/null || true
    success "  $SLUG sudah ada."
  fi
done

# ==============================================================================
# LANGKAH 7: Aktifkan Redis Cache (opsional, jangan gagalkan jika redis down)
# ==============================================================================
info "Mengaktifkan Redis Cache (opsional)..."
$WP redis enable 2>/dev/null && success "Redis Cache aktif." || warn "Redis tidak tersedia, dilewati."

# ==============================================================================
# LANGKAH 8: Atur permalink
# ==============================================================================
info "Mengatur struktur permalink..."
$WP rewrite structure '/%postname%/' --hard --quiet
$WP rewrite flush --hard --quiet
success "Permalink: /%postname%/"

# ==============================================================================
# LANGKAH 9: Hapus konten default
# ==============================================================================
info "Menghapus konten default WordPress..."
$WP post delete 1 --force 2>/dev/null && info "  Post 'Hello World' dihapus." || true
$WP post delete 2 --force 2>/dev/null && info "  Halaman 'Sample Page' dihapus." || true

# ==============================================================================
# LANGKAH 10: Buat halaman-halaman utama
# ==============================================================================
info "Membuat halaman-halaman Portal Kampus..."

create_page_if_missing() {
  local SLUG="$1"
  local TITLE="$2"
  local CONTENT="$3"

  EXISTING=$($WP post list --post_type=page --post_status=publish --post_name="$SLUG" --fields=ID --format=ids 2>/dev/null || echo "")
  if [ -z "$EXISTING" ]; then
    $WP post create \
      --post_type=page \
      --post_status=publish \
      --post_title="$TITLE" \
      --post_name="$SLUG" \
      --post_content="$CONTENT" \
      --porcelain --quiet
    success "  Halaman '$TITLE' dibuat."
  else
    info "  Halaman '$TITLE' sudah ada (ID: $EXISTING)."
  fi
}

create_page_if_missing "beranda" "Beranda" \
"<!-- wp:paragraph -->
<p>Selamat datang di <strong>Portal Kampus</strong> — sumber informasi resmi seputar kegiatan akademik, berita terkini, dan layanan mahasiswa. Kami berkomitmen menyediakan akses mudah terhadap informasi yang Anda butuhkan.</p>
<!-- /wp:paragraph -->
<!-- wp:paragraph -->
<p>Gunakan menu navigasi di atas untuk menjelajahi profil kampus, daftar fakultas, pengumuman terbaru, agenda kegiatan, dan informasi kontak. Bersama membangun generasi unggul dan berkarakter.</p>
<!-- /wp:paragraph -->"

create_page_if_missing "profil-kampus" "Profil Kampus" \
"<!-- wp:heading -->
<h2>Tentang Kampus Kami</h2>
<!-- /wp:heading -->
<!-- wp:paragraph -->
<p>Universitas Nusantara Maju (UNM) didirikan pada tahun 1985 dan telah berkembang menjadi salah satu institusi pendidikan tinggi terkemuka di Indonesia. Berlokasi di Kota Bandung, UNM memiliki luas kampus 45 hektare dengan fasilitas modern.</p>
<!-- /wp:paragraph -->
<!-- wp:heading {\"level\":3} -->
<h3>Visi</h3>
<!-- /wp:heading -->
<!-- wp:paragraph -->
<p>Menjadi universitas kelas dunia yang menghasilkan lulusan inovatif, berintegritas, dan berdaya saing global pada tahun 2035.</p>
<!-- /wp:paragraph -->
<!-- wp:heading {\"level\":3} -->
<h3>Misi</h3>
<!-- /wp:heading -->
<!-- wp:list -->
<ul><li>Menyelenggarakan pendidikan berkualitas tinggi berbasis riset</li><li>Mengembangkan ilmu pengetahuan dan teknologi melalui penelitian inovatif</li><li>Melaksanakan pengabdian kepada masyarakat secara berkelanjutan</li><li>Membangun kerja sama strategis dengan industri dan lembaga internasional</li></ul>
<!-- /wp:list -->"

create_page_if_missing "fakultas-program-studi" "Fakultas dan Program Studi" \
"<!-- wp:heading -->
<h2>Fakultas dan Program Studi</h2>
<!-- /wp:heading -->
<!-- wp:paragraph -->
<p>UNM memiliki 8 fakultas dengan 42 program studi yang telah terakreditasi oleh BAN-PT. Berikut adalah daftar fakultas yang tersedia:</p>
<!-- /wp:paragraph -->
<!-- wp:list -->
<ul>
<li><strong>Fakultas Teknik</strong> — Teknik Informatika, Teknik Elektro, Teknik Mesin, Teknik Sipil</li>
<li><strong>Fakultas Ekonomi dan Bisnis</strong> — Manajemen, Akuntansi, Ekonomi Pembangunan</li>
<li><strong>Fakultas Ilmu Komputer</strong> — Sistem Informasi, Ilmu Komputer, Teknologi Informasi</li>
<li><strong>Fakultas Hukum</strong> — Ilmu Hukum</li>
<li><strong>Fakultas Kedokteran</strong> — Pendidikan Dokter, Keperawatan, Farmasi</li>
<li><strong>Fakultas MIPA</strong> — Matematika, Fisika, Kimia, Biologi</li>
<li><strong>Fakultas Ilmu Sosial dan Politik</strong> — Ilmu Komunikasi, Administrasi Publik, Sosiologi</li>
<li><strong>Fakultas Keguruan dan Ilmu Pendidikan</strong> — Pendidikan Matematika, Pendidikan Bahasa Indonesia</li>
</ul>
<!-- /wp:list -->"

create_page_if_missing "berita" "Berita" \
"<!-- wp:paragraph -->
<p>Halaman ini menampilkan berita dan artikel terbaru dari lingkungan kampus. Temukan informasi seputar prestasi mahasiswa, kegiatan akademik, dan perkembangan riset terkini.</p>
<!-- /wp:paragraph -->"

create_page_if_missing "pengumuman" "Pengumuman" \
"<!-- wp:paragraph -->
<p>Halaman pengumuman resmi kampus. Pantau terus halaman ini untuk mendapatkan informasi penting mengenai jadwal ujian, pendaftaran, beasiswa, dan kebijakan akademik terbaru.</p>
<!-- /wp:paragraph -->
<!-- wp:paragraph -->
<p><strong>Pengumuman Terbaru:</strong> Pendaftaran Beasiswa Prestasi Semester Genap 2024/2025 dibuka mulai 1 Desember 2024. Mahasiswa yang memenuhi syarat IPK minimal 3.50 dapat mengajukan permohonan melalui portal akademik.</p>
<!-- /wp:paragraph -->"

create_page_if_missing "agenda" "Agenda" \
"<!-- wp:paragraph -->
<p>Jadwal kegiatan dan agenda resmi kampus. Semua civitas akademika diharapkan memperhatikan jadwal kegiatan berikut:</p>
<!-- /wp:paragraph -->
<!-- wp:list -->
<ul>
<li><strong>1-15 Desember 2024</strong> — Ujian Akhir Semester (UAS) Ganjil 2024/2025</li>
<li><strong>20 Desember 2024</strong> — Pengumuman Hasil UAS</li>
<li><strong>23-31 Desember 2024</strong> — Libur Semester</li>
<li><strong>6 Januari 2025</strong> — Awal Semester Genap 2024/2025</li>
<li><strong>15 Januari 2025</strong> — Seminar Nasional Teknologi Informasi</li>
<li><strong>1 Februari 2025</strong> — Batas Akhir Pengisian KRS Semester Genap</li>
</ul>
<!-- /wp:list -->"

create_page_if_missing "dosen" "Dosen" \
"<!-- wp:paragraph -->
<p>Universitas Nusantara Maju memiliki lebih dari 350 tenaga pengajar tetap yang terdiri dari profesor, doktor, dan master di bidangnya masing-masing. Seluruh dosen kami berkomitmen untuk memberikan pendidikan berkualitas tinggi.</p>
<!-- /wp:paragraph -->
<!-- wp:heading {\"level\":3} -->
<h3>Dosen Berprestasi</h3>
<!-- /wp:heading -->
<!-- wp:list -->
<ul>
<li><strong>Prof. Dr. Budi Santoso, M.T.</strong> — Teknik Informatika, Spesialisasi: Kecerdasan Buatan</li>
<li><strong>Dr. Sari Dewi Lestari, M.Si.</strong> — Ilmu Komputer, Spesialisasi: Keamanan Siber</li>
<li><strong>Dr. Ahmad Fauzi, M.Kom.</strong> — Sistem Informasi, Spesialisasi: Big Data Analytics</li>
<li><strong>Prof. Dr. Rahma Hidayati, M.Pd.</strong> — FKIP, Spesialisasi: Teknologi Pendidikan</li>
</ul>
<!-- /wp:list -->"

create_page_if_missing "kontak" "Kontak" \
"<!-- wp:heading -->
<h2>Hubungi Kami</h2>
<!-- /wp:heading -->
<!-- wp:paragraph -->
<p>Kami siap membantu Anda. Silakan hubungi kami melalui saluran berikut:</p>
<!-- /wp:paragraph -->
<!-- wp:list -->
<ul>
<li><strong>Alamat:</strong> Jl. Pendidikan No. 1, Bandung, Jawa Barat 40123</li>
<li><strong>Telepon:</strong> (022) 1234-5678</li>
<li><strong>Fax:</strong> (022) 1234-5679</li>
<li><strong>Email:</strong> info@portal-kampus.ac.id</li>
<li><strong>Jam Layanan:</strong> Senin–Jumat, 08.00–16.00 WIB</li>
</ul>
<!-- /wp:list -->
<!-- wp:paragraph -->
<p>Untuk pertanyaan seputar akademik, silakan kunjungi Biro Administrasi Akademik (BAA) di Gedung Rektorat lantai 2.</p>
<!-- /wp:paragraph -->"

# ==============================================================================
# LANGKAH 11: Atur halaman depan statis
# ==============================================================================
info "Mengatur halaman depan statis..."
FRONT_ID=$($WP post list --post_type=page --post_status=publish --post_name=beranda --fields=ID --format=ids 2>/dev/null | head -1)
BLOG_ID=$($WP post list --post_type=page --post_status=publish --post_name=berita --fields=ID --format=ids 2>/dev/null | head -1)

if [ -n "$FRONT_ID" ]; then
  $WP option update show_on_front page --quiet
  $WP option update page_on_front "$FRONT_ID" --quiet
  success "Halaman depan: Beranda (ID: $FRONT_ID)"
fi
if [ -n "$BLOG_ID" ]; then
  $WP option update page_for_posts "$BLOG_ID" --quiet
  success "Halaman blog: Berita (ID: $BLOG_ID)"
fi

# ==============================================================================
# LANGKAH 12: Buat menu navigasi
# ==============================================================================
info "Membuat menu navigasi..."
MENU_NAME="Menu Utama"
MENU_ID=$($WP menu list --fields=term_id,name --format=csv 2>/dev/null | grep "$MENU_NAME" | cut -d',' -f1 | head -1 || echo "")

if [ -z "$MENU_ID" ]; then
  MENU_ID=$($WP menu create "$MENU_NAME" --porcelain 2>/dev/null)
  success "Menu '$MENU_NAME' dibuat (ID: $MENU_ID)."
else
  success "Menu '$MENU_NAME' sudah ada (ID: $MENU_ID)."
fi

# Tambahkan halaman ke menu jika belum ada
MENU_SLUGS=("beranda" "profil-kampus" "fakultas-program-studi" "berita" "pengumuman" "agenda" "dosen" "kontak")
CURRENT_MENU_COUNT=$($WP menu item list "$MENU_ID" --format=count 2>/dev/null || echo "0")

if [ "$CURRENT_MENU_COUNT" -lt "${#MENU_SLUGS[@]}" ]; then
  info "Menambahkan halaman ke menu..."
  $WP menu item list "$MENU_ID" --format=ids 2>/dev/null | tr ' ' '\n' | while read -r ITEM_ID; do
    $WP menu item delete "$ITEM_ID" --quiet 2>/dev/null || true
  done
  for SLUG in "${MENU_SLUGS[@]}"; do
    PAGE_ID=$($WP post list --post_type=page --post_status=publish --post_name="$SLUG" --fields=ID --format=ids 2>/dev/null | head -1)
    if [ -n "$PAGE_ID" ]; then
      $WP menu item add-post "$MENU_ID" "$PAGE_ID" --quiet 2>/dev/null || true
    fi
  done
  success "Halaman ditambahkan ke menu."
fi

# Assign menu ke lokasi primary
$WP menu location assign "$MENU_ID" primary --quiet 2>/dev/null || warn "Lokasi menu 'primary' tidak ditemukan di tema saat ini."

# ==============================================================================
# LANGKAH 13: Generate konten dummy
# ==============================================================================
info "Memeriksa jumlah post..."
CURRENT_POSTS=$($WP post list --post_type=post --post_status=publish --format=count 2>/dev/null || echo "0")
info "Post saat ini: $CURRENT_POSTS / target: $POSTS"

if [ "$CURRENT_POSTS" -lt "$POSTS" ]; then
  REMAINING=$((POSTS - CURRENT_POSTS))
  info "Menggenerate $REMAINING post dummy (ini bisa memakan waktu beberapa menit)..."
  $WP post generate \
    --count="$REMAINING" \
    --post_type=post \
    --post_status=publish \
    --post_title="Berita Kampus"
  success "$REMAINING post berhasil digenerate."
else
  success "Post sudah mencukupi ($CURRENT_POSTS post)."
fi

# ==============================================================================
# LANGKAH 14: Atur opsi situs
# ==============================================================================
info "Mengatur opsi situs..."
$WP option update blogdescription "Portal Informasi Kampus" --quiet
$WP option update timezone_string "Asia/Jakarta" --quiet
$WP option update date_format "d F Y" --quiet
$WP option update time_format "H:i" --quiet
$WP option update start_of_week 1 --quiet
$WP option update posts_per_page 10 --quiet
success "Opsi situs diperbarui."

# ==============================================================================
# RINGKASAN AKHIR
# ==============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  SEEDING SELESAI!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  URL Situs  : ${WP_HOME}"
echo -e "  Admin      : ${WP_HOME}/wp-admin"
echo -e "  Username   : ${WP_ADMIN_USER}"
echo -e "  Tema       : Astra"
echo -e "  Post       : $($WP post list --post_type=post --post_status=publish --format=count 2>/dev/null)"
echo -e "  Halaman    : $($WP post list --post_type=page --post_status=publish --format=count 2>/dev/null)"
echo -e "${GREEN}============================================================${NC}"
echo ""

