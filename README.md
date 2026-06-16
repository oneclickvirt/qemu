# qemu

[![Hits](https://hits.spiritlhl.net/qemu.svg)](https://hits.spiritlhl.net/qemu)

基于 QEMU/KVM + libvirt 的虚拟机环境一键安装与管理脚本

支持一键安装 QEMU/KVM 运行时，并开设各种 Linux 虚拟机（提供 SSH 访问），支持端口映射、资源限制、cloud-init 自动初始化等。

## 说明

- 使用 [QEMU/KVM](https://www.qemu.org/) + [libvirt](https://libvirt.org/) 安装完整虚拟化环境
- 使用官方 Cloud Image（qcow2 格式），自动下载并使用 cloud-init 初始化
- 支持系统：Debian 10/11/12/13、Ubuntu 18/20/22/24、AlmaLinux 8/9、RockyLinux 8/9、OpenEuler 22
- 支持架构：amd64、arm64
- 网络模式：libvirt NAT（virbr0），通过 nftables 或 iptables 进行端口映射；新安装网络支持 ULA IPv6 NAT
- 虚拟机信息记录在 `/root/vmlog`

## 无交互约定

所有脚本统一支持以下方式进入无交互模式：

```bash
export noninteractive=true
```

开启后，脚本不会等待人工输入：安装和批量创建会使用默认值或已传入的参数；删除和卸载会把该变量视为明确确认。各脚本原有的专用环境变量（如 `VM_COUNT`、`QEMU_FORCE_DELETE`、`QEMU_FORCE_UNINSTALL`）仍然兼容。

## 安装 QEMU/KVM 环境

```bash
bash <(curl -sSL https://raw.githubusercontent.com/oneclickvirt/qemu/main/qemuinstall.sh)
```

**支持环境变量（无交互）：**

```bash
export noninteractive=true
# 自定义镜像存储路径（默认 /var/lib/libvirt/images）
export QEMU_IMAGES_PATH=/data/vm-images
bash <(curl -sSL https://raw.githubusercontent.com/oneclickvirt/qemu/main/qemuinstall.sh)
```

## 开设单个虚拟机

```bash
# 下载脚本
curl -sSL -o oneqemu.sh https://raw.githubusercontent.com/oneclickvirt/qemu/main/scripts/oneqemu.sh
chmod +x oneqemu.sh

# 用法 (两种格式均支持):
# ./oneqemu.sh <name> <cpu> <memory_mb> <disk_gb> <password> <sshport> <startport> <endport> [system]
# ./oneqemu.sh <name> <cpu> <memory_mb> <disk_gb> <password> <sshport> <startport> <endport> <extra_flag(y/n)> [system]

# 示例: 创建名为 vm1 的 Debian 虚拟机，1核 1024MB 20GB，SSH端口25001，额外端口35001-35025
./oneqemu.sh vm1 1 1024 20 MyPassword 25001 35001 35025 debian
# 示例: 第 9 个参数为附加标志（y/n），第 10 个参数为系统名
./oneqemu.sh vm1 1 1024 10 MyPassword 25000 34975 35000 n debian13
```

| 参数 | 说明 | 默认值 |
|------|------|--------|
| name | 虚拟机名称 | vm1 |
| cpu | CPU 核数 | 1 |
| memory_mb | 内存限制（MB） | 1024 |
| disk_gb | 磁盘大小（GB） | 20 |
| password | root 密码 | 自动生成 |
| sshport | 宿主机 SSH 映射端口 | 25001 |
| startport | 额外端口范围起始 | 35001 |
| endport | 额外端口范围结束 | 35025 |
| system | 系统类型（第 9 或第 10 个参数） | debian |

**支持的 system 值：**

| 系统名 | 支持版本号 | 示例 |
|--------|-----------|------|
| `debian` | 10 11 12 13 | `debian` `debian12` `debian13` |
| `ubuntu` | 18 20 22 24 | `ubuntu` `ubuntu22` `ubuntu24` |
| `almalinux` | 8 9 | `almalinux9`（`alma9` 亦可） |
| `rockylinux` | 8 9 | `rockylinux9`（`rocky9` 亦可） |
| `openeuler` | 22 | `openeuler` |

> system 名称不区分大小写，支持带 `-` 或 `_` 分隔符（如 `debian-13`、`ubuntu_22`），均可自动规范化。

**单机创建也支持环境变量（位置参数优先）：**

```bash
export noninteractive=true
export VM_NAME=vm1
export VM_CPU=1
export VM_MEMORY=1024
export VM_DISK=20
export VM_PASSWORD='ChangeMe-123'
export VM_SSH_PORT=25001
export VM_START_PORT=35001
export VM_END_PORT=35025
export VM_SYSTEM=debian12
./oneqemu.sh
```

## 批量开设虚拟机

```bash
curl -sSL -o create_qemu.sh https://raw.githubusercontent.com/oneclickvirt/qemu/main/scripts/create_qemu.sh
chmod +x create_qemu.sh
./create_qemu.sh
```

交互式脚本，自动递增虚拟机名（vm1, vm2, ...）、SSH 端口、公网端口，虚拟机信息记录到 `vmlog` 文件。
批量创建会使用批处理锁串行执行；若单台创建失败，脚本会停止后续创建，避免名称和端口继续漂移。

**支持命令行参数（非交互）：**

```bash
# ./create_qemu.sh <数量> <内存MB> <CPU> <磁盘GB> <系统类型>
./create_qemu.sh 3 1024 1 20 debian12
```

**支持环境变量（无交互一键批量创建）：**

```bash
export noninteractive=true
export VM_COUNT=3          # 虚拟机数量
export VM_MEMORY=1024      # 每台内存 MB
export VM_CPU=1            # 每台 CPU 核数
export VM_DISK=20          # 每台磁盘 GB
export VM_SYSTEM=debian12  # 操作系统类型
./create_qemu.sh
```

> **说明：** 脚本不会阻塞等待 cloud-init 完成。DHCP 预留和端口转发规则在 VM 启动前已配置完毕，cloud-init 在后台运行；VM 保持运行，SSH 就绪后即可连接。可通过以下命令查看初始化进度：
> ```bash
> tail -f /tmp/qemu-init-<vm_name>.log
> ```

## 查看与管理虚拟机

```bash
virsh list --all                    # 查看所有虚拟机
virsh console <name>                # 进入虚拟机控制台（Ctrl+] 退出）
virsh start <name>                  # 启动虚拟机
virsh shutdown <name>               # 优雅关闭虚拟机
virsh destroy <name>                # 强制关闭虚拟机
virsh reboot <name>                 # 重启虚拟机
virsh dominfo <name>                # 查看虚拟机信息
virsh domifaddr <name>              # 查看虚拟机 IP 地址
```

也可以使用项目脚本进行无交互管理：

```bash
curl -sSL -o manage_qemu.sh https://raw.githubusercontent.com/oneclickvirt/qemu/main/scripts/manage_qemu.sh
chmod +x manage_qemu.sh

# 查询全部或单台虚拟机（包含 vmlog、状态、MAC、IP、端口等信息）
./manage_qemu.sh info all
./manage_qemu.sh info vm1

# 创建快照
./manage_qemu.sh snapshot vm1 before-upgrade

# 调整 CPU 和内存（内存单位 MB）
./manage_qemu.sh set-resources vm1 2 2048
```

## 删除单个虚拟机

```bash
curl -sSL -o delete_qemu.sh https://raw.githubusercontent.com/oneclickvirt/qemu/main/scripts/delete_qemu.sh
chmod +x delete_qemu.sh
./delete_qemu.sh <vm_name>
# 跳过确认直接删除
./delete_qemu.sh vm1 -y
```

**支持环境变量（无交互）：**

```bash
export VM_NAME=vm1
export noninteractive=true
export QEMU_FORCE_DELETE=yes
./delete_qemu.sh
```

脚本会自动清理：虚拟机定义、磁盘镜像、DHCP 预留、nftables/iptables 端口转发规则、日志记录。
删除成功后会同步清理 `/root/vmlog` 和本地 SQLite 状态库中的 VM 记录。

## 卸载（完整清理）

一键卸载 QEMU/KVM 全套环境，包括所有虚拟机、磁盘镜像、网络配置、systemd 服务、软件包：

```bash
bash <(curl -sSL https://raw.githubusercontent.com/oneclickvirt/qemu/main/qemuuninstall.sh)
```

脚本会在执行前要求输入 `yes` 确认，操作不可逆。

**支持环境变量或参数跳过确认（无交互）：**

```bash
# 方式一：环境变量
export noninteractive=true
export QEMU_FORCE_UNINSTALL=yes
bash <(curl -sSL https://raw.githubusercontent.com/oneclickvirt/qemu/main/qemuuninstall.sh)

# 方式二：命令行参数
bash qemuuninstall.sh -y
```

## 环境变量汇总

| 脚本 | 环境变量 | 说明 | 示例值 |
|------|----------|------|--------|
| 全部 | `noninteractive` | 统一无交互开关 | `true` |
| `qemuinstall.sh` | `QEMU_IMAGES_PATH` | 镜像存储路径 | `/data/images` |
| `qemuuninstall.sh` | `QEMU_FORCE_UNINSTALL` | 跳过卸载确认 | `yes` |
| `oneqemu.sh` | `VM_NAME` | 虚拟机名称 | `vm1` |
| `oneqemu.sh` | `VM_CPU` | CPU 核数 | `1` |
| `oneqemu.sh` | `VM_MEMORY` | 内存（MB） | `1024` |
| `oneqemu.sh` | `VM_DISK` | 磁盘（GB） | `20` |
| `oneqemu.sh` | `VM_PASSWORD` | root 密码（为空则自动生成） | `ChangeMe-123` |
| `oneqemu.sh` | `VM_SSH_PORT` | SSH 映射端口 | `25001` |
| `oneqemu.sh` | `VM_START_PORT` | 额外端口起始 | `35001` |
| `oneqemu.sh` | `VM_END_PORT` | 额外端口结束 | `35025` |
| `oneqemu.sh` | `VM_SYSTEM` | 操作系统类型 | `debian12` |
| `create_qemu.sh` | `VM_COUNT` | 创建虚拟机数量 | `3` |
| `create_qemu.sh` | `VM_MEMORY` | 每台内存（MB） | `1024` |
| `create_qemu.sh` | `VM_CPU` | 每台 CPU 核数 | `1` |
| `create_qemu.sh` | `VM_DISK` | 每台磁盘（GB） | `20` |
| `create_qemu.sh` | `VM_SYSTEM` | 操作系统类型 | `debian12` |
| `delete_qemu.sh` | `VM_NAME` | 要删除的虚拟机名 | `vm1` |
| `delete_qemu.sh` | `QEMU_FORCE_DELETE` | 跳过删除确认 | `yes` |

## 镜像说明

本项目使用各发行版官方 Cloud Image（cloud-init 格式），首次使用时自动下载至 `/var/lib/libvirt/images/`，后续创建同系统虚拟机不再重复下载。下载成功后会生成本地 `.sha256` 校验记录；再次使用缓存时会先复核 SHA256，校验失败则删除旧缓存并重新下载。

| 系统 | 镜像来源 |
|------|---------|
| Debian 10/11/12/13 | cloud.debian.org |
| Ubuntu 18/20/22/24 | cloud-images.ubuntu.com |
| AlmaLinux 8/9 | repo.almalinux.org |
| RockyLinux 8/9 | dl.rockylinux.org |
| OpenEuler 22 | repo.openeuler.org |

## 网络说明

- 使用 libvirt 的 `default` NAT 网络（`virbr0`，`192.168.122.0/24`）
- 安装时会检测已有 `virbr0` 是否由 libvirt 管理，避免和宿主机已有网桥冲突
- 虚拟机获得 `192.168.122.2`~`192.168.122.99` 范围内的静态 IP（通过 DHCP 预留）
- 通过 nftables 或 iptables DNAT 实现宿主机端口到虚拟机端口的映射
- 新安装的 default 网络包含 `fd42:122::/64` ULA IPv6 段；宿主机存在 IPv6 默认路由时会启用 NAT66，并记录 `ipv6_nat=true`
- 创建中会临时预留 VM 名称、SSH 端口和额外端口范围，避免并发创建时复用同一资源
- SSH 端口映射：`宿主机:sshport` → `vm_ip:22`
- 额外端口映射：`宿主机:startport-endport` → `vm_ip:startport-endport`

## 日志文件

虚拟机信息保存在 `/root/vmlog`，并同步写入 `/var/lib/libvirt/qemu-vms.db` 作为结构化本地状态库。`/root/vmlog` 保持向后兼容，格式如下：

```
vm1 25001 passwd123 1 1024 20 35001 35025 debian 192.168.122.2
vm2 25002 passwd456 1 1024 20 35026 35050 ubuntu 192.168.122.3
```

字段顺序：`名称 SSH端口 密码 CPU核数 内存MB 磁盘GB 起始端口 结束端口 系统 内网IP`

新版本会在上述 10 个兼容字段后追加网络元数据，例如：

```
mac=52:54:xx:xx:xx:xx bridge=virbr0 fw=nft ipv6=fd42:122::2 ipv6_nat=true
```

创建、删除和 `manage_qemu.sh set-resources` 会同步维护 vmlog 与 SQLite 记录；若 vmlog 缺失，`manage_qemu.sh info all` 会回退读取 SQLite。

## 资源要求

| 项目 | 最低要求 |
|------|---------|
| CPU | 支持 VT-x/AMD-V 硬件虚拟化（或嵌套虚拟化） |
| 内存 | 宿主机剩余 >= 虚拟机内存 + 512MB |
| 磁盘 | 宿主机剩余 >= 虚拟机磁盘 × 台数 |
| OS | Ubuntu 22.04+、Debian 11+、CentOS 7+ |

## Stargazers over time

[![Stargazers over time](https://starchart.cc/oneclickvirt/qemu.svg)](https://starchart.cc/oneclickvirt/qemu)
