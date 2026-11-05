# 故障排查记录

本文件记录 ops-lab 环境在**建设期**与**演练期**遇到的真实故障。每条按「现象 → 排查 → 根因 → 修复 → 验证」组织，重点写**踩过的坑**而不是成功经验。

## 环境基线

| 项 | 配置 |
|---|---|
| 节点 | 阿里云 ECS 20 台：1 bastion + 2 web + 17 app（`192.168.1.222-241`） |
| 系统 | Alibaba Cloud Linux 3（Python 3.6.8） |
| 编排 | Ansible，`ops` 用户 + 密钥登录 + sudo 免密 |
| 监控 | Prometheus v2.51.0 + Alertmanager v0.27.0 + Grafana 10.4.2（docker compose） |
| 数据层 | MySQL 8.0.46 一主一从（GTID）+ Redis 6.2.24 主从 + 3 哨兵（`.237`–`.239`） |
| 巡检 | `/opt/ops-lab/check.sh`，8 类指标，末行 `RESULT <host> warn=N` |
| 告警规则 | 12 条：node-basic 6 条 + data-layer 6 条 |

---

# 一、主动演练故障（人为注入）

## 1. 服务中断：停止 agg-02 的 node_exporter

**现象**

Prometheus `/targets` 显示 `node (19/20 up)`，`192.168.1.227:9100` 标红 DOWN，Error 列为：

```
Get "http://192.168.1.227:9100/metrics": dial tcp 192.168.1.227:9100: connect: connection refused
```

**三路观测**

| 视角 | 结果 |
|---|---|
| Prometheus `up` 指标 | `1` → `0` 台阶（拐点 19:23） |
| Prometheus 告警 | `NodeDown` 规则评估中 |
| 巡检脚本 | `SVC node_exporter=inactive WARN`、`PORT port=9100 WARN`、`RESULT warn=2` |

**根因**

`systemctl stop node_exporter` 后 9100 端口不再监听。`connection refused` 与网络不通的 `timeout` 有本质区别：前者是**进程不在**，后者是**链路不通**，这条错误文本本身就完成了二分之一的分诊。

**修复**

```bash
systemctl start node_exporter
```

20 秒后 `21/21 up`。

**衍生问题**

同期发现巡检脚本对服务中断**毫无感知**：`PORT` 只统计监听端口总数（`listen=2 OK`），`SVC` 列表里没有 `node_exporter`。详见案例 7。

---

## 2. 磁盘告警：根分区填充至 83%

**现象**

在 agg-02 上用 `fallocate` 分配 22G 后，`df -h /` 变为 `40G 31G 6.5G 83%`，`DiskWillFull` 进入 FIRING：

```
DiskWillFull  192.168.1.227:9100  firing  16.65
```

**`16.65` 是什么**

不是使用率，而是规则表达式算出的**可用空间占比**：

```promql
(node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}
 / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}) * 100 < 20
```

`83%` 已用 + `16.65%` 可用 ≈ 100，两个数字互为校验。**规则阈值写的是「剩余」，不是「使用」**，看告警值时容易误读。

**`for: 5m` 的作用**

从条件满足到 FIRING 有 5 分钟缓冲，防止瞬时写盘（如日志轮转、镜像拉取）触发误报。

**修复**

```bash
rm -f /fill.img
```

`df` 回落至 24%，40 秒后告警归零。

**注意**

`fstype!~"tmpfs|overlay"` 这个过滤**不能省**：容器里的 overlay 分区和 tmpfs 容量极小且天然写满，不加过滤会产生大量噪音告警。

---

## 3. 负载告警：4 个 CPU 空转进程

**现象**

agg-02（2 核）跑 4 个 `yes > /dev/null` 后：

```
load average: 7.08, 2.34, 0.83
%Cpu(s): 40.0 us, 60.0 sy, 0.0 id
```

`HighLoad` FIRING，`Active Since 2026-11-05T12:29:39Z`（UTC，即 20:29:39），`Value 9.02`。

