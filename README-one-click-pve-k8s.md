# 一键PVE K8S+KubeSphere全自动部署脚本 使用说明

## 功能简介

本脚本可在Proxmox VE（PVE）环境下，一键完成如下操作：

- 自动下载Debian 12.2官方ISO
- 自动创建3台KVM虚拟机（cloud-init无人值守，静态IP，root/kubesphere123）
- 自动批量启动、检测、SSH初始化
- 自动在master节点初始化Kubernetes集群（kubeadm+calico网络）
- 自动将worker节点加入集群
- 自动在master节点安装KubeSphere（官方一键脚本）
- 全流程日志输出，遇到错误友好提示，所有日志保存在`deploy.log`

---

## 环境要求

- 已安装Proxmox VE（PVE）8.x
- PVE主机有足够的CPU/内存/磁盘资源（建议24核48G/1T以上）
- 能访问公网（用于下载ISO、K8S、KubeSphere等）
- 已安装依赖：`qm`、`wget`、`sshpass`、`nc`
  - 安装命令示例：  
    ```bash
    apt update
    apt install -y wget sshpass netcat
    ```

---

## 使用方法

1. **上传脚本到PVE主机任意目录**
2. **赋予执行权限**
   ```bash
   chmod +x one-click-pve-k8s.sh
   ```
3. **运行脚本**
   ```bash
   ./one-click-pve-k8s.sh
   ```
4. **全程无需人工干预，所有日志自动保存到 `deploy.log`**

---

## 部署完成后

- **KubeSphere控制台**  
  地址：http://10.0.0.10:30880  
  用户名：admin  
  密码：P@88w0rd

- **K8S节点信息**  
  - master: 10.0.0.10  
  - worker1: 10.0.0.11  
  - worker2: 10.0.0.12  
  - 所有节点root密码：kubesphere123

- **日志文件**  
  所有部署过程日志保存在当前目录的 `deploy.log`，如遇问题可查阅或发给技术支持。

---

## 常见问题

- **依赖未安装**  
  按提示安装缺失依赖后重试。
- **网络不通/端口未开放**  
  检查PVE主机网络、虚拟机网络桥接、外网访问等。
- **KubeSphere首次访问慢**  
  安装后首次访问需等待几分钟，耐心等待页面加载。

---

## 高级定制

如需自定义节点数量、资源、K8S/KubeSphere版本、网络插件等，请联系维护者或技术支持。

---

## 技术支持

如遇到脚本无法解决的问题，请将`deploy.log`日志内容一并提供，便于快速定位和解决。

---

如需进一步定制或有新需求，欢迎随时联系！ 