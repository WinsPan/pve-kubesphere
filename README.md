# PVE KubeSphere 一键部署脚本

🚀 在Proxmox VE (PVE) 上快速部署KubeSphere v4.1.3的自动化脚本集合。

## 📋 项目概述

本项目提供了一套完整的自动化脚本，用于在Proxmox VE虚拟化环境中快速部署KubeSphere容器平台。脚本采用模块化设计，支持一键部署和分步执行。

### 🎯 主要特性

- ✅ **一键部署**: 自动化完成所有部署步骤
- ✅ **模块化设计**: 支持分步执行和故障排除
- ✅ **资源优化**: 针对家庭/小型环境优化配置
- ✅ **完整文档**: 详细的使用说明和故障排除指南
- ✅ **远程部署**: 支持从GitHub远程下载执行

### 🏗️ 部署架构

```
PVE主机 (24核48GB+)
├── Master节点 (8核16GB 300GB)
│   ├── Kubernetes Control Plane
│   ├── KubeSphere Console
│   └── etcd数据库
├── Worker1节点 (8核16GB 300GB)
│   ├── Kubernetes Worker
│   └── 应用负载
└── Worker2节点 (8核16GB 300GB)
    ├── Kubernetes Worker
    └── 应用负载
```

## 🚀 快速开始

### 方法一：本地部署

1. **克隆仓库**
   ```bash
   git clone https://github.com/WinsPan/pve-kubesphere.git
   cd pve-kubesphere
   ```

2. **配置参数**
   ```bash
   # 编辑配置文件
   vim 01-pve-prepare.sh
   ```

3. **一键部署**
   ```bash
   ./deploy-all.sh
   ```

### 方法二：远程部署

#### 完整版远程部署
```bash
curl -fsSL https://raw.githubusercontent.com/WinsPan/pve-kubesphere/main/remote-deploy.sh | bash
```

#### 快速版远程部署
```bash
curl -fsSL https://raw.githubusercontent.com/WinsPan/pve-kubesphere/main/quick-deploy.sh | bash
```

## 📁 文件结构

```
pve-kubesphere/
├── 01-pve-prepare.sh          # PVE环境准备脚本
├── 02-k8s-install.sh          # Kubernetes安装脚本
├── 03-kubesphere-install.sh   # KubeSphere安装脚本
├── 04-cleanup.sh              # 清理脚本
├── deploy-all.sh              # 一键部署脚本
├── remote-deploy.sh           # 远程部署脚本
├── quick-deploy.sh            # 快速部署脚本
├── README.md                  # 项目说明
├── README-KubeSphere.md       # KubeSphere详细说明
├── QUICK-START.md             # 快速开始指南
├── CONFIG-SUMMARY.md          # 配置总结
├── CHECK-REPORT.md            # 检查报告
├── RESOURCE-REQUIREMENTS.md   # 资源要求
└── .gitignore                 # Git忽略文件
```

## ⚙️ 系统要求

### PVE主机要求
- **CPU**: 至少24核心
- **内存**: 至少48GB RAM
- **存储**: 至少1TB可用空间
- **网络**: 千兆网络连接
- **系统**: Proxmox VE 7.x 或 8.x

### 网络配置
- **管理网络**: 10.0.0.0/24
- **Master节点**: 10.0.0.10
- **Worker1节点**: 10.0.0.11
- **Worker2节点**: 10.0.0.12

## 🔧 配置说明

### 主要配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `PVE_HOST` | 192.168.1.100 | PVE主机IP地址 |
| `MASTER_IP` | 10.0.0.10 | Master节点IP |
| `WORKER_IPS` | 10.0.0.11,10.0.0.12 | Worker节点IP列表 |
| `KUBESPHERE_VERSION` | v4.1.3 | KubeSphere版本 |
| `K8S_VERSION` | v1.28.0 | Kubernetes版本 |

### 修改配置

1. **编辑主配置文件**
   ```bash
   vim 01-pve-prepare.sh
   ```

2. **修改网络配置**
   ```bash
   # 修改PVE主机IP
   PVE_HOST="192.168.1.100"
   
   # 修改节点IP
   MASTER_IP="10.0.0.10"
   WORKER_IPS="10.0.0.11,10.0.0.12"
   ```

3. **修改资源配置**
   ```bash
   # 修改虚拟机配置
   VM_CORES=8
   VM_MEMORY=16384
   VM_DISK_SIZE=300
   ```

## 📖 使用指南

### 分步部署

1. **准备PVE环境**
   ```bash
   ./01-pve-prepare.sh
   ```

2. **安装Kubernetes**
   ```bash
   ./02-k8s-install.sh
   ```

3. **安装KubeSphere**
   ```bash
   ./03-kubesphere-install.sh
   ```

### 一键部署

```bash
./deploy-all.sh
```

### 清理环境

```bash
./04-cleanup.sh
```

## 🌐 访问信息

部署完成后，可以通过以下方式访问：

### KubeSphere控制台
- **URL**: http://10.0.0.10:30880
- **用户名**: admin
- **密码**: P@88w0rd

### SSH访问
```bash
# 访问Master节点
ssh root@10.0.0.10

# 访问Worker节点
ssh root@10.0.0.11
ssh root@10.0.0.12
```

### Kubernetes管理
```bash
# 查看节点状态
kubectl get nodes

# 查看所有pods
kubectl get pods --all-namespaces

# 查看集群信息
kubectl cluster-info
```

## 🔍 故障排除

### 常见问题

1. **PVE连接失败**
   - 检查网络连接
   - 确认PVE主机IP地址
   - 验证SSH密钥配置

2. **虚拟机创建失败**
   - 检查PVE主机资源
   - 确认存储空间充足
   - 验证网络配置

3. **Kubernetes安装失败**
   - 检查网络连通性
   - 确认防火墙设置
   - 查看详细错误日志

4. **KubeSphere无法访问**
   - 等待服务完全启动
   - 检查端口是否开放
   - 验证DNS解析

### 日志文件

- **部署日志**: `deployment-*.log`
- **Kubernetes日志**: `/var/log/kubernetes/`
- **KubeSphere日志**: `/var/log/kubesphere/`

### 获取帮助

```bash
# 查看脚本帮助
./remote-deploy.sh --help

# 检查系统状态
./CHECK-REPORT.md

# 查看配置总结
cat CONFIG-SUMMARY.md
```

## 📚 相关文档

- [KubeSphere官方文档](https://kubesphere.io/docs/)
- [Kubernetes官方文档](https://kubernetes.io/docs/)
- [Proxmox VE文档](https://pve.proxmox.com/wiki/Main_Page)

## 🤝 贡献

欢迎提交Issue和Pull Request来改进这个项目！

### 贡献指南

1. Fork本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 打开Pull Request

## 📄 许可证

本项目采用MIT许可证 - 查看 [LICENSE](LICENSE) 文件了解详情。

## 🙏 致谢

- [KubeSphere](https://kubesphere.io/) - 优秀的容器平台
- [Kubernetes](https://kubernetes.io/) - 容器编排平台
- [Proxmox VE](https://www.proxmox.com/) - 虚拟化平台

---

**注意**: 请在使用前仔细阅读所有文档，并根据您的环境调整配置参数。 