**时间线校验**

压测启动 20:29:14 → 条件满足约 20:29:39 → `for: 5m` → FIRING 20:34:39。实测告警激活时间与理论值一致，证明 `for` 语义正确落地，而不是「一超阈值就响」。

**压测代表性的局限（重要）**

`60% sy`（系统态）高于 `40% us`（用户态），因为 `yes > /dev/null` 本质是 `write()` 系统调用死循环，时间全耗在内核。真实业务（Java 计算、PHP 渲染）应以用户态为主。**用这种压测去论证「业务高负载下的表现」是不充分的**，只能验证告警链路是否连通。

**修复**

```bash
pkill -x yes
```

`load1` 指数衰减，约 2 分钟后 `告警数: 0`。清理期间告警仍为 firing 属正常现象，不要误判为「告警卡住不恢复」。

---

## 4. SSH 暴力破解：60 次失败登录 + firewalld 封禁

**现象**

从 agg-02 本机发起 60 次无密钥 SSH 尝试：

```bash
for i in $(seq 1 60); do
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i /dev/null ops@127.0.0.1 true 2>/dev/null
  sleep 0.3
done
```

日志产生 `Connection closed by authenticating user ops 127.0.0.1 port xxxxx [preauth]`，巡检脚本报：

```
SSH_FAIL   count=123    WARN
RESULT     agg-02       warn=1
```

**封禁响应**

```bash
firewall-cmd --add-rich-rule='rule family=ipv4 source address=192.168.1.223 \
  port port=22 protocol=tcp reject' --timeout=180
```

验证：从 223 连 227 由 `Permission denied`（能连上、认证失败）变为 `Connection timed out`（包被丢弃）。对照组 bastion(222) → 227 全程正常，证明**封了攻击源但没有封住运维通道**。

**三个必须注意的点**

1. `--timeout` 只作用于 runtime 规则，不写 `--permanent`，到期自动失效，避免把自己锁死。
2. 封 `127.0.0.1` 完全无效，详见案例 8。
3. 造流量必须放慢（`sleep 0.3`）。60 次不限速只落下 7 条日志，`/var/log/secure` 写入有速率限制，密集写入会被丢弃，导致指标永远到不了阈值。

---

# 二、建设期故障（真实踩坑）

## 5. Ansible `script` 模块报 "Could not find or access"

**现象**

```bash
ansible all -i inventory -m script -a "/root/ops-lab/check.sh"
```

5 台全部 `FAILED`，报 `Could not find or access '/root/ops-lab/check.sh' on the Ansible Controller`。

**根因**

`script` 模块的 `-a` 参数是**控制机**上的脚本路径，不是远端路径。当时脚本只在远端存在（甚至是后来才分发），控制机对应路径为空。

**修复**

三种正确做法，按场景选：

```bash
# A. 脚本已在远端：用 shell 执行远端路径
ansible all -i inventory -m shell -a "/opt/ops-lab/check.sh"

# B. 从控制机推送并执行
ansible all -i inventory -m script -a "scripts/check.sh"

# C. 落盘后再执行（需要保留脚本时）
ansible all -i inventory -m copy -a "src=scripts/check.sh dest=/opt/ops-lab/ mode=0755"
```

最终统一为 **C + 分发 playbook**（`playbooks/distribute-check.yml`），因为脚本要长期存在且被 Prometheus 之外的定时任务复用。

---

## 6. 巡检脚本的 SSH_FAIL 指标是假的（sudo 审计自指污染）

**现象**

`SSH_FAIL count` 每次巡检都上涨：`2` → `3` → `6` → `8`，但环境里**从未发生过一次真实攻击**。

**排查过程**

```bash
grep "Failed password" /var/log/secure | tail -3
```

输出全是这种行：

```
agg-02 sudo[5143]: ops : PWD=/home/ops ; USER=root ;
  COMMAND=/bin/grep -c 'Failed password' /var/log/secure
```

**根因**

