#!/bin/bash
# 单机巡检脚本 —— 一行一指标，WARN 表示越界
# 退出码固定 0，靠最后一行 RESULT 里的 warn 数判断

HOST=$(hostname)
WARN=0

row() { printf "%-10s %-38s %s\n" "$1" "$2" "$3"; }

# 1. 磁盘使用率
while read -r u m; do
  u=${u%\%}
  s=OK; [ "$u" -ge 80 ] && { s=WARN; WARN=1; }
  row DISK "$m ${u}%" "$s"
done < <(df -P -x tmpfs -x devtmpfs -x overlay 2>/dev/null | awk 'NR>1 {print $5, $6}')

# 2. inode 使用率
while read -r u m; do
  u=${u%\%}
  s=OK; [ "$u" -ge 80 ] && { s=WARN; WARN=1; }
  row INODE "$m ${u}%" "$s"
done < <(df -Pi -x tmpfs -x devtmpfs -x overlay 2>/dev/null | awk 'NR>1 {print $5, $6}')

# 3. 负载 vs 核数
L=$(awk '{print $1}' /proc/loadavg)
C=$(nproc)
s=OK
awk -v l="$L" -v c="$C" 'BEGIN{exit !(l>c)}' && { s=WARN; WARN=1; }
row LOAD "1m=${L} cores=${C}" "$s"

# 4. 内存
M=$(free | awk '/^Mem:/{printf "%.0f", $3/$2*100}')
s=OK; [ "$M" -ge 90 ] && { s=WARN; WARN=1; }
row MEM "${M}%" "$s"

# 5. 关键服务
for svc in sshd firewalld chronyd; do
  a=$(systemctl is-active "$svc" 2>/dev/null)
  s=OK; [ "$a" != "active" ] && { s=WARN; WARN=1; }
  row SVC "$svc=${a}" "$s"
done

# 6. 监听端口数
P=$(ss -lnt 2>/dev/null | awk 'NR>1' | wc -l)
row PORT "listen=${P}" "OK"

# 7. 失败登录统计
F=$(grep -c "Failed password" /var/log/secure 2>/dev/null)
row SSH_FAIL "count=${F:-0}" "OK"

# 8. 待重启
if command -v needs-restarting >/dev/null 2>&1; then
  if needs-restarting -r >/dev/null 2>&1; then
    row REBOOT "no" "OK"
  else
    row REBOOT "required" "WARN"; WARN=1
  fi
fi

echo "RESULT ${HOST} warn=${WARN}"
exit 0
