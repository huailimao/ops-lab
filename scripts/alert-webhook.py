#!/usr/bin/env python3
"""Alertmanager 落盘接收器。

为什么需要它：告警规则触发只发生在 Prometheus 内部，规则文件写对不代表
通知链路通。真正要证明的是「Prometheus -> Alertmanager -> 接收端」整条链路，
所以这里起一个最小的 HTTP 端点，把收到的告警原始 payload 按 JSON 行追加到日志，
再用 `curl http://127.0.0.1:9093/api/v2/alerts` 与日志两头对齐。

生产环境这一段替换成企业微信/钉钉/邮件机器人即可，Alertmanager 的路由配置不用改。
"""
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

# 容器内路径，宿主机上由 compose 挂到 /opt/alert-webhook/logs
LOG = "/data/alertmanager-webhook.log"
PORT = 5001


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/alerts":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)

        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return

        ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        for alert in payload.get("alerts", []):
            labels = alert.get("labels", {})
            record = {
                "ts": ts,
                "status": alert.get("status"),
                "alertname": labels.get("alertname"),
                "severity": labels.get("severity"),
                "instance": labels.get("instance"),
                "summary": alert.get("annotations", {}).get("summary"),
                "startsAt": alert.get("startsAt"),
                "endsAt": alert.get("endsAt"),
                "fingerprint": alert.get("fingerprint"),
            }
            with open(LOG, "a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, fmt, *args):
        # 默认访问日志会刷屏 journald，只保留告警内容
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