`check.sh` 用 `sudo grep -c "Failed password" /var/log/secure` 统计失败登录，而 sudo 会把**执行的完整命令行**写进 `/var/log/secure`，命令行里恰好含 `Failed password` 这个字符串。于是 grep 匹配到了自己刚产生的那条审计记录 —— 典型的**自指污染**，指标会随巡检次数单调增长。

**修复**

先锚定进程名，再匹配失败模式：

```bash
F=$(sudo -n grep 'sshd' /var/log/secure 2>/dev/null \
    | grep -cE 'Failed password|Failed publickey|Invalid user|Connection closed by (invalid|authenticating) user')
```

**为什么不用 `grep -E 'sshd\[[0-9]+\]'`**

转义在多层 shell 传递中极易丢失（本次就出现 `\[` 被吃掉、变成 `$$` 的情况，导致正则完全失效且 `grep -c` 返回 0，看起来「改好了」其实没生效）。`grep 'sshd'` 不需要任何转义，逻辑等价。

**教训**

监控指标要排除**自身产生的审计痕迹**。凡是「查询行为本身会被记录到被查询对象中」的场景（日志统计、CLI 审计、访问日志分析）都有这个陷阱。

---

## 7. 巡检脚本三处缺陷：端口裸计数、服务清单缺失、inode 崩溃

**缺陷 1：`PORT listen=2 OK`**

原实现统计 `ss -lnt | wc -l` 的总行数，只要不是 0 就判 OK。停掉 node_exporter 后端口从 2 变 1，仍然 OK —— **对单服务中断完全无感知**。

修复为逐端口探测：

```bash
for p in 22 9100; do
  if ss -lnt | awk 'NR>1{print $4}' | grep -qE "[:.]${p}\$"; then w=0; else w=1; fi
  warn_if PORT "$w" "port=${p}"
done
```

**缺陷 2：`SVC` 列表没有 node_exporter**

监控探针自身也是关键服务，挂了等于监控失效。补进循环：`for svc in sshd firewalld chronyd node_exporter`。

**缺陷 3：`df -Pi` 导致 `integer expression expected`**

`/boot/efi`（vfat）不支持 inode 统计，`df -Pi` 的 IUse% 列返回 `-`。`[ "-" -ge 80 ]` 直接报 `integer expression expected`，且该行指标丢失。

修复：加 `isnum` 守卫，非数字直接跳过。

```bash
isnum() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
```

---

## 8. firewalld 封禁 127.0.0.1 无效

**现象**

rich rule 下发成功，`--list-rich-rules` 也能看到，但从本机连 22 仍然 `Permission denied`（说明 TCP 通了、到了认证阶段）。

**根因**

firewalld 对 **loopback 接口（`lo`）的流量全部放行**，`lo` 位于 `trusted` zone，rich rule 的 `reject` 根本匹配不到。封 `127.0.0.1` 在任何 firewalld 环境里都无效，这不是配置写错。

**修复**

改封真实网卡上的源地址（例：`192.168.1.223`），再从该地址发起连接即可验证。表现从 `Permission denied` 变为 `Connection timed out`（包被静默丢弃，攻击者连端口是否存在都无法判断，比 `refused` 更安全）。

**排查顺序**

封禁不生效时按此顺序查：① 源地址是否 loopback → ② 规则是否落在正确 zone（`--get-active-zones`）→ ③ 是否有更优先的 accept 规则 → ④ 安全组是否在上游放行（云上环境，安全组优先于 firewalld）。

---

## 9. Prometheus 配置热加载「成功」但 target 数量不变

**现象**

`curl -X POST localhost:9090/-/reload` 返回成功，日志有两次 `Completed loading of configuration file`，但 `/targets` 始终只有 6 个（预期 21 个）。

**排查**

```bash
stat -c '%i %y' /opt/prometheus/prometheus.yml
docker exec prometheus stat -c '%i %y' /etc/prometheus/prometheus.yml
```

