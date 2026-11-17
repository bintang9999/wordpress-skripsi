#!/bin/bash
set -euo pipefail

# ==============================================================================
# Portal Kampus - Deploy Script
# ==============================================================================

# Output Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Timestamp helper function
timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

# Logging helpers
log_info() {
  echo -e "${GREEN}[$(timestamp)] [INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[$(timestamp)] [WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[$(timestamp)] [ERROR]${NC} $1" >&2
}

log_step() {
  echo -e "\n${CYAN}[$(timestamp)] [STEP] ${BOLD}$1${NC}"
}

# Parse flags
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

# ------------------------------------------------------------------------------
# 0. HEADER: Print colored banner
# ------------------------------------------------------------------------------
echo -e "${CYAN}================================================================${NC}"
echo -e "${GREEN}${BOLD}                 Portal Kampus - Deploy Script                  ${NC}"
echo -e "${CYAN}================================================================${NC}"

if [[ "$DRY_RUN" == true ]]; then
  echo -e "${YELLOW}${BOLD}>>> PERINGATAN: MODE DRY-RUN AKTIF. PERINTAH SSH & RSYNC TIDAK AKAN DIEKSEKUSI <<<${NC}\n"
else
  echo ""
fi

# ------------------------------------------------------------------------------
# 1. LOAD .env.deploy
# ------------------------------------------------------------------------------
log_step "1. Memuat konfigurasi deploy (.env.deploy)..."

# Ensure we are in project root if executed from scripts directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f ".env.deploy" ]]; then
  DEPLOY_ENV_FILE=".env.deploy"
elif [[ -f "${SCRIPT_DIR}/../.env.deploy" ]]; then
  cd "${SCRIPT_DIR}/.."
  DEPLOY_ENV_FILE=".env.deploy"
else
  DEPLOY_ENV_FILE=".env.deploy"
fi

# Check if .env.deploy exists, exit with error if not
if [[ ! -f "$DEPLOY_ENV_FILE" ]]; then
  log_error "File .env.deploy tidak ditemukan di project root! Salin dari .env.deploy.example dan sesuaikan isinya."
  exit 1
fi

# Load .env.deploy
set -a
# shellcheck disable=SC1090
source "$DEPLOY_ENV_FILE"
set +a

# Fallbacks for optional settings
SSH_PORT="${SSH_PORT:-22}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-docker-compose.yml}"

# Validate required variables: SSH_USER, SSH_HOST, REMOTE_DIR
MISSING_VARS=()
[[ -z "${SSH_USER:-}" ]] && MISSING_VARS+=("SSH_USER")
[[ -z "${SSH_HOST:-}" ]] && MISSING_VARS+=("SSH_HOST")
[[ -z "${REMOTE_DIR:-}" ]] && MISSING_VARS+=("REMOTE_DIR")

if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
  log_error "Variabel wajib berikut belum didefinisikan di .env.deploy: ${MISSING_VARS[*]}"
  exit 1
fi

log_info "Konfigurasi deploy berhasil dimuat:"
log_info "  - Target Server      : ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
log_info "  - Direktori Remote   : ${REMOTE_DIR}"
log_info "  - File Docker Compose: ${DOCKER_COMPOSE_FILE}"

# ------------------------------------------------------------------------------
# 2. PRE-FLIGHT CHECKS
# ------------------------------------------------------------------------------
log_step "2. Menjalankan Pre-Flight Checks..."

# a) SSH connectivity check
log_info "a) Memeriksa konektivitas SSH ke ${SSH_HOST}..."
if [[ "$DRY_RUN" == true ]]; then
  log_info "[DRY-RUN] Melewati uji SSH. Perintah yang akan dijalankan:"
  echo "         ssh -p ${SSH_PORT} -q -o BatchMode=yes -o ConnectTimeout=5 ${SSH_USER}@${SSH_HOST} exit"
else
  if ! ssh -p "${SSH_PORT}" -q -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${SSH_HOST}" exit 2>/dev/null; then
    log_error "Gagal terhubung ke ${SSH_HOST}. Pastikan SSH aktif dan kunci SSH terdaftar."
    exit 1
  fi
  log_info "Konektivitas SSH berhasil."
fi

# b) Remote disk space check
log_info "b) Memeriksa sisa ruang disk di server remote..."
if [[ "$DRY_RUN" == true ]]; then
  log_info "[DRY-RUN] Melewati pemeriksaan disk remote. Perintah yang akan dijalankan:"
  echo "         ssh -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"df -BG / | awk 'NR==2{print \\\$4}' | tr -d G\""
