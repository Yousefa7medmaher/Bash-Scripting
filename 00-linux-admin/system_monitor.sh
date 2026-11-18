#!/usr/bin/env bash
set -Eeuo pipefail

CPU_THRESHOLD="${CPU_THRESHOLD:-80}"
MEMORY_THRESHOLD="${MEMORY_THRESHOLD:-80}"
DISK_THRESHOLD="${DISK_THRESHOLD:-80}"

for threshold in "$CPU_THRESHOLD" "$MEMORY_THRESHOLD" "$DISK_THRESHOLD"; do
  [[ "$threshold" =~ ^[0-9]+$ ]] || { echo "Thresholds must be integers." >&2; exit 2; }
done

read_cpu() {
  local label user nice system idle iowait irq softirq steal
  read -r label user nice system idle iowait irq softirq steal _ < /proc/stat
  CPU_TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal))
  CPU_IDLE=$((idle + iowait))
}

check_cpu_usage() {
  read_cpu
  local total_before="$CPU_TOTAL" idle_before="$CPU_IDLE"
  sleep 1
  read_cpu
  local total_delta=$((CPU_TOTAL - total_before))
  local idle_delta=$((CPU_IDLE - idle_before))
  if ((total_delta > 0)); then
    local usage
    usage="$(awk -v total="$total_delta" -v idle="$idle_delta" \
      'BEGIN { printf "%.2f", (total-idle)*100/total }')"
    if awk -v usage="$usage" -v threshold="$CPU_THRESHOLD" 'BEGIN { exit !(usage > threshold) }'; then
      printf 'High CPU usage: %s%%\n' "$usage"
    fi
  fi
}

check_memory_usage() {
  local usage
  usage="$(awk '/MemTotal:/ { total=$2 } /MemAvailable:/ { available=$2 }
    END { if (total > 0) printf "%.2f", (total-available)*100/total }' /proc/meminfo)"
  if awk -v usage="$usage" -v threshold="$MEMORY_THRESHOLD" 'BEGIN { exit !(usage > threshold) }'; then
    printf 'High memory usage: %s%%\n' "$usage"
  fi
}

check_disk_usage() {
  local usage
  usage="$(df -P / | awk 'NR==2 { gsub(/%/, "", $5); print $5 }')"
  if ((usage > DISK_THRESHOLD)); then
    printf 'High disk usage: %s%%\n' "$usage"
  fi
}

check_cpu_usage
check_memory_usage
check_disk_usage
