#!/bin/bash
# ==============================================================================
# monitor.sh - Koleksi Metrik Sistem untuk Skripsi
# Judul: "Analisis Performa dan Stabilitas Xiaomi Redmi Note 4
#         Berbasis postmarketOS sebagai Low-Power Docker Host"
#
# USAGE: bash scripts/monitor.sh [INTERVAL_DETIK] [DURASI_DETIK]
# Contoh: bash scripts/monitor.sh 10 3600   # Monitor 1 jam, interval 10 detik
#         bash scripts/monitor.sh 5          # Monitor selamanya, interval 5 detik
# ==============================================================================
set -euo pipefail

INTERVAL="${1:-10}"
DURATION="${2:-0}"  # 0 = jalankan selamanya

mkdir -p logs

TIMESTAMP_START=$(date +%Y%m%d_%H%M%S)
CSV_FILE="logs/metrics_${TIMESTAMP_START}.csv"

# --- Warna output ---
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# --- Flag ---
VERBOSE=0
HEADER_ONLY=0
for ARG in "$@"; do
  case "$ARG" in
    --verbose) VERBOSE=1 ;;
    --header-only) HEADER_ONLY=1 ;;
  esac
done

ROW_COUNT=0
START_TIME=$(date +%s)

# --- Handler Ctrl+C ---
cleanup() {
  echo ""
  echo -e "${GREEN}[monitor] Dihentikan. Total baris: ${ROW_COUNT}${NC}"
  echo -e "${GREEN}[monitor] Data tersimpan di: ${CSV_FILE}${NC}"
  exit 0
}
trap cleanup SIGINT SIGTERM

# ==============================================================================
# TULIS HEADER CSV
# ==============================================================================
HEADER="timestamp,uptime_seconds,load_avg_1m,load_avg_5m,load_avg_15m"
HEADER="${HEADER},mem_total_mb,mem_used_mb,mem_free_mb,mem_available_mb,swap_used_mb"
HEADER="${HEADER},cpu_temp_zone0_c,cpu_temp_zone1_c,cpu_temp_zone2_c,cpu_temp_zone3_c"
HEADER="${HEADER},cpu_freq_mhz"
HEADER="${HEADER},container_name,container_cpu_pct,container_mem_mb,container_mem_pct,net_rx_mb,net_tx_mb"

echo "$HEADER" > "$CSV_FILE"

if [ "$HEADER_ONLY" -eq 1 ]; then
  echo "Header CSV:"
  echo "$HEADER"
  exit 0
fi

echo -e "${CYAN}[monitor] Mulai merekam ke: ${CSV_FILE}${NC}"
echo -e "${CYAN}[monitor] Interval: ${INTERVAL}s | Durasi: ${DURATION}s (0=selamanya)${NC}"
echo -e "${CYAN}[monitor] Tekan Ctrl+C untuk berhenti${NC}"
echo ""

# ==============================================================================
# FUNGSI BACA METRIK
# ==============================================================================

get_uptime() {
  awk '{print $1}' /proc/uptime 2>/dev/null || echo "0"
}

get_load() {
  awk '{print $1,$2,$3}' /proc/loadavg 2>/dev/null || echo "0 0 0"
}

get_memory() {
  # Kembalikan: total_mb used_mb free_mb available_mb swap_used_mb
  awk '
    /^MemTotal:/     { total=$2 }
    /^MemFree:/      { free=$2 }
    /^MemAvailable:/ { avail=$2 }
    /^SwapTotal:/    { stotal=$2 }
    /^SwapFree:/     { sfree=$2 }
    END {
      used = total - avail
      swap_used = stotal - sfree
      printf "%.1f %.1f %.1f %.1f %.1f",
        total/1024, used/1024, free/1024, avail/1024, swap_used/1024
    }
  ' /proc/meminfo 2>/dev/null || echo "0 0 0 0 0"
}

get_cpu_temp() {
  # Baca hingga 4 thermal zone, default 0 jika tidak ada
  local ZONES=("0" "0" "0" "0")
  local IDX=0
  for ZONE_PATH in /sys/class/thermal/thermal_zone*/temp; do
    if [ "$IDX" -ge 4 ]; then break; fi
    if [ -f "$ZONE_PATH" ]; then
      RAW=$(cat "$ZONE_PATH" 2>/dev/null || echo "0")
      ZONES[$IDX]=$(awk "BEGIN{printf \"%.1f\", $RAW/1000}")
    fi
    IDX=$((IDX+1))
  done
  echo "${ZONES[0]} ${ZONES[1]} ${ZONES[2]} ${ZONES[3]}"
}

