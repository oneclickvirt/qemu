# CHANGELOG

## Unreleased

- 统一支持 `noninteractive=true` 作为安装、创建、删除、卸载脚本的无交互开关。
- 优化 iptables 端口范围映射，避免按端口逐条添加规则。
- 增强虚拟机创建参数校验和失败清理，避免部署失败后残留 DHCP 预留、端口转发规则或临时磁盘。
- 新建 libvirt 默认网络时使用 NAT 模式，并让默认存储池尊重自定义镜像路径。
- 修复批量创建脚本在切换到 `/root` 后无法稳定优先使用同目录 `oneqemu.sh` 的问题。

## 2026.03.02

- 初始化仓库，基于 oneclickvirt/containerd 实现 QEMU/KVM 版本
- 实现 qemuinstall.sh：一键安装 QEMU/KVM + libvirt + virt-install + cloud-init 全套组件
- 实现 scripts/oneqemu.sh：单个虚拟机开设脚本，支持 debian/ubuntu/almalinux/rockylinux/openeuler
- 实现 scripts/create_qemu.sh：交互式批量虚拟机开设脚本，记录至 vmlog 日志
- 实现 scripts/delete_qemu.sh：删除单个虚拟机并清理端口转发规则、DHCP 预留、磁盘
- 实现 qemuuninstall.sh：完整卸载 QEMU/KVM 环境及所有虚拟机
- 支持 CDN 加速下载（与 oneclickvirt 系列项目共用 CDN）
- 支持 libvirt hooks + iptables DNAT 实现持久化端口映射
- 支持 cloud-init 自动初始化（设置 root 密码、启用 SSH 密码登录）
- 支持 amd64、arm64 双架构
