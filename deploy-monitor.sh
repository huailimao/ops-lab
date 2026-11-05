#!/bin/bash
# P2 监控补全：Alertmanager + webhook 接收器 + Grafana 自动装配
# 在 bastion 的 /root/ops-lab 下执行。幂等，可重复运行。
set -euo pipefail
cd /root/ops-lab

echo "== 0. 备份现有配置 =="
[ -f /opt/prometheus/prometheus.yml ] && cp -a /opt/prometheus/prometheus.yml /opt/prometheus/prometheus.yml.bak.p2
[ -f /opt/prometheus/rules.yml ] && cp -a /opt/prometheus/rules.yml /opt/prometheus/rules.yml.bak.p2

echo "== 1. 建目录 =="
mkdir -p /opt/alertmanager/data /opt/alert-webhook/logs
mkdir -p /opt/grafana-provisioning/datasources /opt/grafana-provisioning/dashboards

echo "== 2. 下发配置 =="
install -m 0644 monitor/alertmanager.yml /opt/alertmanager/alertmanager.yml
install -m 0644 monitor/prometheus.yml /opt/prometheus/prometheus.yml
install -m 0644 monitor/rules.yml /opt/prometheus/rules.yml
install -m 0644 monitor/grafana/provisioning/datasources/prometheus.yml /opt/grafana-provisioning/datasources/prometheus.yml
install -m 0644 monitor/grafana/provisioning/dashboards/provider.yml /opt/grafana-provisioning/dashboards/provider.yml
if ls monitor/dashboards/*.json >/dev/null 2>&1; then
  cp -f monitor/dashboards/*.json /opt/grafana-provisioning/dashboards/
  echo "  看板 JSON: $(ls monitor/dashboards/*.json | wc -l) 个"
else
  echo "  看板 JSON: 暂无"
fi

echo "== 3. 内核转发（容器抓取局域网目标的前提）=="
# ip_forward=0 时，容器到同网段目标的包在宿主机内核层就被丢弃：
# 现象是所有 target 报 context deadline exceeded，而 eth0 上抓不到任何包。
# 写完 sysctl.d 后 firewall-cmd --reload 不会再把它改回去（实测）。
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-docker-forward.conf
sysctl -q -w net.ipv4.ip_forward=1
echo "  ip_forward=$(sysctl -n net.ipv4.ip_forward)"

echo "== 3b. webhook 接收器（容器化，随 compose 启动）=="
install -m 0755 scripts/alert-webhook.py /opt/alert-webhook/alert-webhook.py
if systemctl list-unit-files 2>/dev/null | grep -q '^alert-webhook.service'; then
  systemctl disable --now alert-webhook.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/alert-webhook.service
  systemctl daemon-reload
  echo "  已移除旧的 systemd 版接收器"
fi

echo "== 4. 起容器 =="
cd monitor
docker compose up -d
cd ..

echo "== 5. 等待就绪 =="
for i in $(seq 1 30); do
  am=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9093/-/ready || true)
  pr=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9090/-/ready || true)
  [ "$am" = "200" ] && [ "$pr" = "200" ] && { echo "  alertmanager ready, prometheus ready"; break; }
  sleep 2
done

echo "== 6. 热加载 Prometheus =="
curl -s -X POST http://127.0.0.1:9090/-/reload && echo "  reload 已提交"

echo "== 7. 容器状态 =="
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
