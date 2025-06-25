# 故障排除指南

## 网络连接问题

### 1. 下载Debian模板失败

**症状：**
```
[ERROR] 第一步失败：PVE环境准备失败
[ERROR] 部署在第 1 步失败，错误代码: 0
```

**解决方案：**

#### 方法1：手动下载模板
```bash
# 在PVE主机上执行
cd /var/lib/vz/template/cache

# 尝试从中国镜像源下载
wget https://mirrors.ustc.edu.cn/proxmox/images/system/debian-12-standard_12.2-1_amd64.tar.zst

# 或者使用curl
curl -L -o debian-12-standard_12.2-1_amd64.tar.zst https://mirrors.ustc.edu.cn/proxmox/images/system/debian-12-standard_12.2-1_amd64.tar.zst
```

#### 方法2：使用PVE内置下载功能
```bash
# 更新模板列表
pveam update

# 下载Debian模板
pveam download local debian-12-standard_12.2-1_amd64.tar.zst
```

#### 方法3：从其他机器传输
如果PVE主机无法直接下载，可以从其他机器下载后传输：

```bash
# 在其他机器上下载
wget https://mirrors.ustc.edu.cn/proxmox/images/system/debian-12-standard_12.2-1_amd64.tar.zst

# 传输到PVE主机
scp debian-12-standard_12.2-1_amd64.tar.zst root@PVE_HOST_IP:/var/lib/vz/template/cache/
```

### 2. 网络连接测试

运行网络诊断脚本：
```bash
./test-network.sh
```

### 3. 防火墙和代理设置

#### 检查防火墙
```bash
# 检查iptables
iptables -L

# 检查ufw
ufw status

# 临时禁用防火墙测试
ufw disable  # 测试完成后记得重新启用
```

#### 设置代理（如果需要）
```bash
# 设置HTTP代理
export http_proxy=http://proxy_server:port
export https_proxy=http://proxy_server:port

# 设置wget代理
echo "use_proxy = on" >> ~/.wgetrc
echo "http_proxy = http://proxy_server:port" >> ~/.wgetrc
echo "https_proxy = http://proxy_server:port" >> ~/.wgetrc
```

## 虚拟机创建问题

### 1. 存储空间不足

**检查存储空间：**
```bash
# 检查磁盘空间
df -h

# 检查存储状态
pvesm status
```

**清理空间：**
```bash
# 清理临时文件
rm -rf /var/lib/vz/template/cache/*.tmp

# 清理日志文件
journalctl --vacuum-time=7d
```

### 2. 网络桥接问题

**检查网络配置：**
```bash
# 查看网络接口
ip addr show

# 查看桥接配置
brctl show

# 检查网络配置文件
cat /etc/network/interfaces
```

**创建网络桥接：**
```bash
# 编辑网络配置
nano /etc/network/interfaces

# 添加桥接配置
auto vmbr0
iface vmbr0 inet static
    address 192.168.1.100/24
    gateway 192.168.1.1
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
```

## SSH连接问题

### 1. 虚拟机无法SSH连接

**检查虚拟机状态：**
```bash
# 查看虚拟机列表
qm list

# 查看虚拟机详细信息
qm status VMID
```

**检查网络配置：**
```bash
# 进入虚拟机控制台
qm terminal VMID

# 检查网络配置
ip addr show
ping 8.8.8.8
```

### 2. SSH密钥问题

**生成SSH密钥：**
```bash
# 生成SSH密钥对
ssh-keygen -t rsa -b 4096 -C "your_email@example.com"

# 复制公钥到虚拟机
ssh-copy-id root@VM_IP
```

## 常见错误代码

### 错误代码 0
- **原因：** 通常表示脚本正常退出但某个步骤失败
- **解决：** 检查日志输出，找到具体的失败步骤

### 错误代码 1
- **原因：** 脚本遇到错误并退出
- **解决：** 查看错误信息，通常是配置问题

### 错误代码 2
- **原因：** 权限不足
- **解决：** 确保以root用户运行脚本

## 日志分析

### 查看详细日志
```bash
# 运行脚本时启用详细输出
bash -x ./01-pve-prepare.sh

# 查看系统日志
journalctl -f

# 查看PVE日志
tail -f /var/log/pve/tasks/index.log
```

### 常见日志信息
- `qm create failed`: 虚拟机创建失败，检查存储和网络配置
- `wget failed`: 下载失败，检查网络连接
- `ssh connection refused`: SSH连接被拒绝，检查虚拟机状态和网络

## 性能优化

### 1. 提高下载速度
```bash
# 使用多线程下载
wget -c -t 0 -O debian-12-standard_12.2-1_amd64.tar.zst https://mirrors.ustc.edu.cn/proxmox/images/system/debian-12-standard_12.2-1_amd64.tar.zst

# 或者使用aria2
aria2c -x 16 -s 16 https://mirrors.ustc.edu.cn/proxmox/images/system/debian-12-standard_12.2-1_amd64.tar.zst
```

### 2. 优化虚拟机性能
```bash
# 设置CPU类型为host
qm set VMID --cpu host

# 启用嵌套虚拟化
echo "options kvm_intel nested=1" >> /etc/modprobe.d/kvm.conf
modprobe -r kvm_intel
modprobe kvm_intel
```

## 联系支持

如果以上方法都无法解决问题，请：

1. 收集错误日志和系统信息
2. 运行 `./test-network.sh` 生成诊断报告
3. 提供以下信息：
   - PVE版本
   - 错误日志
   - 网络诊断报告
   - 系统配置信息

## 快速修复脚本

如果遇到常见问题，可以运行快速修复脚本：

```bash
# 清理并重新开始
./04-cleanup.sh
./01-pve-prepare.sh
``` 