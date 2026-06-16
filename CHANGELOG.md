# CHANGELOG

## Unreleased

- 统一支持 `noninteractive=true` 作为安装、创建、删除、卸载脚本的无交互开关。
- 优化 iptables 端口范围映射，避免按端口逐条添加规则。
- 增强虚拟机创建参数校验和失败清理，避免部署失败后残留 DHCP 预留、端口转发规则或临时磁盘。
- 新建 libvirt 默认网络时使用 NAT 模式，并让默认存储池尊重自定义镜像路径。
- 修复批量创建脚本在切换到 `/root` 后无法稳定优先使用同目录 `oneqemu.sh` 的问题。
- 单机创建未传密码时自动生成密码，避免继续使用弱默认密码。
- 新增 `.gitignore` 和 GitHub Actions 静态检查 workflow。
- 新增 `scripts/manage_qemu.sh`，支持虚拟机信息查询、快照创建和 CPU/内存调整。
- 创建和删除流程增加状态锁，降低并发创建/删除时 `/root/vmlog` 与 DHCP 预留竞争风险。
- 创建流程增加临时资源预留，覆盖 VM 创建中尚未写入 `/root/vmlog` 的名称和端口冲突窗口。
- VM 状态锁与批量创建锁增加 PID 标记和 stale lock 清理，避免异常退出后后续任务长时间等待。
- 批量创建增加批处理锁，单台创建失败时立即停止后续创建。
- 批量创建可从 SQLite VM 状态库恢复已有编号和端口，避免 `/root/vmlog` 缺失时从默认端口误重新分配。
- Cloud Image 缓存增加本地 SHA256 记录与复核，校验失败时自动丢弃旧缓存并重新下载。
- 新安装的 default 网络增加 ULA IPv6 段，并在宿主具备 IPv6 默认路由时配置 nftables/ip6tables NAT66。
- `/root/vmlog` 追加兼容性的网络元数据，管理脚本可展示 MAC、bridge、防火墙后端、IPv6 与 NAT66 状态。
- SQLite VM 状态库扩展网络元数据，并在创建、删除、资源调整与信息查询时和 `/root/vmlog` 保持一致。
- 安装 default 网络前检测非 libvirt 管理的 `virbr0`，避免网桥冲突。
- `oneqemu.sh` 支持 `VM_*` 环境变量作为无交互默认参数。

## 2026.03.02

- 初始化仓库，基于 oneclickvirt/containerd 实现 QEMU/KVM 版本
- 实现 qemuinstall.sh：一键安装 QEMU/KVM + libvirt + virt-install + cloud-init 全套组件
- 实现 scripts/oneqemu.sh：单个虚拟机开设脚本，支持 debian/ubuntu/almalinux/rockylinux/openeuler
- 实现 scripts/create_qemu.sh：交互式批量虚拟机开设脚本，记录至 vmlog 日志
- 实现 scripts/delete_qemu.sh：删除单个虚拟机并清理端口转发规则、DHCP 预留、磁盘
- 实现 qemuuninstall.sh：完整卸载 QEMU/KVM 环境及所有虚拟机
- 支持 CDN 加速下载（与 oneclickvirt 系列项目共用 CDN）
- 支持 nftables/iptables DNAT 实现持久化端口映射
- 支持 cloud-init 自动初始化（设置 root 密码、启用 SSH 密码登录）
- 支持 amd64、arm64 双架构
