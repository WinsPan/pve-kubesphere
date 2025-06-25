# PVE KubeSphere 配置总结

## 📋 当前配置

### 网络配置
- **PVE主机IP**: 10.0.0.1
- **Master节点IP**: 10.0.0.10
- **Worker节点1IP**: 10.0.0.11
- **Worker节点2IP**: 10.0.0.12
- **网络CIDR**: 10.0.0.0/24
- **网关**: 10.0.0.1

### 版本配置
- **Kubernetes版本**: v1.28.0
- **KubeSphere版本**: v4.1.3
- **Calico版本**: v3.26.0
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
# 找到 K8S_VERSION="1.28.0" 并修改
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