get_cpu_freq() {
  local FREQ_PATH="/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
  if [ -f "$FREQ_PATH" ]; then
    awk '{printf "%.0f", $1/1000}' "$FREQ_PATH" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

parse_net_io() {
  # Input: "1.23MB / 456kB" -> output: rx_mb tx_mb
  local IO="$1"
  local RX TX
  RX=$(echo "$IO" | awk -F'/' '{print $1}' | tr -d ' ')
  TX=$(echo "$IO" | awk -F'/' '{print $2}' | tr -d ' ')

  to_mb() {
    local VAL="$1"
    if echo "$VAL" | grep -qi 'gb'; then
      awk "BEGIN{printf \"%.2f\", $(echo "$VAL" | tr -d 'GgBb')*1024}"
    elif echo "$VAL" | grep -qi 'mb'; then
      awk "BEGIN{printf \"%.2f\", $(echo "$VAL" | tr -d 'MmBb')}"
    elif echo "$VAL" | grep -qi 'kb'; then
      awk "BEGIN{printf \"%.4f\", $(echo "$VAL" | tr -d 'KkBb')/1024}"
    else
      awk "BEGIN{printf \"%.6f\", $(echo "$VAL" | tr -d 'Bb')/1048576}"
    fi
  }

  echo "$(to_mb "$RX") $(to_mb "$TX")"
}

parse_mem_usage() {
  # Input: "123MiB / 768MiB" -> output: used_mb
  echo "$1" | awk -F'/' '{print $1}' | awk '{
    val=$1; unit=$2
    if (unit ~ /GiB/) val=val*1024
    printf "%.1f", val
  }'
}

# ==============================================================================
# LOOP UTAMA
# ==============================================================================
while true; do
  NOW=$(date +%s)
  if [ "$DURATION" -gt 0 ] && [ $((NOW - START_TIME)) -ge "$DURATION" ]; then
    break
  fi

  TIMESTAMP=$(date +%Y-%m-%dT%H:%M:%S)
  UPTIME=$(get_uptime)

  read -r LOAD1 LOAD5 LOAD15 <<< "$(get_load)"
  read -r MEM_TOTAL MEM_USED MEM_FREE MEM_AVAIL SWAP_USED <<< "$(get_memory)"
  read -r TEMP0 TEMP1 TEMP2 TEMP3 <<< "$(get_cpu_temp)"
  CPU_FREQ=$(get_cpu_freq)

  # Ambil docker stats untuk container yang relevan
  DOCKER_OUTPUT=$(docker stats --no-stream \
    --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}}" \
    2>/dev/null | grep -E "wordpress|_db|redis" || echo "")

  if [ -z "$DOCKER_OUTPUT" ]; then
    # Tidak ada container yang cocok, tulis satu baris dengan placeholder
    ROW="${TIMESTAMP},${UPTIME},${LOAD1},${LOAD5},${LOAD15}"
    ROW="${ROW},${MEM_TOTAL},${MEM_USED},${MEM_FREE},${MEM_AVAIL},${SWAP_USED}"
    ROW="${ROW},${TEMP0},${TEMP1},${TEMP2},${TEMP3},${CPU_FREQ}"
    ROW="${ROW},none,0,0,0,0,0"
    echo "$ROW" >> "$CSV_FILE"
    ROW_COUNT=$((ROW_COUNT+1))
  else
    # Tulis satu baris per container
    while IFS= read -r LINE; do
      CNAME=$(echo "$LINE" | cut -d',' -f1)
      CPU_PCT=$(echo "$LINE" | cut -d',' -f2 | tr -d '%')
      MEM_USAGE=$(echo "$LINE" | cut -d',' -f3)
      MEM_PCT=$(echo "$LINE" | cut -d',' -f4 | tr -d '%')
      NET_IO=$(echo "$LINE" | cut -d',' -f5)

      CMEM_MB=$(parse_mem_usage "$MEM_USAGE")
      read -r NET_RX NET_TX <<< "$(parse_net_io "$NET_IO")"

      ROW="${TIMESTAMP},${UPTIME},${LOAD1},${LOAD5},${LOAD15}"
      ROW="${ROW},${MEM_TOTAL},${MEM_USED},${MEM_FREE},${MEM_AVAIL},${SWAP_USED}"
      ROW="${ROW},${TEMP0},${TEMP1},${TEMP2},${TEMP3},${CPU_FREQ}"
      ROW="${ROW},${CNAME},${CPU_PCT},${CMEM_MB},${MEM_PCT},${NET_RX},${NET_TX}"

      echo "$ROW" >> "$CSV_FILE"
      ROW_COUNT=$((ROW_COUNT+1))

      if [ "$VERBOSE" -eq 1 ]; then
        echo "$ROW"
      fi
    done <<< "$DOCKER_OUTPUT"
  fi

  # Tampilkan status ringkas di stderr
  LATEST_TEMP="${TEMP0}°C"
  printf "\r${CYAN}[monitor]${NC} Baris: %-5d | Waktu: %s | Suhu: %-8s | RAM dipakai: %s MB    " \
    "$ROW_COUNT" "$TIMESTAMP" "$LATEST_TEMP" "$MEM_USED" >&2

  sleep "$INTERVAL"
done

cleanup