host `inode=788031`，container `inode=787936` —— **inode 不一致**。

**根因**

compose 用的是**单文件 bind mount**（`/opt/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml`）。单文件挂载绑定的是 inode，用 `mv` 或 `rm` 重建文件后 inode 变化，容器里的 `/etc/prometheus/prometheus.yml` 仍指向旧的已删除 inode，**宿主机怎么改容器都看不见**。

**修复**

- 临时：用 `cat new > 原文件` 保留原 inode（重定向写入不改变 inode）；
- 根治：改为**目录挂载** `/opt/prometheus:/etc/prometheus:ro`。

**教训**

`promtool check config` 只校验语法，不证明内容是新版；`reload` 返回 200 也不证明加载了你的文件。验证配置是否生效，**看结果指标**（target 数量、`scrape_duration` 变化），不要看返回值。

---

## 10. 安全组跨层拦截导致 app 层 targets down

**现象**

20 台节点 9100 全部本地监听正常、firewalld 已放行，但 Prometheus 里 web 层（223/224）up，app 层（225/226）`context deadline exceeded`。

**排查**

```bash
# 在 web 节点上测 app 节点
ssh 192.168.1.223 'curl -m 3 http://192.168.1.225:9100/metrics'   # http=000
```

同层可达、跨层不可达 → 指向安全组。

**根因**

四层安全组按层隔离，`app` 层入方向只授权 `web` 安全组，不信任 `bastion`。而规则被误加到了 **web 安全组**（授权对象写对了，但加错了组）。

**修复**

在 **app 安全组** 的入方向增加一条：协议 TCP、端口 9100、授权对象选择 `sg-bastion`。

**设计说明**

入方向用「安全组」而非「IP 段」作为授权对象，后续扩容新机器无需改规则 —— 这也是为什么 20 台扩容时安全组零改动。

**同类问题再次出现（数据层）**

接数据层监控时，`9104`（mysqld_exporter）与 `9121`（redis_exporter）从跳板机访问返回 `curl: (7)` / `http=000`，
而宿主机 `firewalld` 已按 `192.168.1.0/24` 放行 —— 又是同一类：**`sg-app` 入方向只授权了 `9100`**。

处置：在 `sg-app` 入方向补两条，授权对象同样选 `sg-bastion`。规则没加之前，
`/targets` 上这 4 个数据层目标会一直 `down`，而 `mysql_up` 这类指标压根不存在，告警不会响 ——
**抓取目标 down 本身必须有一条告警**，否则「监控自己瞎了」没人知道（这是本次遗留的改进项）。

---

## 11. Docker 镜像拉取静默回退到官方仓库

**现象**

`daemon.json` 配了 `registry-mirrors`，`docker info` 也能看到，但 `docker compose up` 始终连 `registry-1.docker.io` 并超时。

**排查过程（逐层否定）**

1. `daemon.json` 改了但**没 restart docker** → `docker info` 显示的还是旧值；
2. restart 后 mirror 生效，但 `curl mirror/v2/` 返回 `200 {}` 且**没有 `Www-Authenticate` 头** → Docker 判定该 mirror 不是合法 registry，**静默回退**到官方源（不报错，只在 pull 时表现为超时）；
3. 换用真正的 registry 代理（返回 `401` + `Www-Authenticate`）后恢复正常。

**修复**

```bash
docker pull docker.m.daocloud.io/prom/prometheus:v2.51.0
docker tag  docker.m.daocloud.io/prom/prometheus:v2.51.0 prom/prometheus:v2.51.0
```

`compose` 里保留官方镜像名，实际镜像由 `docker tag` 提供，避免把代理地址写死进编排文件。

**判断 mirror 是否可用的标准**

`curl -D - https://<mirror>/v2/` 必须返回 **401** 且带 `Www-Authenticate: Bearer ...`。返回 200 的是「能连通但不是 registry」，Docker 不会用它。

---

## 12. 加固「已完成」，但 15 台的 root 仍能直接登录（配置漂移）

