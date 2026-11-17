#!/bin/bash
# ==============================================================================
# loadtest.sh - Uji Beban WordPress Portal Kampus
# Mendukung k6 (prioritas) atau wrk (fallback)
#
# USAGE: bash scripts/loadtest.sh [TARGET_URL] [TOOL]
# Contoh: bash scripts/loadtest.sh http://192.168.0.108:8083
#         bash scripts/loadtest.sh http://192.168.0.108:8083 wrk
# ==============================================================================
set -euo pipefail

TARGET_URL="${1:-http://192.168.0.108:8083}"
PREFERRED_TOOL="${2:-auto}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ts() { date '+%H:%M:%S'; }
info()    { echo -e "$(ts) ${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "$(ts) ${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "$(ts) ${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "$(ts) ${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- Parse flags ---
STAGE_FILTER=""
for ARG in "$@"; do
  case "$ARG" in
    --stages=*) STAGE_FILTER="${ARG#--stages=}" ;;
  esac
done

# --- Setup output ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="logs/loadtest_${TIMESTAMP}"
mkdir -p "$OUT_DIR"

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  Portal Kampus - Load Test${NC}"
echo -e "${CYAN}  Target : ${TARGET_URL}${NC}"
echo -e "${CYAN}  Output : ${OUT_DIR}${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ==============================================================================
# DETEKSI TOOL
# ==============================================================================
TOOL=""
if [ "$PREFERRED_TOOL" = "auto" ] || [ "$PREFERRED_TOOL" = "k6" ]; then
  if command -v k6 &>/dev/null; then
    TOOL="k6"
    info "Menggunakan k6 $(k6 version | head -1)"
  fi
fi

if [ -z "$TOOL" ] && { [ "$PREFERRED_TOOL" = "auto" ] || [ "$PREFERRED_TOOL" = "wrk" ]; }; then
  if command -v wrk &>/dev/null; then
    TOOL="wrk"
    info "Menggunakan wrk"
  fi
fi

if [ -z "$TOOL" ]; then
  error "Tidak ada tool uji beban yang ditemukan. Install k6 atau wrk terlebih dahulu.
  k6 : https://k6.io/docs/get-started/installation/
  wrk: sudo apt install wrk  (Debian/Ubuntu)"
fi

# ==============================================================================
# CEK TARGET DAPAT DIAKSES
# ==============================================================================
info "Memeriksa koneksi ke ${TARGET_URL}..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "$TARGET_URL" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "000" ]; then
  error "Tidak dapat terhubung ke ${TARGET_URL}. Pastikan WordPress berjalan."
fi
success "Target dapat diakses (HTTP $HTTP_CODE)."

# ==============================================================================
# DEFINISI STAGE UJI BEBAN
# ==============================================================================
declare -A STAGES
STAGES[1]="10"
STAGES[2]="50"
STAGES[3]="100"
STAGES[4]="200"
STAGE_DURATION=60   # detik per stage
WAIT_BETWEEN=30     # detik antar stage

should_run_stage() {
  local S="$1"
  if [ -z "$STAGE_FILTER" ]; then return 0; fi
  echo "$STAGE_FILTER" | tr ',' '\n' | grep -q "^${S}$"
}

# ==============================================================================
# K6 SCRIPT
# ==============================================================================
K6_SCRIPT="/tmp/k6_portal_kampus.js"
if [ "$TOOL" = "k6" ]; then
  cat > "$K6_SCRIPT" << 'EOFK6'
import http from 'k6/http';
import { sleep, check } from 'k6';
import { Rate } from 'k6/metrics';

const failRate = new Rate('failed_requests');
const BASE_URL = __ENV.BASE_URL || 'http://192.168.0.108:8083';

const PAGES = [
  BASE_URL + '/',
  BASE_URL + '/beranda/',
  BASE_URL + '/profil-kampus/',
  BASE_URL + '/berita/',
  BASE_URL + '/?s=kampus',
];

export let options = {
  stages: [
    { duration: `${__ENV.DURATION || '60'}s`, target: parseInt(__ENV.VUS || '10') },
    { duration: '15s', target: 0 },
  ],
  thresholds: {
    http_req_duration: ['p(95)<8000'],
    failed_requests:   ['rate<0.2'],
  },
};

export default function () {
  const url = PAGES[Math.floor(Math.random() * PAGES.length)];
  const res = http.get(url, { timeout: '10s' });
  const ok = check(res, {
    'status 200 or 301': (r) => r.status === 200 || r.status === 301 || r.status === 302,
  });
  failRate.add(!ok);
  sleep(Math.random() * 2 + 1);
}
EOFK6
  info "k6 script ditulis ke ${K6_SCRIPT}"
fi

# ==============================================================================
# FUNGSI JALANKAN STAGE
# ==============================================================================
run_stage_k6() {
  local STAGE_NUM="$1"
  local VUS="$2"
  local OUT_FILE="${OUT_DIR}/stage${STAGE_NUM}_${VUS}vus.json"
  info "Stage ${STAGE_NUM}: ${VUS} pengguna virtual selama ${STAGE_DURATION}s..."
  k6 run \
    --vus "$VUS" \
    --duration "${STAGE_DURATION}s" \
    --env VUS="$VUS" \
    --env DURATION="$STAGE_DURATION" \
    --env BASE_URL="$TARGET_URL" \
    --out "json=${OUT_FILE}" \
    "$K6_SCRIPT" 2>&1 | tee "${OUT_DIR}/stage${STAGE_NUM}_${VUS}vus.log"
  success "Stage ${STAGE_NUM} selesai. Hasil: ${OUT_FILE}"
}

run_stage_wrk() {
  local STAGE_NUM="$1"
  local VUS="$2"
  local OUT_FILE="${OUT_DIR}/stage${STAGE_NUM}_${VUS}vus.txt"
  local THREADS
  THREADS=$(( VUS > 4 ? 4 : VUS ))   # wrk: jumlah thread, biasanya <= jumlah CPU
  info "Stage ${STAGE_NUM}: ${VUS} koneksi, ${THREADS} thread, ${STAGE_DURATION}s..."
  wrk -t"$THREADS" -c"$VUS" -d"${STAGE_DURATION}s" \
    --timeout 10s --latency \
    "$TARGET_URL/" > "$OUT_FILE" 2>&1
  cat "$OUT_FILE"
  success "Stage ${STAGE_NUM} selesai. Hasil: ${OUT_FILE}"
}

countdown() {
  local SEC="$1"
  for i in $(seq "$SEC" -1 1); do
    printf "\r  Menunggu %2d detik sebelum stage berikutnya..." "$i"
    sleep 1
  done
  echo ""
}

# ==============================================================================
# JALANKAN SEMUA STAGE
# ==============================================================================
SUMMARY_FILE="${OUT_DIR}/summary.txt"
echo "Portal Kampus Load Test - $(date)" > "$SUMMARY_FILE"
echo "Target: ${TARGET_URL}" >> "$SUMMARY_FILE"
echo "Tool: ${TOOL}" >> "$SUMMARY_FILE"
echo "==========================================" >> "$SUMMARY_FILE"

for STAGE_NUM in 1 2 3 4; do
  VUS="${STAGES[$STAGE_NUM]}"

  if ! should_run_stage "$STAGE_NUM"; then
    warn "Stage ${STAGE_NUM} (${VUS} VUs) dilewati."
    continue
  fi

  echo ""
  echo -e "${YELLOW}>>> STAGE ${STAGE_NUM}: ${VUS} Pengguna Virtual <<<${NC}"
  echo "Stage ${STAGE_NUM}: ${VUS} VUs, ${STAGE_DURATION}s" >> "$SUMMARY_FILE"

  if [ "$TOOL" = "k6" ]; then
    run_stage_k6 "$STAGE_NUM" "$VUS"
  else
    run_stage_wrk "$STAGE_NUM" "$VUS"
  fi

  echo "  Output: ${OUT_DIR}/stage${STAGE_NUM}_${VUS}vus.*" >> "$SUMMARY_FILE"

  if [ "$STAGE_NUM" -lt 4 ] && should_run_stage $((STAGE_NUM+1)); then
    countdown "$WAIT_BETWEEN"
  fi
done

# ==============================================================================
# RINGKASAN
# ==============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  UJI BEBAN SELESAI${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  Hasil tersimpan di: ${OUT_DIR}/"
ls -lh "$OUT_DIR/" | tail -n +2
echo ""
echo "Selesai: $(date)" >> "$SUMMARY_FILE"
success "Lihat ringkasan: ${SUMMARY_FILE}"

