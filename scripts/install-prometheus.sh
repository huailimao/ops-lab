#!/bin/bash
# 在跳板机上安装 Prometheus（二进制方式）
# 用法：sudo bash install-prometheus.sh
# 说明：配置文件不在这里生成，由调用方从 ops-day3/prometheus/ 拷到 /opt/prometheus/

set -u

VER="2.51.0"
PKG="prometheus-${VER}.linux-amd64"
URL_GH="https://github.com/prometheus/prometheus/releases/download/v${VER}/${PKG}.tar.gz"
URL_MIRROR="https://mirrors.aliyun.com/prometheus/prometheus/v${VER}/${PKG}.tar.gz"
TMP="/tmp/${PKG}.tar.gz"

echo "==> 1/5 下载 Prometheus ${VER}"
if [ ! -f "$TMP" ]; then
  if ! curl -fL --connect-timeout 15 --max-time 300 -o "$TMP" "$URL_GH"; then
    echo "    GitHub 下载失败，改用阿里云镜像"
    if ! curl -fL --connect-timeout 15 --max-time 300 -o "$TMP" "$URL_MIRROR"; then
      echo "    两个源都失败。请手动下载后放到 $TMP 再重跑本脚本："
      echo "    $URL_GH"
      exit 1
    fi
  fi
fi
ls -lh "$TMP"

echo "==> 2/5 解压到 /opt/prometheus"
mkdir -p /opt/prometheus
tar xzf "$TMP" -C /tmp
cp -f "/tmp/${PKG}/prometheus" "/tmp/${PKG}/promtool" /opt/prometheus/
mkdir -p /opt/prometheus/console_libraries /opt/prometheus/consoles /opt/prometheus/data
cp -rf "/tmp/${PKG}/consoles/"* /opt/prometheus/consoles/ 2>/dev/null
cp -rf "/tmp/${PKG}/console_libraries/"* /opt/prometheus/console_libraries/ 2>/dev/null

echo "==> 3/5 创建运行用户"
id prometheus >/dev/null 2>&1 || useradd -rs /bin/false prometheus
chown -R prometheus:prometheus /opt/prometheus

echo "==> 4/5 写入 systemd unit"
cat > /etc/systemd/system/prometheus.service <<'UNIT'
[Unit]
Description=Prometheus
Documentation=https://prometheus.io/docs/introduction/overview/
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/opt/prometheus/prometheus \
  --config.file=/opt/prometheus/prometheus.yml \
  --storage.tsdb.path=/opt/prometheus/data \
  --storage.tsdb.retention.time=15d \
  --web.enable-lifecycle
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

echo "==> 5/5 启动"
if [ ! -f /opt/prometheus/prometheus.yml ]; then
  echo "    !! 缺少 /opt/prometheus/prometheus.yml"
  echo "    先把配置拷贝过去再启动："
  echo "      sudo cp /opt/ops-pkg/prometheus/prometheus.yml /opt/prometheus/"
  echo "      sudo cp /opt/ops-pkg/prometheus/rules.yml     /opt/prometheus/"
  echo "      sudo chown -R prometheus:prometheus /opt/prometheus"
  exit 1
fi

systemctl daemon-reload
systemctl enable --now prometheus
sleep 3
systemctl is-active prometheus
echo "本机访问：http://127.0.0.1:9090"