else
  FREE_DISK=$(ssh -p "${SSH_PORT}" "${SSH_USER}@${SSH_HOST}" "df -BG / | awk 'NR==2{print \$4}' | tr -d G" 2>/dev/null || echo "")
  FREE_DISK=$(echo "$FREE_DISK" | tr -d '[:space:]')
  if [[ -z "$FREE_DISK" || ! "$FREE_DISK" =~ ^[0-9]+$ ]]; then
    log_error "Gagal membaca sisa ruang disk di server (output tidak valid: '$FREE_DISK')."
    exit 1
  elif (( FREE_DISK < 2 )); then
    log_error "Ruang disk tidak cukup di server: ${FREE_DISK}GB tersisa (minimum 2GB)."
    exit 1
  else
    log_info "Ruang disk mencukupi: ${FREE_DISK}GB tersisa (minimum 2GB)."
  fi
fi

# c) Remote RAM check
log_info "c) Memeriksa ketersediaan RAM di server remote..."
if [[ "$DRY_RUN" == true ]]; then
  log_info "[DRY-RUN] Melewati pemeriksaan RAM remote. Perintah yang akan dijalankan:"
  echo "         ssh -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"free -m | awk '/^Mem:/{print \\\$7}'\""
else
  FREE_RAM=$(ssh -p "${SSH_PORT}" "${SSH_USER}@${SSH_HOST}" "free -m | awk '/^Mem:/{print \$7}'" 2>/dev/null || echo "")
  FREE_RAM=$(echo "$FREE_RAM" | tr -d '[:space:]')
  if [[ -n "$FREE_RAM" && "$FREE_RAM" =~ ^[0-9]+$ ]]; then
    if (( FREE_RAM < 512 )); then
      log_warn "Peringatan: RAM tersedia ${FREE_RAM}MB (disarankan minimal 512MB)"
    else
      log_info "RAM server tersedia: ${FREE_RAM}MB (disarankan minimal 512MB terpenuhi)."
    fi
  else
    log_warn "Tidak dapat membaca informasi RAM server secara akurat (output: '$FREE_RAM')."
  fi
fi

# d) Port 8083 availability check
log_info "d) Memeriksa ketersediaan port 8083 di server remote..."
if [[ "$DRY_RUN" == true ]]; then
  log_info "[DRY-RUN] Melewati pemeriksaan port remote. Perintah yang akan dijalankan:"
  echo "         ssh -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"ss -tlnp | grep ':8083' | wc -l\""
  echo "         ssh -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"docker ps --filter 'publish=8083' --format '{{.Names}}'\""
else
  PORT_USED=$(ssh -p "${SSH_PORT}" "${SSH_USER}@${SSH_HOST}" "ss -tlnp 2>/dev/null | grep ':8083' | wc -l" 2>/dev/null || echo "0")
  PORT_USED=$(echo "$PORT_USED" | tr -d '[:space:]')
  if [[ -n "$PORT_USED" && "$PORT_USED" =~ ^[0-9]+$ ]] && (( PORT_USED > 0 )); then
    OUR_CONTAINER=$(ssh -p "${SSH_PORT}" "${SSH_USER}@${SSH_HOST}" "docker ps --filter 'publish=8083' --format '{{.Names}}' 2>/dev/null" 2>/dev/null || echo "")
    OUR_CONTAINER=$(echo "$OUR_CONTAINER" | tr -d '\r\n')
    if [[ -z "$OUR_CONTAINER" ]]; then
      log_error "Port 8083 sudah dipakai oleh proses lain! Hentikan dulu."
      exit 1
    else
      echo "Port 8083 sudah dipakai oleh container kita: $OUR_CONTAINER, melanjutkan..."
    fi
  else
    log_info "Port 8083 tersedia."
  fi
fi

# e) Local .env check
log_info "e) Memeriksa keberadaan file .env lokal..."
LOCAL_ENV_FILE=".env"
if [[ ! -f "$LOCAL_ENV_FILE" && -f "${SCRIPT_DIR}/../.env" ]]; then
  LOCAL_ENV_FILE="${SCRIPT_DIR}/../.env"
fi

if [[ ! -f "$LOCAL_ENV_FILE" ]]; then
  log_error ".env tidak ditemukan. Copy dari .env.example dan isi dulu."
  exit 1