**现象**

早期记录写着「设置 `PermitRootLogin no` 后 root 登录被拒，加固生效」。按主机逐台核对生效值：

```bash
ansible all -i inventory -m shell -a "sudo -n sshd -T | grep '^permitrootlogin'"
```

```
192.168.1.222–226   permitrootlogin no     ← 加固过
192.168.1.227–241   permitrootlogin yes    ← 15 台从未加固
```

而 227–241 正是第二次扩容新增的机器，已经跑了几天业务。

**排查**

关键不是看 playbook 有没有「跑成功」，而是看它**到底改了什么**：

```bash
grep -nE 'sshd|PermitRoot|PasswordAuth' playbooks/harden.yml
# 无任何输出
```

`harden.yml` 只有三个任务：建 `ops` 用户、配免密 sudo、铺公钥 —— **不含任何 sshd 配置**。真正的 SSH 加固在另一个文件 `sshd-lockdown.yml` 里。扩容时因为新机器还没有 `ops` 用户，只跑了 `harden.yml`（且必须 `-e ansible_user=root`），`sshd-lockdown.yml` 被漏掉了。

**一个差点骗过自己的细节**

227 上 `passwordauthentication no`、`usedns no` 也都是 `no`，看起来像加固生效了。实际上那是**镜像默认值**：

```
147:PermitRootLogin yes            ← 镜像默认
148:PasswordAuthentication no      ← 镜像默认
```

`sshd -T` 只回答「结果是多少」，不回答「是谁改的」。判断加固是否执行，必须**逐项比对清单**（本例 4 项：`PermitRootLogin` / `PasswordAuthentication` / `UseDNS` / `GSSAPIAuthentication`），一项对得上不算数，四项全对才算。

**修复**

单台先验，再全量。`sshd -t` 校验在 `reload` 之前，配置写错时中止任务而不是把 sshd 打死 —— 这是 `sshd-lockdown.yml` 里最重要的一行：

```bash
ansible-playbook -i inventory playbooks/sshd-lockdown.yml --limit 192.168.1.227
```

双向验证（只验「root 被拒」是不够的，还得确认管理通道没断）：

```bash
ssh -i /root/.ssh/id_rsa ops@192.168.1.227 'hostname'    # → agg-02，正常
ssh -i /root/.ssh/id_rsa root@192.168.1.227 true         # → Permission denied (publickey)
```

确认后再放全量：`--limit` 剩余 14 台、`-f 5`。最终 **20/20 `permitrootlogin no`**。

**根因不是「忘了跑」，是没有单一入口**

6 个 playbook 各自独立，靠人记着「按顺序都跑一遍」。这种流程在第一次扩容就失效了 —— 而且失效得无声无息：`harden.yml` 返回全绿，机器也确实能连上，只是少了一道加固。

修复不是补一次命令，而是收敛入口：

| 文件 | 场景 | 身份 |
|---|---|---|
| `playbooks/bootstrap.yml` | 新机器首次接入（建 `ops` 用户） | `root`，唯一需要 root 的一步 |
| `playbooks/site.yml` | 其余全部：init → sshd-lockdown → firewall → 9100 → node_exporter → 巡检分发 | `ops` + sudo，全链路有审计 |

`site.yml` 幂等，扩容后重跑这一个文件即可。「漏跑某个 playbook」这件事在结构上不再可能发生。

**收敛入口的第一次全量执行就又抓到一处漂移**

```
192.168.1.224   ok=39  changed=1   (item=http) (item=https)
其余 19 台      ok=38  changed=0
```

224（web 节点）的 `firewall.yml` 里 80/443 两条放行没生效，是早期单机手工调整时漏掉的。**幂等入口的价值就在这里：它把「环境当前状态是否符合定义」变成一条命令就能回答的问题，而不是靠人回忆哪台机器改过什么。**

**顺带修掉的第二个问题：`state: restarted` 不幂等**

