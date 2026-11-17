#!/bin/bash
set -euo pipefail

# ==========================================
# Portal Kampus - WordPress Backup Script
# ==========================================

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 1. SETUP: Directories & Timestamp
BACKUP_DIR="./backup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${BACKUP_DIR}/${TIMESTAMP}"
BACKUP_COMPLETED=false

# Load .env if exists
if [ -f ".env" ]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
elif [ -f "$(dirname "$0")/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$(dirname "$0")/.env"
    set +a
elif [ -f "$(dirname "$0")/../.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$(dirname "$0")/../.env"
    set +a
fi

# Fallback values for environment variables to ensure compatibility with set -u
MYSQL_DATABASE="${MYSQL_DATABASE:-wordpress}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
if [ -z "${MYSQL_ROOT_PASSWORD}" ] && [ -f "secrets/db_root_password.txt" ]; then
    MYSQL_ROOT_PASSWORD="$(cat secrets/db_root_password.txt | tr -d '\r\n')"
fi

# Error handler: removes incomplete backup directory on failure
cleanup_on_failure() {
    local exit_code=$?
    if [ "${BACKUP_COMPLETED}" = false ] && [ -n "${BACKUP_PATH:-}" ] && [ -d "${BACKUP_PATH}" ]; then
        echo -e "\n${RED}[ERROR] Backup gagal dengan status kode ${exit_code}!${NC}" >&2
        echo -e "${YELLOW}[CLEANUP] Menghapus direktori backup parsial/tidak lengkap: ${BACKUP_PATH}${NC}" >&2
        rm -rf "${BACKUP_PATH}"
        echo -e "${RED}[ERROR] Pembersihan selesai. Direktori ${BACKUP_PATH} telah dihapus.${NC}" >&2
    fi
}
trap cleanup_on_failure EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Function to list existing backups
list_backups() {
    echo -e "${BOLD}${CYAN}==========================================${NC}"
    echo -e "${BOLD}${CYAN}      Portal Kampus - Backup List         ${NC}"
    echo -e "${BOLD}${CYAN}==========================================${NC}"

    if [ ! -d "${BACKUP_DIR}" ]; then
        echo -e "${YELLOW}Direktori backup '${BACKUP_DIR}' tidak ditemukan.${NC}"
        return 0
    fi

    local backup_dirs
    backup_dirs=$(ls -dt "${BACKUP_DIR}"/*/ 2>/dev/null || true)

    if [ -z "${backup_dirs}" ]; then
        echo -e "${YELLOW}Tidak ada backup yang ditemukan di '${BACKUP_DIR}'.${NC}"
        return 0
    fi

    echo -e "${BOLD}Daftar backup yang tersedia di ${BACKUP_DIR}:${NC}\n"
    local count=0
    for dir in ${backup_dirs}; do
        local b_name
        b_name=$(basename "${dir}")
        [[ "${b_name}" =~ ^\. ]] && continue

        count=$((count + 1))
        local total_sz
        total_sz=$(du -sh "${dir}" 2>/dev/null | awk '{print $1}')
        echo -e "  ${BOLD}${CYAN}[${count}] ${b_name}${NC} (Total: ${total_sz})"

        # Status file database
        if [ -f "${dir}/database.sql.gz" ]; then
            local db_sz
            db_sz=$(du -sh "${dir}/database.sql.gz" | awk '{print $1}')
            echo -e "      - Database : database.sql.gz (${db_sz})"
        elif [ -f "${dir}/database.sql" ]; then
            local db_sz
            db_sz=$(du -sh "${dir}/database.sql" | awk '{print $1}')
            echo -e "      - Database : database.sql (${db_sz})"
        else
            echo -e "      - Database : ${RED}Tidak ditemukan${NC}"
        fi

        # Status file wp-content
        if [ -d "${dir}/wp-content" ]; then
            local wp_sz
            wp_sz=$(du -sh "${dir}/wp-content" | awk '{print $1}')
            echo -e "      - Files    : wp-content/ (${wp_sz})"
        elif [ -f "${dir}/wp-content.tar.gz" ]; then
            local wp_sz
            wp_sz=$(du -sh "${dir}/wp-content.tar.gz" | awk '{print $1}')
            echo -e "      - Files    : wp-content.tar.gz (${wp_sz})"
        else
            echo -e "      - Files    : ${RED}Tidak ditemukan${NC}"
        fi
        echo ""
    done

    echo -e "${BOLD}Total backup tersimpan:${NC} ${count}"
    echo -e "${BOLD}${CYAN}==========================================${NC}"
}

# Function to show restore instructions
show_restore() {
    local target_ts="$1"
    local target_path="${BACKUP_DIR}/${target_ts}"

    echo -e "${BOLD}${CYAN}================================================================${NC}"
    echo -e "${BOLD}${CYAN}      Portal Kampus - Restore Instructions (${target_ts})       ${NC}"
    echo -e "${BOLD}${CYAN}================================================================${NC}"
    echo -e "${YELLOW}[CATATAN] Perintah di bawah ini TIDAK dijalankan secara otomatis.${NC}"
    echo -e "${YELLOW}Silakan salin dan jalankan instruksi berikut secara manual:${NC}\n"

    if [ -d "${target_path}" ]; then
        echo -e "${GREEN}[OK] Direktori backup terverifikasi ada: ${target_path}${NC}\n"
    else
        echo -e "${YELLOW}[PERINGATAN] Direktori '${target_path}' saat ini belum ada.${NC}"
        echo -e "${YELLOW}Pastikan TIMESTAMP sesuai dengan yang tercantum pada '$0 --list'.${NC}\n"
    fi

    echo -e "${BOLD}1. Restore Database:${NC}"
    echo -e "   gunzip -c ${target_path}/database.sql.gz | \\"
    echo -e "     docker compose exec -T wordpress_db mysql -u root -p\"\${MYSQL_ROOT_PASSWORD}\" \"\${MYSQL_DATABASE:-wordpress}\""
    echo ""
    echo -e "${BOLD}2. Restore Berkas wp-content (pilih salah satu sesuai format backup):${NC}"
    echo -e "   # Jika backup berupa folder direktori:"
    echo -e "   docker compose cp ${target_path}/wp-content/. wordpress:/var/www/html/wp-content/"
    echo ""
    echo -e "   # ATAU jika backup berupa arsip tar.gz:"
    echo -e "   docker run --rm -v portal-kampus_wp_data:/data -v \$(pwd)/${target_path#./}:/backup alpine \\"
    echo -e "     tar xzf /backup/wp-content.tar.gz -C /data"
    echo ""
    echo -e "${BOLD}3. Perbaiki Kepemilikan & Hak Akses Berkas:${NC}"
    echo -e "   docker compose exec -T wordpress chown -R www-data:www-data /var/www/html/wp-content"
    echo ""
    echo -e "${BOLD}4. Restart Service WordPress:${NC}"
    echo -e "   docker compose restart wordpress"
    echo ""
    echo -e "${BOLD}5. Verifikasi Kontainer:${NC}"
    echo -e "   docker compose ps"
    echo -e "${BOLD}${CYAN}================================================================${NC}"
}

# Parse Command-Line Flags
if [ $# -gt 0 ]; then
    case "$1" in
        --list|-l)
            list_backups
            exit 0
            ;;
        --restore|-r)
            if [ -z "${2:-}" ]; then
                echo -e "${RED}[ERROR] Flag --restore membutuhkan argumen TIMESTAMP!${NC}" >&2
                echo -e "Penggunaan: $0 --restore <TIMESTAMP>" >&2
                echo -e "Contoh:     $0 --restore 20261118_061525" >&2
                exit 1
            fi
            show_restore "$2"
            exit 0
            ;;
        --restore=*)
            target_ts="${1#*=}"
            if [ -z "${target_ts}" ]; then
                echo -e "${RED}[ERROR] Flag --restore membutuhkan argumen TIMESTAMP!${NC}" >&2
                echo -e "Penggunaan: $0 --restore=<TIMESTAMP>" >&2
                exit 1
            fi
            show_restore "${target_ts}"
            exit 0
            ;;
        --help|-h)
            echo -e "${BOLD}Penggunaan:${NC} $0 [OPSI]"
            echo ""
            echo -e "${BOLD}Opsi:${NC}"
            echo "  (tanpa argumen)           Jalankan proses backup penuh (database + wp-content)"
            echo "  --list, -l                Tampilkan daftar seluruh backup yang ada"
            echo "  --restore, -r <TIMESTAMP> Tampilkan petunjuk perintah restore untuk TIMESTAMP"
            echo "  --help, -h                Tampilkan pesan bantuan ini"
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR] Parameter tidak dikenal: $1${NC}" >&2
            echo -e "Jalankan '$0 --help' untuk melihat daftar opsi yang tersedia." >&2
            exit 1
            ;;
    esac
fi

# 0. HEADER: Print "Portal Kampus - Backup Script"
echo -e "${BOLD}${CYAN}==========================================${NC}"
echo -e "${BOLD}${CYAN}      Portal Kampus - Backup Script       ${NC}"
echo -e "${BOLD}${CYAN}==========================================${NC}"

# 1. SETUP: Create backup directory
echo -e "${BLUE}==> Menyiapkan direktori backup: ${BACKUP_PATH}${NC}"
mkdir -p "${BACKUP_PATH}"
echo -e "${GREEN}[OK] Direktori backup siap.${NC}"

# 2. DATABASE BACKUP
echo -e "${BLUE}==> Membackup database...${NC}"
docker compose exec -T wordpress_db mysqldump \
    -u root -p"${MYSQL_ROOT_PASSWORD}" \
    --single-transaction --quick --lock-tables=false \
    "${MYSQL_DATABASE}" > "${BACKUP_PATH}/database.sql"

gzip "${BACKUP_PATH}/database.sql"
DB_SIZE=$(du -sh "${BACKUP_PATH}/database.sql.gz" | awk '{print $1}')
echo -e "${GREEN}[OK] Database berhasil dicompress: database.sql.gz (${DB_SIZE})${NC}"

# 3. WP-CONTENT BACKUP (files from volume)
echo -e "${BLUE}==> Membackup wp-content...${NC}"
if docker compose cp wordpress:/var/www/html/wp-content "${BACKUP_PATH}/wp-content" 2>/dev/null; then
    WP_SIZE=$(du -sh "${BACKUP_PATH}/wp-content" | awk '{print $1}')
    echo -e "${GREEN}[OK] Berkas wp-content berhasil disalin (${WP_SIZE})${NC}"
else
    echo -e "${YELLOW}[WARN] 'docker compose cp' gagal. Menggunakan fallback via container Alpine...${NC}"
    docker run --rm \
        -v portal-kampus_wp_data:/data \
        -v "$(pwd)/backup/${TIMESTAMP}:/backup" \
        alpine \
        tar czf /backup/wp-content.tar.gz -C /data wp-content
    WP_SIZE=$(du -sh "${BACKUP_PATH}/wp-content.tar.gz" | awk '{print $1}')
    echo -e "${GREEN}[OK] Berkas wp-content berhasil diarsip (${WP_SIZE})${NC}"
fi

# 4. CLEANUP OLD BACKUPS (keep last 7)
echo -e "${BLUE}==> Membersihkan backup lama (menyimpan 7 backup terakhir)...${NC}"
DELETED_COUNT=0
OLD_BACKUPS=$(ls -t "${BACKUP_DIR}" 2>/dev/null | grep -v '^\.' | tail -n +8 || true)

if [ -n "${OLD_BACKUPS}" ]; then
    DELETED_COUNT=$(echo "${OLD_BACKUPS}" | wc -l | tr -d ' ')
    echo "${OLD_BACKUPS}" | xargs -I{} rm -rf "${BACKUP_DIR}/{}"
fi
echo -e "${GREEN}[OK] Jumlah backup lama yang dihapus: ${DELETED_COUNT}${NC}"

# 5. SUMMARY
TOTAL_SIZE=$(du -sh "${BACKUP_PATH}" | awk '{print $1}')
BACKUP_COMPLETED=true

echo -e "\n${BOLD}${CYAN}==========================================${NC}"
echo -e "${BOLD}${GREEN}        RINGKASAN BACKUP (SELESAI)        ${NC}"
echo -e "${BOLD}${CYAN}==========================================${NC}"
echo -e "  ${BOLD}Lokasi Backup :${NC} ${BACKUP_PATH}"
echo -e "  ${BOLD}Total Ukuran  :${NC} ${TOTAL_SIZE}"
echo -e "  ${BOLD}Timestamp     :${NC} ${TIMESTAMP}"
echo -e "${BOLD}${CYAN}==========================================${NC}"
