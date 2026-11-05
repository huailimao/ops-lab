#!/bin/bash
# 单机巡检脚本 —— 一行一指标，WARN 表示越界
# 退出码固定 0，靠最后一行 RESULT 里的 warn 数判断
# 巡检项: DISK / INODE / LOAD / MEM / SVC / PORT / SSH_FAIL / REBOOT

HOST=$(hostname)
WARN=0

row() { printf "%-10s %-38s %s\n" "$1" "$2" "$3"; }
warn_if() {   # $1=指标 $2=是否越界(1/0) $3=描述
  if [ "$2" = "1" ]; then row "$1" "$3" "WARN"; WARN=$((WARN+1)); else row "$1" "$3" "OK"; fi
}
isnum() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

# 1. 磁盘使用率（>=80% WARN）
while read -r u m; do
  isnum "$u" || continue
  w=0; [ "$u" -ge 80 ] && w=1
  warn_if DISK "$w" "$m ${u}%"
done < <(df -P -x tmpfs -x devtmpfs -x overlay 2>/dev/null | awk 'NR>1 {gsub("%","",$5); print $5, $6}')

# 2. inode 使用率（>=80% WARN；vfat 显示 "-" 的直接跳过）
while read -r u m; do
  isnum "$u" || continue
  w=0; [ "$u" -ge 80 ] && w=1
  warn_if INODE "$w" "$m ${u}%"
done < <(df -Pi -x tmpfs -x devtmpfs -x overlay 2>/dev/null | awk 'NR>1 {gsub("%","",$5); print $5, $6}')

# 3. 负载 vs 核数
L=$(awk '{print $1}' /proc/loadavg 2>/dev/null); L=${L:-0}
C=$(nproc 2>/dev/null); C=${C:-1}
w=0
awk -v l="$L" -v c="$C" 'BEGIN{exit !(l>c)}' && w=1
warn_if LOAD "$w" "1m=${L} cores=${C}"

# 4. 内存使用率（>=90% WARN）
M=$(free 2>/dev/null | awk '/^Mem:/{printf "%.0f", $3/$2*100}'); M=${M:-0}
isnum "$M" || M=0
w=0; [ "$M" -ge 90 ] && w=1
warn_if MEM "$w" "${M}%"

# 5. 关键服务（node_exporter 是监控探针本身，也必须保活）
for svc in sshd firewalld chronyd node_exporter; do
  a=$(systemctl is-active "$svc" 2>/dev/null); a=${a:-unknown}
  w=0; [ "$a" != "active" ] && w=1
  warn_if SVC "$w" "$svc=${a}"
done

# 6. 关键端口逐个探测（不再看总数量）
for p in 22 9100; do
  if ss -lnt 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${p}\$"; then w=0; else w=1; fi
  warn_if PORT "$w" "port=${p}"
done

# 7. 失败登录统计（/var/log/secure 属 root，用 sudo -n 兜底）
F=$(sudo -n grep -c "Failed password" /var/log/secure 2>/dev/null)
if isnum "$F"; then
  w=0; [ "$F" -ge 50 ] && w=1
  warn_if SSH_FAIL "$w" "count=${F}"
else
  row SSH_FAIL "count=n/a" "OK"
fi

# 8. 待重启
if command -v needs-restarting >/dev/null 2>&1; then
  if needs-restarting -r >/dev/null 2>&1; then
    row REBOOT "no" "OK"
  else
    row REBOOT "required" "WARN"; WARN=$((WARN+1))
  fi
fi

echo "RESULT ${HOST} warn=${WARN}"
exit 0
