# PVE KubeSphere 部署指南

## 概述

本指南提供了在Proxmox VE (PVE) 上部署KubeSphere的完整解决方案。通过自动化脚本，您可以轻松创建3个Debian虚拟机，安装Kubernetes集群，并部署KubeSphere容器平台。

## 系统要求

### PVE主机要求
- Proxmox VE 7.0 或更高版本
- 至少 48GB RAM (3个虚拟机 × 16GB + 系统开销)
- 至少 1TB 可用存储空间 (3个虚拟机 × 300GB + 系统开销)
- 网络连接（用于下载模板和软件包）

### 网络要求
- 静态IP地址配置
- 防火墙开放必要端口（22, 6443, 30880等）
- DNS解析正常

## 架构设计

```
PVE主机 (10.0.0.1)
├── k8s-master (10.0.0.10) - Kubernetes主节点
├── k8s-worker1 (10.0.0.11) - Kubernetes工作节点1
└── k8s-worker2 (10.0.0.12) - Kubernetes工作节点2
```

## 部署步骤

### 第一步：环境准备

1. **修改配置**
   编辑 `01-pve-prepare.sh` 文件，根据您的环境修改以下配置：
   ```bash
   PVE_HOST="10.0.0.1"  # 您的PVE主机IP
   STORAGE_NAME="local-lvm"  # 存储名称
   BRIDGE_NAME="vmbr0"       # 网桥名称
   ```

2. **运行环境准备脚本**
   ```bash
   chmod +x 01-pve-prepare.sh
   ./01-pve-prepare.sh
   ```

   此脚本将：
   - 检查PVE连接
   - 下载Debian 12模板
   - 创建3个虚拟机
   - 配置网络和cloud-init
   - 启动虚拟机

### 第二步：安装Kubernetes

1. **修改配置**
   编辑 `02-k8s-install.sh` 文件，确认节点IP配置：
   ```bash
   MASTER_IP="10.0.0.10"
   WORKER_IPS=("10.0.0.11" "10.0.0.12")
   ```

2. **运行Kubernetes安装脚本**
   ```bash
   chmod +x 02-k8s-install.sh
   ./02-k8s-install.sh
   ```

   此脚本将：
   - 在所有节点上准备系统环境
   - 安装containerd容器运行时
   - 安装Kubernetes组件
   - 初始化主节点
   - 安装Calico网络插件
   - 加入worker节点

### 第三步：安装KubeSphere

1. **修改配置**
   编辑 `03-kubesphere-install.sh` 文件，确认配置：
   ```bash
   MASTER_IP="10.0.0.10"
   KUBESPHERE_VERSION="v4.1.3"
   ```

2. **运行KubeSphere安装脚本**
   ```bash
   chmod +x 03-kubesphere-install.sh
   ./03-kubesphere-install.sh
   ```

   此脚本将：
   - 安装Helm包管理器
   - 安装OpenEBS本地存储
   - 安装KubeSphere
   - 配置访问信息
   - 安装常用工具
   - 创建示例应用

## 访问信息

安装完成后，您可以通过以下方式访问：

### KubeSphere控制台
- **地址**: http://10.0.0.10:30880
- **用户名**: admin
- **密码**: P@88w0rd

### SSH访问
```bash
# 主节点
ssh root@10.0.0.10

# Worker节点
ssh root@10.0.0.11
ssh root@10.0.0.12
```

### 默认密码
所有节点的默认密码都是：`kubesphere123`

## 常用命令

### 查看集群状态
```bash
# 在主节点上执行
kubectl get nodes
kubectl get pods --all-namespaces
kubectl cluster-info
```

### 查看KubeSphere状态
```bash
# 查看KubeSphere pods
kubectl get pods -n kubesphere-system

# 查看安装日志
kubectl logs -n kubesphere-system $(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath='{.items[0].metadata.name}') -f
```

### 端口转发（如果需要）
```bash
# 将KubeSphere控制台转发到本地
kubectl port-forward -n kubesphere-system svc/ks-console 30880:80
```

## 故障排除

### 常见问题

1. **虚拟机无法启动**
   - 检查PVE存储空间
   - 检查网络配置
   - 查看PVE日志：`tail -f /var/log/pve/tasks/`

2. **Kubernetes节点无法加入集群**
   - 检查网络连通性
   - 检查防火墙设置
   - 重新生成join命令：`kubeadm token create --print-join-command`

3. **KubeSphere安装失败**
   - 检查Kubernetes集群状态
   - 检查存储类配置
   - 查看安装日志

4. **无法访问KubeSphere控制台**
   - 检查NodePort服务状态
   - 检查防火墙规则
   - 使用端口转发测试

### 日志查看

```bash
# 查看kubelet日志
journalctl -u kubelet -f

# 查看containerd日志
journalctl -u containerd -f

# 查看系统日志
journalctl -f
```

## 清理和重置

如果需要清理整个环境，可以运行清理脚本：

```bash
chmod +x 04-cleanup.sh
./04-cleanup.sh
```

**警告**: 此操作将删除所有数据，请谨慎使用！

## 备份和恢复

### 备份etcd数据
```bash
# 在主节点上执行
etcdctl snapshot save backup.db
```

### 备份Kubernetes配置
```bash
# 备份所有资源
kubectl get all --all-namespaces -o yaml > backup.yaml
```

### 恢复集群
```bash
# 恢复etcd数据
etcdctl snapshot restore backup.db

# 恢复配置
kubectl apply -f backup.yaml
```

## 性能优化

### 系统优化
```bash
# 调整内核参数
echo 'vm.swappiness=0' >> /etc/sysctl.conf
echo 'vm.max_map_count=262144' >> /etc/sysctl.conf
sysctl -p
```

### 存储优化
```bash
# 使用SSD存储
# 配置适当的存储类
# 定期清理未使用的镜像
```

## 安全建议

1. **更改默认密码**
   - 更改所有节点的root密码
   - 更改KubeSphere管理员密码

2. **配置防火墙**
   - 只开放必要端口
   - 限制访问来源

3. **启用RBAC**
   - 配置适当的角色和权限
   - 使用最小权限原则

4. **定期更新**
   - 保持系统和软件包更新
   - 监控安全公告

## 监控和维护

### 监控指标
- 节点资源使用率
- Pod运行状态
- 存储使用情况
- 网络流量

### 维护任务
- 定期清理日志
- 更新软件包
- 备份重要数据
- 检查集群健康状态

## 扩展集群

### 添加Worker节点
1. 在PVE上创建新的虚拟机
2. 按照相同步骤配置系统
3. 使用join命令加入集群

### 升级Kubernetes
1. 备份集群数据
2. 按照官方文档升级
3. 测试所有功能

## 技术支持

如果遇到问题，请：

1. 查看相关日志文件
2. 检查网络连接
3. 验证配置参数
4. 参考官方文档

## 更新日志

- **v1.0.0** - 初始版本
  - 支持PVE 7.0+
  - 支持Kubernetes 1.29.7
  - 支持KubeSphere 4.1.3

## 许可证

本脚本遵循MIT许可证，您可以自由使用和修改。

---

**注意**: 在生产环境中使用前，请充分测试所有功能，并根据实际需求调整配置参数。

### 部署前检查清单
- [ ] 确认PVE主机 (10.0.0.1) 可以访问
- [ ] 确认网络配置与您的环境匹配
- [ ] 确认有足够的存储空间 (至少1TB)
- [ ] 确认有足够的内存 (至少48GB)
- [ ] 确认防火墙允许必要端口 