fi
log_info "File .env lokal ditemukan."

# ------------------------------------------------------------------------------
# 3. SYNC FILES
# ------------------------------------------------------------------------------
log_step "3. Menyinkronkan file ke server..."
echo "Menyinkronkan file ke server..."

if [[ "$DRY_RUN" == true ]]; then
  log_info "[DRY-RUN] Melewati sinkronisasi file rsync. Perintah yang akan dijalankan:"
  echo "         ssh -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"mkdir -p ${REMOTE_DIR}\""
  echo "         rsync -avz -e \"ssh -p ${SSH_PORT}\" --exclude='.git' --exclude='logs/*.csv' --exclude='backup/' --exclude='.env.deploy' ./ ${SSH_USER}@${SSH_HOST}:${REMOTE_DIR}/"
else
  # Ensure remote destination directory exists
  ssh -p "${SSH_PORT}" "${SSH_USER}@${SSH_HOST}" "mkdir -p ${REMOTE_DIR}"

  rsync -avz -e "ssh -p ${SSH_PORT}" \
    --exclude='.git' \
    --exclude='logs/*.csv' \
    --exclude='backup/' \
    --exclude='.env.deploy' \
    ./ "${SSH_USER}@${SSH_HOST}:${REMOTE_DIR}/"
fi

# Copy .env separately (not in rsync exclude but mention it)
echo "Pastikan .env sudah ada di server di ${REMOTE_DIR}/.env"

# ------------------------------------------------------------------------------
# 4. REMOTE DEPLOY
# ------------------------------------------------------------------------------
log_step "4. Menjalankan Docker Compose di remote server..."

if [[ "$DRY_RUN" == true ]]; then
  log_info "[DRY-RUN] Melewati eksekusi SSH remote deploy. Perintah yang akan dijalankan di ${SSH_USER}@${SSH_HOST}:"
  cat <<EOF
    cd ${REMOTE_DIR}
    echo 'Pulling images...'
    docker compose pull
    echo 'Starting services...'
    docker compose up -d
    echo 'Status container:'
    docker compose ps
EOF
else
  ssh -p "${SSH_PORT}" "${SSH_USER}@${SSH_HOST}" "
    cd ${REMOTE_DIR}
    echo 'Pulling images...'
    docker compose pull
    echo 'Starting services...'
    docker compose up -d
    echo 'Status container:'
    docker compose ps
  "
fi

# ------------------------------------------------------------------------------
# 5. HEALTH CHECK (wait up to 60 seconds)
# ------------------------------------------------------------------------------
log_step "5. Memeriksa status kesehatan WordPress (Health Check)..."

HEALTH_URL="http://${SSH_HOST}:8083/wp-login.php"
BASE_URL="http://${SSH_HOST}:8083"

if [[ "$DRY_RUN" == true ]]; then
  log_info "[DRY-RUN] Melewati proses health check. Polling yang akan dijalankan:"
  echo "         Loop hingga 12 kali (setiap 5 detik, total 60 detik):"
  echo "         HTTP_CODE=\$(curl -s -o /dev/null -w \"%{http_code}\" ${HEALTH_URL} 2>/dev/null)"
  echo "         Jika HTTP_CODE bernilai 200 atau 302: berhasil"
else
  HEALTHY=false
  log_info "Menunggu WordPress aktif di ${HEALTH_URL} (maksimal 60 detik)..."

  for ((i=1; i<=12; i++)); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${HEALTH_URL}" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" ]]; then
      HEALTHY=true
      log_info "WordPress merespons dengan status HTTP ${HTTP_CODE} pada percobaan ke-${i}."
      break
    fi
    echo -n "."
    sleep 5
  done
  echo ""

  if [[ "$HEALTHY" == false ]]; then
    log_warn "WordPress mungkin masih starting, cek dengan: curl -I http://${SSH_HOST}:8083"
  else
    log_info "WordPress siap digunakan!"
  fi
fi

# ------------------------------------------------------------------------------
# 6. PRINT SUCCESS
# ------------------------------------------------------------------------------
log_step "6. Ringkasan Deployment"

echo -e "${GREEN}${BOLD}Deploy selesai! Akses WordPress di: http://${SSH_HOST}:8083${NC}"
echo -e "${GREEN}${BOLD}Login admin: http://${SSH_HOST}:8083/wp-admin${NC}"
