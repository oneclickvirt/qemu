# qemu

[![Hits](https://hits.spiritlhl.net/qemu.svg)](https://hits.spiritlhl.net/qemu)

基于 QEMU/KVM + libvirt 的虚拟机环境一键安装与管理脚本

支持一键安装 QEMU/KVM 运行时，并开设各种 Linux 虚拟机（提供 SSH 访问），支持端口映射、资源限制、cloud-init 自动初始化等。

## 更新

[更新日志](CHANGELOG.md)

## 说明文档

国内(China Docs)：

[https://virt.spiritlhl.net/guide/qemu/qemu_precheck.html](https://virt.spiritlhl.net/guide/qemu/qemu_precheck.html)

国际(English Docs)：

[https://www.spiritlhl.net/en/guide/qemu/qemu_precheck.html](https://www.spiritlhl.net/en/guide/qemu/qemu_precheck.html)

说明文档中 QEMU/KVM 分区内容

## 说明

- 使用 [QEMU/KVM](https://www.qemu.org/) + [libvirt](https://libvirt.org/) 安装完整虚拟化环境
- 使用 qcow2 云镜像，依次尝试组织镜像仓库和发行版上游，自动下载并使用 cloud-init 初始化
- 支持系统：Debian 10/11/12/13、Ubuntu 18/20/22/24、AlmaLinux 8/9、RockyLinux 8/9、OpenEuler 22
- 支持架构：amd64、arm64
- 网络模式：libvirt NAT（virbr0），通过 nftables 或 iptables 进行端口映射；新安装网络支持 ULA IPv6 NAT
- 虚拟机信息记录在 `/root/vmlog`

## 资源要求

| 项目 | 最低要求 |
|------|---------|
| CPU | 推荐支持 VT-x/AMD-V 硬件虚拟化（或嵌套虚拟化）；缺少 KVM 时使用较慢的 QEMU 模拟 |
| 内存 | 宿主机剩余 >= 虚拟机内存 + 512MB |
| 磁盘 | 宿主机剩余 >= 虚拟机磁盘 × 台数，另预留镜像缓存空间 |
| OS | 建议使用维护中的 Debian、Ubuntu 系统 |

## Stargazers over time

[![Stargazers over time](https://starchart.cc/oneclickvirt/qemu.svg)](https://starchart.cc/oneclickvirt/qemu)
