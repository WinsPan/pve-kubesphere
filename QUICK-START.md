# PVE KubeSphere 快速开始指南

## 🚀 一键部署

### 前提条件
- PVE主机已安装并配置
- 网络连接正常
- 至少48GB RAM和1TB存储空间

### 快速部署步骤

1. **下载脚本**
   ```bash
   # 确保所有脚本有执行权限
   chmod +x *.sh
   ```

2. **修改配置**（重要！）
   ```bash
   # 编辑以下文件中的IP地址
   vim 01-pve-prepare.sh    # 修改PVE_HOST
   vim 02-k8s-install.sh    # 确认节点IP
   vim 03-kubesphere-install.sh  # 确认主节点IP
   ```

3. **一键部署**
   ```bash
   ./deploy-all.sh
   ```

4. **访问KubeSphere**
   - 地址：http://10.0.0.10:30880
   - 用户名：admin
   - 密码：P@88w0rd

## 📋 分步部署

如果一键部署失败，可以分步执行：

```bash
# 第一步：创建虚拟机
./01-pve-prepare.sh

# 第二步：安装Kubernetes
./02-k8s-install.sh

# 第三步：安装KubeSphere
./03-kubesphere-install.sh
```

## 🔧 常用命令

```bash
# SSH到主节点
ssh root@10.0.0.10

# 查看集群状态
kubectl get nodes
kubectl get pods --all-namespaces

# 查看KubeSphere状态
kubectl get pods -n kubesphere-system
```

## 🧹 清理环境

```bash
./04-cleanup.sh
```

## 📚 更多信息

- 详细文档：`README-KubeSphere.md`
- 故障排除：查看各脚本的日志输出
- 配置说明：编辑脚本文件中的配置变量

## ⚠️ 注意事项

1. 首次部署需要30-60分钟
2. 确保网络连接稳定
3. 建议在生产环境使用前充分测试
4. 定期备份重要数据

---

**开始部署前，请务必修改脚本中的IP地址配置！** 