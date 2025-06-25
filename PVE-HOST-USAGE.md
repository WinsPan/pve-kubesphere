# PVE宿主机使用说明

## 📋 概述

本说明文档介绍如何在Proxmox VE (PVE) 宿主机上直接执行KubeSphere部署脚本，无需SSH连接。

## 🎯 执行环境

### 脚本执行位置
- **执行位置**: PVE宿主机
- **执行用户**: root用户
- **执行方式**: 直接在PVE宿主机上运行

### 系统要求
- **操作系统**: Proxmox VE 7.x 或 8.x
- **CPU**: 至少24核心
- **内存**: 至少48GB RAM
- **存储**: 至少1TB可用空间
- **网络**: 千兆网络连接

## 🚀 执行步骤

### 1. 准备环境

```bash
# 登录PVE宿主机
ssh root@your-pve-host

# 下载脚本（如果从GitHub下载）
git clone https://github.com/WinsPan/pve-kubesphere.git
cd pve-kubesphere

# 或者直接下载脚本文件
wget https://raw.githubusercontent.com/WinsPan/pve-kubesphere/main/deploy-all.sh
wget https://raw.githubusercontent.com/WinsPan/pve-kubesphere/main/01-pve-prepare.sh
wget https://raw.githubusercontent.com/WinsPan/pve-kubesphere/main/02-k8s-install.sh
wget https://raw.githubusercontent.com/WinsPan/pve-kubesphere/main/03-kubesphere-install.sh

# 添加执行权限
chmod +x *.sh
```

### 2. 配置参数（可选）

```bash
# 编辑配置文件
vim 01-pve-prepare.sh

# 主要配置项：
PVE_HOST="10.0.0.1"          # PVE主机IP
VM_CORES=8                   # 虚拟机CPU核心数
VM_MEMORY=16384              # 虚拟机内存(MB)
VM_DISK_SIZE=300             # 虚拟机磁盘大小(GB)
STORAGE_NAME="local-lvm"     # PVE存储名称
```

### 3. 执行部署

```bash
# 一键部署（推荐）
./deploy-all.sh

# 或者分步执行
./01-pve-prepare.sh    # 创建虚拟机
./02-k8s-install.sh    # 安装Kubernetes
./03-kubesphere-install.sh  # 安装KubeSphere
```

## 📁 脚本说明

### 脚本执行流程

| 脚本 | 执行位置 | 功能描述 |
|------|----------|----------|
| `01-pve-prepare.sh` | PVE宿主机 | 创建3个Debian虚拟机 |
| `02-k8s-install.sh` | PVE宿主机 | 通过SSH在虚拟机中安装Kubernetes |
| `03-kubesphere-install.sh` | PVE宿主机 | 通过SSH在虚拟机中安装KubeSphere |

### 虚拟机配置

脚本将创建以下虚拟机：

| 虚拟机 | IP地址 | 配置 | 用途 |
|--------|--------|------|------|
| k8s-master | 10.0.0.10 | 8核16GB 300GB | Kubernetes主节点 |
| k8s-worker1 | 10.0.0.11 | 8核16GB 300GB | Kubernetes工作节点1 |
| k8s-worker2 | 10.0.0.12 | 8核16GB 300GB | Kubernetes工作节点2 |

## 🔧 网络配置

### 网络要求

- **管理网络**: 10.0.0.0/24
- **PVE主机**: 10.0.0.1
- **虚拟机网络**: 通过vmbr0桥接

### 网络检查

```bash
# 检查网络桥接
ip link show vmbr0

# 检查网络配置
cat /etc/network/interfaces

# 测试网络连通性
ping -c 3 10.0.0.1
```

## 💾 存储配置

### 存储要求

- **存储类型**: LVM或本地存储
- **存储名称**: local-lvm（默认）
- **可用空间**: 至少900GB

### 存储检查

```bash
# 检查存储状态
pvesm status

# 检查可用空间
df -h

# 检查LVM存储
lvs
```

## 🔍 故障排除

### 常见问题

#### 1. 脚本权限问题
```bash
# 解决方案：添加执行权限
chmod +x *.sh
```

#### 2. PVE环境检查失败
```bash
# 检查PVE版本
pveversion -v

# 检查存储
pvesm status

# 检查网络
ip link show
```

#### 3. 虚拟机创建失败
```bash
# 检查存储空间
df -h

# 检查网络桥接
ip link show vmbr0

# 检查虚拟机状态
qm list
```

#### 4. SSH连接失败
```bash
# 检查SSH服务
systemctl status ssh

# 检查SSH密钥
ls -la ~/.ssh/

# 测试SSH连接
ssh root@10.0.0.10
```

### 日志文件

- **部署日志**: `deployment-*.log`
- **虚拟机日志**: `/var/log/pve/`
- **系统日志**: `/var/log/syslog`

## 📊 监控和验证

### 部署验证

```bash
# 检查虚拟机状态
qm list

# 检查节点连接
ping -c 3 10.0.0.10
ping -c 3 10.0.0.11
ping -c 3 10.0.0.12

# 检查Kubernetes集群
ssh root@10.0.0.10 "kubectl get nodes"

# 检查KubeSphere
ssh root@10.0.0.10 "kubectl get pods -n kubesphere-system"
```

### 访问信息

部署完成后，可以通过以下方式访问：

- **KubeSphere控制台**: http://10.0.0.10:30880
- **SSH访问**: ssh root@10.0.0.10
- **默认密码**: kubesphere123

## 🛠️ 维护命令

### 虚拟机管理

```bash
# 查看虚拟机状态
qm list

# 启动虚拟机
qm start 100  # k8s-master
qm start 101  # k8s-worker1
qm start 102  # k8s-worker2

# 停止虚拟机
qm stop 100
qm stop 101
qm stop 102

# 重启虚拟机
qm reset 100
qm reset 101
qm reset 102
```

### 清理环境

```bash
# 运行清理脚本
./04-cleanup.sh

# 或手动清理
qm destroy 100  # 删除k8s-master
qm destroy 101  # 删除k8s-worker1
qm destroy 102  # 删除k8s-worker2
```

## ⚠️ 注意事项

1. **执行环境**: 确保在PVE宿主机上执行，不是在虚拟机中
2. **用户权限**: 使用root用户执行脚本
3. **网络配置**: 确保网络桥接vmbr0存在且配置正确
4. **存储空间**: 确保有足够的存储空间创建虚拟机
5. **SSH密钥**: 建议配置SSH密钥以提高安全性

## 📚 相关文档

- [Proxmox VE官方文档](https://pve.proxmox.com/wiki/Main_Page)
- [Kubernetes安装指南](https://kubernetes.io/docs/setup/)
- [KubeSphere官方文档](https://kubesphere.io/docs/)

---

**提示**: 执行脚本前请仔细检查所有配置参数，确保符合您的环境要求。 