#!/bin/bash
# 准备 exporter 二进制到 /opt/ops-pkg（不入库，仓库里只保留这份脚本）
#
# 为什么不用 GitHub release 直链：实测被限速到约 4KB/s，
# 8MB 的包 60 秒只下来 236KB，直接超时。
# 容器镜像源可用，于是从官方镜像里把二进制 cp 出来。
#
# 用到的镜像：
#   prom/mysqld-exporter:v0.15.1   -> /bin/mysqld_exporter
#   oliver006/redis_exporter:v1.62.0 -> /redis_exporter
set -euo pipefail

DEST=/opt/ops-pkg
MIRROR=${MIRROR:-docker.m.daocloud.io}
mkdir -p "$DEST"

extract() {
  local image="$1" path="$2" name="$3" tag="$4"
  if [ -x "$DEST/$name" ]; then
    echo "  $name 已存在，跳过"
    return
  fi
  docker pull -q "$MIRROR/$image:$tag" >/dev/null
  cid=$(docker create "$MIRROR/$image:$tag")
  docker cp "$cid:$path" "$DEST/$name"
  docker rm -f "$cid" >/dev/null
  chmod 0755 "$DEST/$name"
  echo "  $name 就绪：$("$DEST/$name" --version 2>&1 | head -1)"
}

echo "== 提取 exporter 二进制 =="
extract prom/mysqld-exporter /bin/mysqld_exporter mysqld_exporter v0.15.1
extract oliver006/redis_exporter /redis_exporter redis_exporter v1.62.0
ls -l "$DEST"
