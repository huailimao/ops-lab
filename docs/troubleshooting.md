
案例：SSH 加固后的 root 拒绝验证

时间：2026-11-04
操作：设置 PermitRootLogin no 后尝试 root 登录
现象：Permission denied (publickey)，日志记录 User root not allowed
结论：加固生效，运维统一走 ops + sudo
