# PVE KubeSphere 一键部署脚本使用指南

## 🚀 快速开始

### 方法1：直接下载并执行（推荐）

```bash
# 下载一键部署脚本
curl -fsSL https://raw.githubusercontent.com/WinsPan/pve-kubesphere/main/one-click-deploy.sh -o one-click-deploy.sh

# 添加执行权限
chmod +x one-click-deploy.sh

# 执行一键部署
./one-click-deploy.sh
```

### 方法2：使用wget下载

```bash
# 下载一键部署脚本
wget https://raw.githubusercontent.com/WinsPan/pve-kubesphere/main/one-click-deploy.sh

# 添加执行权限
chmod +x one-click-deploy.sh

# 执行一键部署
./one-click-deploy.sh
```

### 方法3：自动确认部署（无需手动确认）

```bash
# 自动确认模式，跳过确认步骤
./one-click-deploy.sh -y
```

## 📋 部署内容

一键部署脚本将自动完成以下操作：

### 1. 环境准备
- ✅ 检查系统要求
- ✅ 备份现有安装
- ✅ 从GitHub下载最新脚本
- ✅ 验证关键文件

### 2. PVE环境准备
- ✅ 下载Debian 12模板
- ✅ 创建3个虚拟机 (8核16GB 300GB)
- ✅ 配置网络和存储
- ✅ 自动修复启动问题

### 3. Kubernetes安装
- ✅ 安装Kubernetes v1.29.7
- ✅ 配置集群网络
- ✅ 部署CNI插件

### 4. KubeSphere安装
- ✅ 安装KubeSphere v4.1.3
- ✅ 配置存储类
- ✅ 部署监控组件

## 🔧 虚拟机配置

| 节点 | IP地址 | 配置 | 用途 |
|------|--------|------|------|
| k8s-master | 10.0.0.10 | 8核16GB 300GB | 主节点 |
| k8s-worker1 | 10.0.0.11 | 8核16GB 300GB | 工作节点1 |
| k8s-worker2 | 10.0.0.12 | 8核16GB 300GB | 工作节点2 |

## 📊 系统要求

### PVE主机要求
- **CPU**: 至少24核（推荐32核以上）
- **内存**: 至少48GB（推荐64GB以上）
- **存储**: 至少1TB可用空间
- **网络**: 稳定的网络连接

### 软件要求
- **PVE版本**: 8.x
- **操作系统**: Debian/Ubuntu
- **网络**: 桥接网络vmbr0

## 🎯 使用方法

### 基本用法

```bash
# 使用默认配置
./one-click-deploy.sh

# 显示帮助信息
./one-click-deploy.sh -h

# 自动确认部署
./one-click-deploy.sh -y
```

### 高级用法

```bash
# 指定GitHub仓库和分支
./one-click-deploy.sh -r username/repo -b develop

# 组合使用
./one-click-deploy.sh -r WinsPan/pve-kubesphere -b main -y
```

## 📱 访问信息

部署完成后，您可以通过以下方式访问：

### KubeSphere控制台
- **URL**: http://10.0.0.10:30880
- **用户名**: admin
- **密码**: P@88w0rd

### SSH访问
```bash
# 主节点
ssh root@10.0.0.10

# 工作节点1
ssh root@10.0.0.11

# 工作节点2
ssh root@10.0.0.12
```

### 默认密码
- **SSH密码**: kubesphere123
- **KubeSphere密码**: P@88w0rd

## 🛠️ 故障排除工具

部署完成后，您可以使用以下工具进行故障排除：

### 网络诊断
```bash
cd pve-kubesphere-*
./test-network.sh
```

### SSH连接诊断
```bash
cd pve-kubesphere-*
./diagnose-ssh.sh --all
```

### 快速修复
```bash
cd pve-kubesphere-*
./quick-fix.sh --all
```

### 串口终端修复
```bash
cd pve-kubesphere-*
./fix-serial-terminal.sh
```

## 📚 相关文档

部署完成后，您可以查看以下文档：

- **README-KubeSphere.md**: 详细说明
- **QUICK-START.md**: 快速开始
- **TROUBLESHOOTING.md**: 故障排除
- **SERIAL-TERMINAL-FIX.md**: 串口修复
- **CONFIG-SUMMARY.md**: 配置总结

## ⚠️ 注意事项

1. **执行环境**: 建议在PVE主机上直接执行
2. **网络连接**: 确保网络连接稳定
3. **资源充足**: 确保PVE主机有足够资源
4. **备份数据**: 建议先备份重要数据
5. **防火墙**: 确保相关端口开放

## 🔄 重新部署

如果需要重新部署，可以：

```bash
# 清理现有环境
cd pve-kubesphere-*
./04-cleanup.sh

# 重新部署
./one-click-deploy.sh
```

## 📞 技术支持

如果遇到问题，可以：

1. 查看故障排除文档
2. 运行诊断工具
3. 检查系统日志
4. 查看GitHub Issues

## 🎉 完成

部署完成后，您将拥有一个完整的KubeSphere集群，可以开始使用容器编排和云原生应用管理功能！ 