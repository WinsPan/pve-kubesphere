# PVE K8S+KubeSphere 一键部署脚本

## 功能特性

- 🚀 **一键部署**：自动创建3台KVM虚拟机，部署K8S集群和KubeSphere
- 🔧 **智能诊断**：内置PVE环境诊断、虚拟机状态检查、K8S集群诊断
- 🛠️ **问题修复**：自动修复Flannel网络问题、kube-controller-manager崩溃、KubeSphere安装失败
- 📊 **状态监控**：实时监控部署进度和集群状态
- 🔄 **重试机制**：智能重试和错误恢复
- 🎯 **轻量版选项**：支持轻量版KubeSphere安装，适合测试环境

## 系统要求

- PVE 7.0+ 环境
- 至少 48GB 内存（3台16GB虚拟机）
- 至少 900GB 存储空间（3台300GB虚拟机）
- 至少 24核 CPU（3台8核虚拟机）
- 网络连接（用于下载镜像和软件包）

## 默认配置

- **虚拟机配置**：
  - 3台虚拟机：k8s-master, k8s-worker1, k8s-worker2
  - 每台：8核CPU, 16GB内存, 300GB存储
  - IP地址：10.0.0.10, 10.0.0.11, 10.0.0.12

- **网络配置**：
  - 网桥：vmbr0
  - 网关：10.0.0.1
  - DNS：10.0.0.2, 119.29.29.29

- **登录信息**：
  - 用户名：root
  - 密码：kubesphere123

## 使用方法

### 1. 部署K8S+KubeSphere集群

```bash
# 给脚本执行权限
chmod +x one-click-pve-k8s.sh

# 运行脚本
./one-click-pve-k8s.sh
```

选择菜单选项：
1. **诊断PVE环境**：检查PVE环境是否满足要求
2. **下载Debian Cloud镜像**：下载最新的Debian 12 Cloud镜像
3. **创建并启动虚拟机**：创建3台KVM虚拟机并启动
4. **修正已存在虚拟机配置**：修复现有虚拟机的配置问题
5. **部署K8S集群**：自动部署K8S集群
6. **部署KubeSphere**：安装KubeSphere控制台
7. **清理所有资源**：删除所有虚拟机资源
8. **一键全自动部署**：执行完整的部署流程
9. **诊断Cloud-init配置**：检查cloud-init配置问题
10. **诊断单个虚拟机**：诊断特定虚拟机的问题
11. **升级K8S和KubeSphere**：升级到最新版本
12. **诊断KubeSphere安装问题**：检查KubeSphere安装状态
13. **部署轻量版KubeSphere**：安装轻量版KubeSphere
14. **修复K8S和KubeSphere问题**：修复常见问题

### 2. 修复功能

脚本内置了强大的修复功能，可以解决以下常见问题：

#### 修复Flannel网络问题
- 删除有问题的Flannel配置
- 清理Flannel网络接口
- 安装Calico网络插件作为替代

#### 修复kube-controller-manager崩溃
- 检查崩溃原因
- 重启kubelet服务
- 恢复控制器管理器

#### 修复KubeSphere安装问题
- 清理失败的安装
- 重新安装轻量版KubeSphere
- 配置最小化组件

### 3. 访问信息

部署完成后，可以通过以下方式访问：

- **KubeSphere控制台**: http://10.0.0.10:30880
- **用户名**: admin
- **密码**: P@88w0rd

### 4. 故障排除

#### 常见问题及解决方案

1. **虚拟机无法启动**
   - 检查PVE资源是否充足
   - 确认存储空间足够
   - 检查网络配置

2. **SSH连接失败**
   - 检查cloud-init配置
   - 确认root密码设置正确
   - 检查网络连通性

3. **K8S集群部署失败**
   - 检查虚拟机状态
   - 确认网络连接正常
   - 查看部署日志

4. **KubeSphere安装卡住**
   - 使用诊断功能检查状态
   - 尝试轻量版安装
   - 检查资源使用情况

5. **网络插件问题**
   - 使用修复功能替换Flannel为Calico
   - 检查网络配置
   - 重启相关服务

#### 手动诊断命令

```bash
# 检查虚拟机状态
qm list

# 检查网络连接
ping 10.0.0.10

# SSH到master节点
sshpass -p kubesphere123 ssh root@10.0.0.10

# 检查K8S集群状态
kubectl get nodes
kubectl get pods -n kube-system

# 检查KubeSphere状态
kubectl get pods -n kubesphere-system
```

## 日志文件

脚本运行过程中会生成以下日志文件：
- `auto_deploy_YYYYMMDD_HHMMSS.log`：自动部署日志
- `/root/k8s-init.log`：K8S初始化日志
- `/root/kubesphere-install.log`：KubeSphere安装日志
- `/root/flannel-fix.log`：Flannel修复日志
- `/root/controller-fix.log`：控制器修复日志
- `/root/kubesphere-fix.log`：KubeSphere修复日志

## 注意事项

1. **资源要求**：确保PVE主机有足够的CPU、内存和存储资源
2. **网络配置**：确保vmbr0网桥配置正确
3. **防火墙**：确保相关端口（22, 6443, 30880等）未被防火墙阻止
4. **备份**：在生产环境中使用前，建议先备份重要数据
5. **测试环境**：建议先在测试环境中验证脚本功能

## 更新日志

- **v1.0**：基础部署功能
- **v1.1**：添加诊断和修复功能
- **v1.2**：增强错误处理和重试机制
- **v1.3**：添加轻量版KubeSphere选项
- **v1.4**：完善修复工具，支持一键修复所有问题

## 技术支持

如果遇到问题，请：
1. 查看相关日志文件
2. 使用脚本内置的诊断功能
3. 尝试使用修复功能
4. 检查系统资源使用情况 