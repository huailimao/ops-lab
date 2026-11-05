# 故障排查记录

本文件记录 ops-lab 环境在**建设期**与**演练期**遇到的真实故障。每条按「现象 → 排查 → 根因 → 修复 → 验证」组织，重点写**踩过的坑**而不是成功经验。

## 环境基线

| 项 | 配置 |
|---|---|
| 节点 | 阿里云 ECS 20 台：1 bastion + 2 web + 17 app（`192.168.1.222-241`） |
| 系统 | Alibaba Cloud Linux 3（Python 3.6.8） |
| 编排 | Ansible，`ops` 用户 + 密钥登录 + sudo 免密 |
| 监控 | Prometheus v2.51.0 + Grafana 10.4.2（docker compose） |
| 巡检 | `/opt/ops-lab/check.sh`，8 类指标，末行 `RESULT <host> warn=N` |
| 告警规则 | 6 条：`NodeDown` / `DiskWillFull` / `InodeWillFull` / `HighLoad` / `HighMemory` / `DiskIOSaturated` |

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