原始 `sshd-lockdown.yml` 最后是 `systemd: state: restarted`，导致每次执行都重启 sshd —— 20 台一起跑等于把全部在线会话踢掉一次，而且「每次都 changed」会淹没真正需要关注的变更。改为条件触发：

```yaml
    - name: 禁止 root 直接登录
      lineinfile: ...
      notify: reload sshd

  handlers:
    - name: reload sshd
      systemd: { name: sshd, state: reloaded }
```

两处改进：① 只有配置真的变了才触发；② 用 `reload`（SIGHUP）而不是 `restart`，新连接读到新配置，已有会话不断。改完连跑两次 `site.yml`，20 台全部 `changed=0`。

**教训**

- 「加固完成」以**逐台逐项的生效值**为准（`sshd -T` / `sysctl -a` / `firewall-cmd --list-all`），不以「playbook 返回 ok」为准
- 幂等 + 单一入口能消灭「漏跑」，流程文档不能 —— 文档写「记得都跑一遍」的那一刻，就已经注定会被漏掉
- 配置漂移最爱藏在**分批扩容**里：第一批手工做全了，第二批只做了当下必须做的那一步

---

## 13. 加固项把跳板机的容器网络打断了（`ip_forward=0`）

**现象**

把监控栈从手工 `docker run` 收归 compose 管理后，`/targets` 上 19 个 node 目标全部 `context deadline exceeded`，只有 Prometheus 自己和本机是 up。容器能解析 DNS、能连 `127.0.0.1`，就是到不了 `192.168.1.x`。

**排查**

```bash
# 1. 容器内直接测目标
docker run --rm --network container:prometheus python:3.12-alpine \
  sh -c "wget -T 3 -qO- http://192.168.1.226:9100/metrics | head -1"
# wget: download timed out

# 2. 宿主机出口抓包
tcpdump -ni eth0 'host 192.168.1.226 and port 9100'
# 0 packets captured  ← 关键信号：包根本没到网卡出口

# 3. 转发开关
sysctl net.ipv4.ip_forward
# net.ipv4.ip_forward = 0
```

**根因**

`playbooks/init.yml` 里有一条面向业务节点的加固项写死在静态文件里：

```yaml
net.ipv4.ip_forward = 0
```

而 `site.yml` 对 `all` 执行 `sysctl --system`，**跳板机也在 `all` 里**。于是每次跑单一入口，跳板机的转发就被关闭一次，docker 网桥上的容器全部出不去。

**修复**

```yaml
- name: 设置 IP 转发（跳板机开启，业务节点关闭）
  sysctl:
    name: net.ipv4.ip_forward
    value: "{{ '1' if inventory_hostname in groups['bastion'] else '0' }}"
    sysctl_file: /etc/sysctl.d/99-ops.conf
    sysctl_set: true
    reload: true
```

同时把静态文件里那行删掉——两份配置来源必然漂移。

**验证**

重跑 `init.yml --limit 127.0.0.1`，`sysctl -n net.ipv4.ip_forward` 仍为 `1`，targets 全部恢复 up。

**教训**

- **`ip_forward=0` 与「规则挡包」的现象完全不同**：规则挡包能在 `eth0` 上抓到 SYN，内核不转发则一个包都抓不到。抓包零包是第一时间的判断依据
- 加固项要**按角色**下发。同一条 sysctl 在业务节点是收紧，在跑容器的节点上就是自断网络
- 这类问题在「单一入口」落地后才会暴露——以前 `init.yml` 只对 5 台跑，跳板机上的 Docker 没受影响

---

## 14. `exporter` 账号存在，却报 `Host '127.0.0.1' is not allowed`

**现象**

`mysqld_exporter` 起来了，但 `mysql_up 0`，日志：

```
Error 1130: Host '127.0.0.1' is not allowed to connect to this MySQL server
```

同时 `SELECT user,host FROM mysql.user` 里明明有 `exporter@localhost`。

**根因**

`my.cnf` 里为了加快认证关掉了反向解析：

