# PVE KubeSphere 配置总结

## 📋 配置概览

本文档总结了PVE KubeSphere部署脚本中的所有配置参数，方便快速查看和修改。

## 🔧 核心配置参数

### 网络配置

| 参数 | 默认值 | 说明 | 修改位置 |
|------|--------|------|----------|
| `PVE_HOST` | 10.0.0.1 | PVE主机IP地址 | 01-pve-prepare.sh |
| `MASTER_IP` | 10.0.0.10 | Master节点IP | 01-pve-prepare.sh |
| `WORKER_IPS` | 10.0.0.11,10.0.0.12 | Worker节点IP列表 | 01-pve-prepare.sh |
| `POD_CIDR` | 10.244.0.0/16 | Pod网络CIDR | 02-k8s-install.sh |
| `SERVICE_CIDR` | 10.96.0.0/12 | Service网络CIDR | 02-k8s-install.sh |

### 版本配置

| 参数 | 默认值 | 说明 | 修改位置 |
|------|--------|------|----------|
| `KUBESPHERE_VERSION` | v4.1.3 | KubeSphere版本 | 03-kubesphere-install.sh |
| `K8S_VERSION` | 1.29.7 | Kubernetes版本 | 02-k8s-install.sh |
| `CONTAINERD_VERSION` | 1.7.11 | containerd版本 | 02-k8s-install.sh |
| `CALICO_VERSION` | 3.27.0 | Calico网络插件版本 | 02-k8s-install.sh |

### 虚拟机配置

| 参数 | 默认值 | 说明 | 修改位置 |
|------|--------|------|----------|
| `VM_CORES` | 8 | 虚拟机CPU核心数 | 01-pve-prepare.sh |
| `VM_MEMORY` | 16384 | 虚拟机内存(MB) | 01-pve-prepare.sh |
| `VM_DISK_SIZE` | 300 | 虚拟机磁盘大小(GB) | 01-pve-prepare.sh |
| `VM_STORAGE` | local-lvm | PVE存储名称 | 01-pve-prepare.sh |

### 认证配置

| 参数 | 默认值 | 说明 | 修改位置 |
|------|--------|------|----------|
| `PVE_USER` | root | PVE用户名 | 01-pve-prepare.sh |
| `KUBESPHERE_USER` | admin | KubeSphere管理员用户名 | 03-kubesphere-install.sh |
| `KUBESPHERE_PASSWORD` | P@88w0rd | KubeSphere管理员密码 | 03-kubesphere-install.sh |

## 📝 修改配置步骤

### 1. 修改网络配置

编辑 `01-pve-prepare.sh` 文件：

```bash
# 找到以下行并修改
PVE_HOST="10.0.0.1"  # 修改为您的PVE主机IP
MASTER_IP="10.0.0.10"  # 修改为Master节点IP
WORKER_IPS="10.0.0.11,10.0.0.12"  # 修改为Worker节点IP列表
```

### 2. 修改版本配置

编辑 `02-k8s-install.sh` 文件：

```bash
# 找到以下行并修改
K8S_VERSION="1.29.7"  # 修改Kubernetes版本
CONTAINERD_VERSION="1.7.11"  # 修改containerd版本
CALICO_VERSION="3.27.0"  # 修改Calico版本
```

编辑 `03-kubesphere-install.sh` 文件：

```bash
# 找到以下行并修改
KUBESPHERE_VERSION="v4.1.3"  # 修改KubeSphere版本
```

### 3. 修改虚拟机配置

编辑 `01-pve-prepare.sh` 文件：

```bash
# 找到以下行并修改
VM_CORES=8  # 修改CPU核心数
VM_MEMORY=16384  # 修改内存大小(MB)
VM_DISK_SIZE=300  # 修改磁盘大小(GB)
```

### 4. 修改认证配置

编辑 `03-kubesphere-install.sh` 文件：

```bash
# 找到以下行并修改
KUBESPHERE_USER="admin"  # 修改管理员用户名
KUBESPHERE_PASSWORD="P@88w0rd"  # 修改管理员密码
```

## 🔍 配置验证

### 检查当前配置

```bash
# 查看所有配置参数
grep -E "PVE_HOST|MASTER_IP|WORKER_IPS|KUBESPHERE_VERSION|K8S_VERSION" *.sh
```

### 验证网络连通性

```bash
# 测试PVE主机连接
ping -c 3 10.0.0.1

# 测试节点IP连通性
ping -c 3 10.0.0.10
ping -c 3 10.0.0.11
ping -c 3 10.0.0.12
```

## ⚠️ 注意事项

1. **网络配置**: 确保所有IP地址在您的网络环境中可用
2. **版本兼容性**: 确保Kubernetes和KubeSphere版本兼容
3. **资源要求**: 根据实际硬件调整虚拟机配置
4. **安全配置**: 建议修改默认密码和用户名

## 📚 相关文档

- [Kubernetes版本兼容性](https://kubernetes.io/docs/setup/release/version-skew-policy/)
- [KubeSphere版本说明](https://kubesphere.io/docs/release/release-v430/)
- [Calico版本兼容性](https://projectcalico.docs.tigera.io/getting-started/kubernetes/requirements)

---

**提示**: 修改配置后，建议重新运行部署脚本以确保所有更改生效。

## 📋 当前配置

### 网络配置
- **PVE主机IP**: 10.0.0.1
- **Master节点IP**: 10.0.0.10
- **Worker节点1IP**: 10.0.0.11
- **Worker节点2IP**: 10.0.0.12
- **网络CIDR**: 10.0.0.0/24
- **网关**: 10.0.0.1

### 版本配置
- **Kubernetes版本**: v1.29.7
- **KubeSphere版本**: v4.1.3
- **Calico版本**: v3.27.0
- **Helm版本**: v3.12.0

### 虚拟机配置
- **Master节点**: 8核CPU, 16GB内存, 300GB磁盘
- **Worker节点**: 8核CPU, 16GB内存, 300GB磁盘
- **操作系统**: Debian 12
- **容器运行时**: containerd

### 访问信息
- **KubeSphere控制台**: http://10.0.0.10:30880
- **默认用户名**: admin
- **默认密码**: P@88w0rd
- **节点SSH密码**: kubesphere123

## 🔧 修改配置

如果您需要修改任何配置，请编辑以下文件：

### 网络配置
```bash
# 编辑PVE环境准备脚本
vim 01-pve-prepare.sh

# 编辑Kubernetes安装脚本
vim 02-k8s-install.sh

# 编辑KubeSphere安装脚本
vim 03-kubesphere-install.sh

# 编辑一键部署脚本
vim deploy-all.sh

# 编辑清理脚本
vim 04-cleanup.sh
```

### 版本配置
```bash
# 修改KubeSphere版本
vim 03-kubesphere-install.sh
# 找到 KUBESPHERE_VERSION="v4.1.3" 并修改

# 修改Kubernetes版本
vim 02-k8s-install.sh
# 找到 K8S_VERSION="1.29.7" 并修改
```

## 📝 配置验证

部署前请确认：
- [ ] PVE主机IP (10.0.0.1) 可以访问
- [ ] 网络配置与您的环境匹配
- [ ] 有足够的存储空间和内存
- [ ] 防火墙允许必要端口

## 🚀 开始部署

确认配置无误后，运行：
```bash
./deploy-all.sh
```

## 📚 相关文档

- 详细部署指南: README-KubeSphere.md
- 快速开始: QUICK-START.md
- 故障排除: 查看各脚本的日志输出

---

**注意**: 部署前请务必确认所有IP地址配置正确！ 