```ini
skip-name-resolve
```

关掉之后 MySQL **不再把 `127.0.0.1` 反解成 `localhost`**，而账号建的是 `'exporter'@'localhost'`。通过 TCP 连进来的主机名被判为 `127.0.0.1`，匹配不上 `localhost`，直接拒绝。

**修复**

```sql
CREATE USER 'exporter'@'127.0.0.1' IDENTIFIED BY '...' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'127.0.0.1';
```

**验证**

```bash
curl -s 127.0.0.1:9104/metrics | grep '^mysql_up'
# mysql_up 1
```

**附带收获**

从库没有手工建这个账号，但它自动出现了 —— 主库的 `CREATE USER` 是一条 DDL，随 binlog 复制到从库。这比 `SELECT 1` 更能证明复制链路是通的。

---

## 15. 手工 `docker run` 的容器与 compose 撞名，栈起不来

**现象**

```
Error response from daemon: Conflict. The container name "/prometheus" is already in use
```

**根因**

Prometheus 与 Grafana 最初是手工 `docker run` 起的，不属于任何 compose 项目。`docker compose up` 试图创建同名容器（并新建了自己的网络），于是命名冲突。

**处理**

```bash
docker rm -f prometheus grafana alertmanager
docker compose up -d
```

数据都在宿主机卷里（`/opt/prometheus`、`/opt/grafana`），删容器不丢数据。

**顺带暴露的第二个问题**

换成 compose 的自定义网络后，webhook 接收器用 `host.docker.internal` 指向 `172.17.0.1`（默认网桥），而实际网段变成了 `172.20.0.0/16`，端口连不通。最终把接收器也做成 compose 里的服务，用**服务名**互访，不再依赖任何 172.x 硬编码。

---

## 16. Docker Hub 与 GitHub Release 都下不动，二进制从镜像里取

**现象**

```bash
docker pull prom/alertmanager:v0.27.0
# Error ... dial tcp 31.13.87.34:443: connect: connection refused

curl -L -o mysqld.tar.gz https://github.com/prometheus/mysqld_exporter/releases/download/v0.15.1/...
# curl: (28) Operation timed out after 59424 ms with 236933 out of 8287769 bytes received
# 约 4 KB/s
```

**根因**

- Docker Hub 直连被拒；`daemon.json` 里配的阿里云专属加速器对该镜像无缓存，会回退到官方仓库后失败
- GitHub Release 走 `objects.githubusercontent.com`，本机到该地址被限速到 4 KB/s

**处理**

```bash
# 镜像：换可用的公共镜像源
docker pull docker.m.daocloud.io/prom/alertmanager:v0.27.0
docker tag  docker.m.daocloud.io/prom/alertmanager:v0.27.0 prom/alertmanager:v0.27.0

# 二进制：不从 Release 下，直接从官方镜像里 cp 出来
cid=$(docker create docker.m.daocloud.io/prom/mysqld-exporter:v0.15.1)
docker cp "$cid:/bin/mysqld_exporter" /opt/ops-pkg/mysqld_exporter
docker rm -f "$cid"
```

`docker cp` 出来的二进制与 Release 包里的完全一致（同一构建产物），版本号可自证：

```bash
/opt/ops-pkg/mysqld_exporter --version
# mysqld_exporter, version 0.15.1 (branch: HEAD, revision: cc34968...)
```

脚本固化在 `scripts/fetch-exporters.sh`，二进制不入库。

**教训**

「官方镜像仓库」和「官方二进制发布页」是两个独立的可达性来源。一个不通不代表另一个也不通，别急着换方案。

---

## 17. 一次错误的探测，把「本机防火墙没开」误判成「安全组拦截」

**现象**

要建 MySQL 主从，先探测 `238 → 237:3306` 是否通。探测脚本写成：

```bash
timeout 4 bash -c 'exec 3<>/dev/tcp/192.168.1.237/3306' && echo SG_OPEN || echo SG_BLOCKED
```

结果 `SG_BLOCKED`，据此判断「安全组缺少层内 `sg-app → sg-app` 规则」，准备让控制台加规则。

**后来发生了什么**

MySQL 与 Redis 装完、playbook 加上显式的 `zone=public` rich rule 之后，同一条探测变成 `REACHABLE`，Redis 复制自己就连上了（`master_link_status:up`）。

**根因分析**

探测本身不可靠，至少三点：

1. **超时太短**：4 秒 × 3 次，首次 SYN 若被丢弃，重传窗口还没等完就判死
2. **只在单端验证**：只测了「能不能连」，没确认监听端真的在 `LISTEN`（当时是用 `python3 -m http.server` 临时顶的）
3. **把一次失败当成结论**：没有用第二种方法交叉验证（例如在 237 上 `ss -lnt` + `tcpdump` 同时看）

**教训**

- 手工探测得到的「不通」，只能证明**这一次探测没通**，不能直接推出「网络层拦截」
- 网络问题必须**两端同时取证**：一端看 `ss -lnt` / `tcpdump`，一端看连接结果，中间再看 `iptables -t nat -L` 与安全组
- 结论写进文档前，用第二种方法复验一次。这次如果直接让用户在控制台加了 5 条规则，环境里就会多出几条**本来不需要**的放行规则，而且没人会再去删

---

# 附录：演练取证

四组演练的原始截图，存于仓库根目录 `evidence/`。文件名前缀与案例编号对应（A=案例 1，B=案例 2，C=案例 3，D=案例 4）。

| 文件 | 对应案例 | 截图内容 |
|---|---|---|
| `fault-A1-up-drop.png` | 1 | `up{instance="192.168.1.227:9100"}` 在 19:23 由 `1` 垂直跌到 `0` |
| `fault-A2-up-zero.png` | 1 | `up == 0` 全量查询：21 个目标里仅此一条为 0，其余不受影响 |
| `fault-A3-targets-down.png` | 1 | `/targets` 页标题 `node (19/20 up)`，Error 列 `connect: connection refused` |
| `fault-B1-alert-firing.png` | 2 | `/alerts` 页 `Inactive(5) Pending(0) Firing(1)`，只有 `DiskWillFull` 触发，其余 5 条规则无误报 |
| `fault-B2-disk-table.png` | 2 | Table 视图 20 行数值对比：227 为 `83.35`，其余 19 台 `26.94` |
| `fault-C3-alert-firing.png` | 3 | `HighLoad` FIRING，`Active Since 2026-11-05T12:29:39Z`、`Value 9.02`，其余 5 条 inactive |
| `fault-D3-sshfail-warn.png` | 4 | 巡检脚本 `SSH_FAIL count=123 WARN`、`RESULT agg-02 warn=1` |
| `fault-D2-ban-verified.png` | 4 | 封禁 `192.168.1.223` 后连接由 `Permission denied` 变为 `Connection timed out` |
| `fault-D0-loopback-ineffective.png` | 8 | **反例**：封 `127.0.0.1` 规则下发成功但照样能认证（loopback 不走 filter） |

**取证流程（顺序不可颠倒）**

```
制造故障 → 三视角观测（Prometheus 指标 / 巡检脚本 / 系统命令）
        → 观察告警状态 pending → firing
        → 截图
        → 恢复
        → 确认归零（targets up、告警数 0、指标回落）
```

最容易犯的错是**先恢复再截图**：曲线回到基线，只剩一条平线，等于没有证据。同理，负载类故障恢复后 `load1` 是指数衰减，要等 1–2 分钟才回落到阈值以下，这期间告警仍是 firing 属正常。

**为什么截图要保留「其他规则 inactive」的部分**

只截触发的那一条，无法排除「所有规则都在乱报」的可能。`Inactive(5) Firing(1)` 这个整体视图同时证明了两件事：告警触发了，并且**没有误报** —— 这是被追问「你怎么验证告警规则本身是对的」时最直接的答案。
