#!/bin/bash

# ==========================================
# PVE K8S+KubeSphere 一键部署脚本 v4.0
# 作者: WinsPan
# 重构版本 - 模块化设计，高可靠性
# ==========================================

set -euo pipefail

# ==========================================
# 全局配置
# ==========================================
readonly SCRIPT_VERSION="4.0"
readonly SCRIPT_NAME="PVE K8S+KubeSphere 部署工具"

# 颜色定义
readonly GREEN='\e[0;32m'
readonly YELLOW='\e[1;33m'
readonly RED='\e[0;31m'
readonly BLUE='\e[0;34m'
readonly CYAN='\e[0;36m'
readonly NC='\e[0m'

# 系统配置
readonly STORAGE="local-lvm"
readonly BRIDGE="vmbr0"
readonly GATEWAY="10.0.0.1"
readonly DNS="119.29.29.29,8.8.8.8,10.0.0.2"

# 虚拟机配置 - 使用数组存储配置
declare -A VM_CONFIGS=(
    ["101"]="k8s-master:10.0.0.10:8:16384:300"
    ["102"]="k8s-worker1:10.0.0.11:8:16384:300"
    ["103"]="k8s-worker2:10.0.0.12:8:16384:300"
)

# 认证配置
readonly CLOUDINIT_USER="root"
readonly CLOUDINIT_PASS="kubesphere123"

# 云镜像配置
readonly CLOUD_IMAGE_URLS=(
    "https://mirrors.ustc.edu.cn/debian-cloud-images/bookworm/latest/debian-12-generic-amd64.qcow2"
    "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
)
readonly CLOUD_IMAGE_FILE="debian-12-generic-amd64.qcow2"
readonly CLOUD_IMAGE_PATH="/var/lib/vz/template/qcow/$CLOUD_IMAGE_FILE"

# K8S配置
readonly K8S_VERSION="v1.28.2"
readonly POD_SUBNET="10.244.0.0/16"

# 日志配置
readonly LOG_DIR="/var/log/pve-k8s-deploy"
readonly LOG_FILE="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"

# 超时配置
readonly SSH_TIMEOUT=600
readonly CLOUDINIT_TIMEOUT=900

# ==========================================
# 日志和工具函数
# ==========================================
init_logging() {
    mkdir -p "$LOG_DIR"
}

log()     { echo -e "${GREEN}[INFO]${NC} $(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE"; }

# 错误处理
handle_error() {
    local line_no=$1
    error "脚本在第 $line_no 行执行失败"
    error "详细日志: $LOG_FILE"
    exit 1
}

trap 'handle_error ${LINENO}' ERR

# 解析虚拟机配置
parse_vm_config() {
    local vm_id="$1"
    local field="$2"
    local config="${VM_CONFIGS[$vm_id]}"
    
    IFS=':' read -r name ip cores memory disk <<< "$config"
    
    case "$field" in
        "name") echo "$name" ;;
        "ip") echo "$ip" ;;
        "cores") echo "$cores" ;;
        "memory") echo "$memory" ;;
        "disk") echo "$disk" ;;
        *) error "未知字段: $field"; return 1 ;;
    esac
}

# 获取所有IP
get_all_ips() {
    local ips=()
    for vm_id in "${!VM_CONFIGS[@]}"; do
        ips+=($(parse_vm_config "$vm_id" "ip"))
    done
    echo "${ips[@]}"
}

# 获取master IP
get_master_ip() {
    parse_vm_config "101" "ip"
}

# 根据IP获取VM名称
get_vm_name_by_ip() {
    local target_ip="$1"
    for vm_id in "${!VM_CONFIGS[@]}"; do
        local ip=$(parse_vm_config "$vm_id" "ip")
        if [[ "$ip" == "$target_ip" ]]; then
            echo $(parse_vm_config "$vm_id" "name")
            return
        fi
    done
    echo "unknown"
}

# 重试执行函数
retry_command() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local command=("$@")
    
    for ((i=1; i<=max_attempts; i++)); do
        if "${command[@]}"; then
            return 0
        else
            if [[ $i -lt $max_attempts ]]; then
                warn "命令执行失败，重试 $i/$max_attempts，等待 ${delay}s..."
                sleep "$delay"
            fi
        fi
    done
    
    error "命令执行最终失败: ${command[*]}"
    return 1
}

# ==========================================
# 环境检查
# ==========================================
check_environment() {
    log "检查运行环境..."
    
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要root权限运行"
        exit 1
    fi
    
    # 检查PVE环境
    if ! command -v qm &>/dev/null; then
        error "未检测到PVE环境"
        exit 1
    fi
    
    # 检查必要命令
    local required_commands=("wget" "ssh" "sshpass" "nc")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            warn "安装缺失命令: $cmd"
            apt-get update -qq && apt-get install -y "$cmd"
        fi
    done
    
    # 清理SSH环境
    log "清理SSH环境..."
    local all_ips=($(get_all_ips))
    for ip in "${all_ips[@]}"; do
        ssh-keygen -f "/root/.ssh/known_hosts" -R "$ip" 2>/dev/null || true
    done
    
    success "环境检查完成"
}

# ==========================================
# SSH连接管理
# ==========================================
execute_remote_command() {
    local ip="$1"
    local command="$2"
    local max_retries="${3:-3}"
    
    for ((i=1; i<=max_retries; i++)); do
        if sshpass -p "$CLOUDINIT_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=10 \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "$CLOUDINIT_USER@$ip" "bash -c '$command'" 2>/dev/null; then
            return 0
        else
            if [[ $i -lt $max_retries ]]; then
                warn "节点 $ip 命令执行失败，重试 $i/$max_retries..."
                # 清理可能的旧SSH密钥
                ssh-keygen -f "/root/.ssh/known_hosts" -R "$ip" 2>/dev/null || true
                sleep 5
            fi
        fi
    done
    
    error "节点 $ip 命令执行失败"
    return 1
}

test_ssh_connection() {
    local ip="$1"
    execute_remote_command "$ip" "echo 'SSH测试成功'" 1
}

wait_for_ssh() {
    local ip="$1"
    local max_wait="${2:-$SSH_TIMEOUT}"
    
    log "等待 $ip SSH服务..."
    
    for ((i=0; i<max_wait; i+=10)); do
        if nc -z "$ip" 22 &>/dev/null && test_ssh_connection "$ip"; then
            success "$ip SSH服务就绪"
            return 0
        fi
        
        if [[ $((i % 60)) -eq 0 ]] && [[ $i -gt 0 ]]; then
            log "$ip SSH等待中... (${i}s/${max_wait}s)"
        fi
        
        sleep 10
    done
    
    error "$ip SSH服务超时"
    return 1
}

# 检查网络连接
check_network_connectivity() {
    local ip="$1"
    log "检查 $ip 网络连接..."
    
    local network_check_script='
        # 检查DNS解析
        echo "检查DNS解析..."
        if ! nslookup debian.org >/dev/null 2>&1 && ! nslookup google.com >/dev/null 2>&1; then
            echo "DNS解析失败，配置备用DNS..."
            cat > /etc/resolv.conf << "EOF"
nameserver 119.29.29.29
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
        fi
        
        # 测试网络连接
        echo "测试网络连接..."
        if ! ping -c 2 119.29.29.29 >/dev/null 2>&1 && ! ping -c 2 8.8.8.8 >/dev/null 2>&1; then
            echo "网络连接失败"
            exit 1
        fi
        
        echo "网络连接正常"
    '
    
    execute_remote_command "$ip" "$network_check_script"
}

# 等待Cloud-init完成（增强版）
wait_for_cloudinit() {
    local ip="$1"
    local max_wait="${2:-$CLOUDINIT_TIMEOUT}"
    
    log "等待 $ip Cloud-init完成..."
    
    for ((i=0; i<max_wait; i+=30)); do
        local status=""
        if status=$(execute_remote_command "$ip" "cloud-init status" 1 2>/dev/null); then
            echo -n "."
            if [[ "$status" == *"done"* ]]; then
                success "$ip Cloud-init完成"
                return 0
            elif [[ "$status" == *"error"* ]]; then
                warn "$ip Cloud-init出现错误，但继续执行"
                return 0
            fi
        else
            echo -n "x"
        fi
        
        if [[ $((i % 120)) -eq 0 ]] && [[ $i -gt 0 ]]; then
            log "$ip Cloud-init等待中... (${i}s/${max_wait}s)"
        fi
        
        sleep 30
    done
    
    warn "$ip Cloud-init超时，但继续执行"
    return 0
}

# ==========================================
# SSH配置修复
# ==========================================
fix_ssh_config() {
    local ip="$1"
    log "修复 $ip SSH配置..."
    
    local fix_script='
        # 备份配置
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%s)
        
        # 清理重复SFTP定义
        find /etc/ssh/sshd_config.d/ -name "*.conf" -exec sed -i "/^[[:space:]]*Subsystem[[:space:]]*sftp/d" {} \; 2>/dev/null || true
        
        # 确保主配置正确
        if ! grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config; then
            # 删除冲突配置
            sed -i "/^PermitRootLogin/d; /^PasswordAuthentication/d; /^PubkeyAuthentication/d" /etc/ssh/sshd_config
            
            # 添加新配置
            cat >> /etc/ssh/sshd_config << "EOF"

# PVE K8S部署专用SSH配置
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
EOF
        fi
        
        # 确保SFTP子系统存在
        if ! grep -q "^Subsystem.*sftp" /etc/ssh/sshd_config; then
            echo "Subsystem sftp /usr/lib/openssh/sftp-server" >> /etc/ssh/sshd_config
        fi
        
        # 验证并重启
        if sshd -t; then
            systemctl restart ssh sshd
            echo "SSH配置修复成功"
        else
            echo "SSH配置验证失败"
            exit 1
        fi
    '
    
    if execute_remote_command "$ip" "$fix_script"; then
        success "$ip SSH配置修复完成"
    else
        error "$ip SSH配置修复失败"
        return 1
    fi
}

fix_all_ssh_configs() {
    log "批量修复SSH配置..."
    local all_ips=($(get_all_ips))
    
    for ip in "${all_ips[@]}"; do
        fix_ssh_config "$ip"
    done
    
    success "所有SSH配置修复完成"
}

# ==========================================
# 云镜像管理
# ==========================================
download_cloud_image() {
    if [[ -f "$CLOUD_IMAGE_PATH" ]]; then
        log "云镜像已存在: $CLOUD_IMAGE_PATH"
        return 0
    fi
    
    log "下载云镜像..."
    mkdir -p "$(dirname "$CLOUD_IMAGE_PATH")"
    
    for url in "${CLOUD_IMAGE_URLS[@]}"; do
        log "尝试从 $url 下载..."
        if retry_command 3 5 wget -O "$CLOUD_IMAGE_PATH" "$url"; then
            success "云镜像下载完成"
            return 0
        else
            warn "下载失败，尝试下一个源..."
            rm -f "$CLOUD_IMAGE_PATH"
        fi
    done
    
    error "所有镜像源下载失败"
    return 1
}

# ==========================================
# Cloud-init配置
# ==========================================
create_cloudinit_config() {
    local vm_ip="$1"
    local vm_id="$2"
    local userdata_file="/var/lib/vz/snippets/user-data-k8s-${vm_id}.yml"
    
    log "创建虚拟机 $vm_id 的Cloud-init配置..."
    
    cat > "$userdata_file" << EOF
#cloud-config

chpasswd:
  expire: false
  users:
    - name: root
      password: $CLOUDINIT_PASS
      type: text

# 禁用cloud-init网络配置，使用手动配置
network:
  config: disabled

write_files:
  - path: /etc/ssh/sshd_config.d/00-root-login.conf
    content: |
      PermitRootLogin yes
      PasswordAuthentication yes
      PubkeyAuthentication yes
      AuthorizedKeysFile .ssh/authorized_keys
      ChallengeResponseAuthentication no
      UsePAM yes
      X11Forwarding yes
      PrintMotd no
      AcceptEnv LANG LC_*
    permissions: '0644'
    owner: root:root
  
  - path: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter
    permissions: '0644'
    owner: root:root
  
  - path: /etc/sysctl.d/99-k8s.conf
    content: |
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward = 1
    permissions: '0644'
    owner: root:root
  
  - path: /etc/network/interfaces.d/eth0
    content: |
      auto eth0
      iface eth0 inet static
        address ${vm_ip}
        netmask 255.255.255.0
        gateway $GATEWAY
        dns-nameservers 119.29.29.29 8.8.8.8 1.1.1.1
    permissions: '0644'
    owner: root:root

packages:
  - openssh-server
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - net-tools
  - ifupdown

runcmd:
  # 禁用可能冲突的网络服务
  - systemctl stop systemd-networkd systemd-networkd-wait-online 2>/dev/null || true
  - systemctl disable systemd-networkd systemd-networkd-wait-online 2>/dev/null || true
  - systemctl mask systemd-networkd-wait-online 2>/dev/null || true
  
  # 使用传统网络配置
  - systemctl enable networking
  - ip link set eth0 up
  - ifup eth0
  - sleep 3
  
  # 验证并手动配置（如果需要）
  - |
    echo "Configuring network interface..."
    if ! ip addr show eth0 | grep -q "inet ${vm_ip}"; then
      echo "ifupdown failed, using manual configuration"
      ip addr flush dev eth0 2>/dev/null || true
      ip addr add ${vm_ip}/24 dev eth0
      ip route add default via $GATEWAY dev eth0 2>/dev/null || true
    fi
    
    # 验证网络连接
    echo "Testing network connectivity..."
    if ping -c 3 $GATEWAY >/dev/null 2>&1; then
      echo "Network configuration successful - IP: ${vm_ip}"
    else
      echo "Network test failed, but continuing..."
    fi
  
  # DNS配置
  - |
    cat > /etc/resolv.conf << "EOF"
    nameserver 119.29.29.29
    nameserver 8.8.8.8
    nameserver 1.1.1.1
    EOF
  
  # 基础系统配置
  - apt-get update -y
  - systemctl enable ssh sshd
  - echo "root:$CLOUDINIT_PASS" | chpasswd
  - usermod -U root
  
  # SSH配置修复
  - systemctl stop ssh sshd
  - find /etc/ssh/sshd_config.d/ -name "*.conf" -exec sed -i '/^[[:space:]]*Subsystem[[:space:]]*sftp/d' {} \; 2>/dev/null || true
  - |
    if ! grep -q "^Subsystem.*sftp" /etc/ssh/sshd_config; then
      echo "Subsystem sftp /usr/lib/openssh/sftp-server" >> /etc/ssh/sshd_config
    fi
  - sshd -t && systemctl start ssh sshd || systemctl start ssh sshd
  
  # K8S环境准备
  - modprobe overlay br_netfilter
  - sysctl --system
  - swapoff -a
  - sed -i '/swap/d' /etc/fstab
  - timedatectl set-timezone Asia/Shanghai
  
  # 网络连接测试
  - ping -c 2 119.29.29.29 || ping -c 2 8.8.8.8 || echo "网络连接可能有问题"

final_message: "Cloud-init配置完成"
EOF
    
    success "虚拟机 $vm_id 的Cloud-init配置创建完成: $userdata_file"
    echo "$userdata_file"
}

# ==========================================
# 虚拟机管理
# ==========================================
create_vm() {
    local vm_id="$1"
    local vm_name=$(parse_vm_config "$vm_id" "name")
    local vm_ip=$(parse_vm_config "$vm_id" "ip")
    local vm_cores=$(parse_vm_config "$vm_id" "cores")
    local vm_memory=$(parse_vm_config "$vm_id" "memory")
    
    log "创建虚拟机: $vm_name (ID: $vm_id, IP: $vm_ip)"
    
    # 清理现有虚拟机
    qm stop "$vm_id" 2>/dev/null || true
    sleep 2
    qm destroy "$vm_id" 2>/dev/null || true
    
    # 创建虚拟机
    if qm create "$vm_id" \
        --name "$vm_name" \
        --memory "$vm_memory" \
        --cores "$vm_cores" \
        --net0 "virtio,bridge=$BRIDGE" \
        --scsihw virtio-scsi-pci \
        --ide2 "$STORAGE:cloudinit" \
        --serial0 socket \
        --vga std \
        --ipconfig0 "ip=$vm_ip/24,gw=$GATEWAY" \
        --nameserver "$DNS" \
        --ciuser "$CLOUDINIT_USER" \
        --cipassword "$CLOUDINIT_PASS" \
        --cicustom "user=local:snippets/user-data-k8s-${vm_id}.yml" \
        --agent enabled=1; then
        
        # 导入云镜像
        if qm importdisk "$vm_id" "$CLOUD_IMAGE_PATH" "$STORAGE" --format qcow2; then
            qm set "$vm_id" --scsi0 "$STORAGE:vm-$vm_id-disk-0"
            qm set "$vm_id" --boot c --bootdisk scsi0
            
            # 启动虚拟机
            if qm start "$vm_id"; then
                success "虚拟机 $vm_name 创建成功"
                return 0
            fi
        fi
    fi
    
    error "虚拟机 $vm_name 创建失败"
    return 1
}

create_all_vms() {
    log "创建所有虚拟机..."
    
    # 清理SSH known_hosts中的旧密钥
    log "清理SSH known_hosts中的旧密钥..."
    local all_ips=($(get_all_ips))
    for ip in "${all_ips[@]}"; do
        ssh-keygen -f "/root/.ssh/known_hosts" -R "$ip" 2>/dev/null || true
    done
    
    for vm_id in "${!VM_CONFIGS[@]}"; do
        local vm_ip=$(parse_vm_config "$vm_id" "ip")
        create_cloudinit_config "$vm_ip" "$vm_id"
        create_vm "$vm_id"
    done
    
    success "所有虚拟机创建完成"
}

wait_for_all_vms() {
    log "等待所有虚拟机启动..."
    
    local all_ips=($(get_all_ips))
    
    # 等待SSH连接
    for ip in "${all_ips[@]}"; do
        wait_for_ssh "$ip"
    done
    
    # 检查网络连接
    for ip in "${all_ips[@]}"; do
        check_network_connectivity "$ip" || warn "$ip 网络连接检查失败，但继续执行"
    done
    
    # 等待Cloud-init完成
    for ip in "${all_ips[@]}"; do
        wait_for_cloudinit "$ip"
    done
    
    success "所有虚拟机启动完成"
}

# ==========================================
# K8S部署
# ==========================================
# 验证Docker和K8S安装
verify_docker_k8s_installation() {
    local ip="$1"
    local verify_script='
        # 检查Docker
        if ! command -v docker &>/dev/null || ! systemctl is-active docker &>/dev/null; then
            echo "Docker验证失败"
            exit 1
        fi
        
        # 检查containerd
        if ! command -v containerd &>/dev/null || ! systemctl is-active containerd &>/dev/null; then
            echo "containerd验证失败"
            exit 1
        fi
        
        # 检查K8S组件
        if ! command -v kubectl &>/dev/null || ! command -v kubeadm &>/dev/null || ! command -v kubelet &>/dev/null; then
            echo "K8S组件验证失败"
            exit 1
        fi
        
        echo "Docker和K8S验证成功"
    '
    
    execute_remote_command "$ip" "$verify_script" 1
}

install_docker_k8s() {
    local ip="$1"
    log "在 $ip 安装Docker和K8S..."
    
    local install_script='
        set -e
        
        # 配置国内镜像源
        echo "配置镜像源..."
        cat > /etc/apt/sources.list << "EOF"
deb https://mirrors.ustc.edu.cn/debian/ bookworm main contrib non-free non-free-firmware
deb https://mirrors.ustc.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware
deb https://mirrors.ustc.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware
deb https://mirrors.ustc.edu.cn/debian-security/ bookworm-security main contrib non-free non-free-firmware
EOF
        
        # 更新包列表
        apt-get update -y || { echo "APT更新失败"; exit 1; }
        
        # 安装Docker
        echo "安装Docker..."
        if ! curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg | apt-key add -; then
            echo "尝试备用Docker GPG密钥..."
            curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
        fi
        
        echo "deb [arch=amd64] https://mirrors.aliyun.com/docker-ce/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
        
        apt-get update -y
        if ! apt-get install -y docker-ce docker-ce-cli containerd.io; then
            echo "Docker安装失败"
            exit 1
        fi
        
        # 配置Docker镜像加速
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json << "EOF"
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m"},
  "storage-driver": "overlay2",
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com",
    "https://mirror.baidubce.com"
  ]
}
EOF
        
        # 配置containerd
        mkdir -p /etc/containerd
        containerd config default > /etc/containerd/config.toml
        sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml
        sed -i "s|registry.k8s.io/pause:3.6|registry.aliyuncs.com/google_containers/pause:3.6|g" /etc/containerd/config.toml
        
        # 启动Docker服务
        systemctl daemon-reload
        systemctl enable docker containerd
        systemctl restart docker containerd
        
        # 验证Docker安装
        if ! docker --version; then
            echo "Docker启动失败"
            exit 1
        fi
        
        # 安装K8S
        echo "安装K8S..."
        if ! curl -fsSL https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | apt-key add -; then
            echo "尝试备用K8S GPG密钥..."
            curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
        fi
        
        echo "deb https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
        
        apt-get update -y
        if ! apt-get install -y kubelet=1.28.2-00 kubeadm=1.28.2-00 kubectl=1.28.2-00; then
            echo "K8S安装失败"
            exit 1
        fi
        
        apt-mark hold kubelet kubeadm kubectl
        systemctl enable kubelet
        
        # 验证K8S安装
        if ! kubectl version --client && ! kubeadm version; then
            echo "K8S组件验证失败"
            exit 1
        fi
        
        echo "Docker和K8S安装完成"
    '
    
    # 尝试安装，如果失败则重试
    if ! execute_remote_command "$ip" "$install_script"; then
        warn "$ip Docker/K8S安装失败，尝试修复..."
        
        # 修复安装
        local fix_script='
            echo "清理失败的安装..."
            apt-get remove --purge -y docker-ce docker-ce-cli containerd.io kubelet kubeadm kubectl 2>/dev/null || true
            apt-get autoremove -y
            rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/kubernetes.list
            
            echo "重新安装..."
        '
        
        execute_remote_command "$ip" "$fix_script"
        
        # 重新尝试安装
        if ! execute_remote_command "$ip" "$install_script"; then
            error "$ip Docker/K8S安装最终失败"
            return 1
        fi
    fi
    
    # 验证安装
    if verify_docker_k8s_installation "$ip"; then
        success "$ip Docker和K8S安装验证成功"
    else
        error "$ip Docker和K8S安装验证失败"
        return 1
    fi
}

init_k8s_master() {
    local master_ip=$(get_master_ip)
    log "初始化K8S主节点..."
    
    # 首先验证master节点的Docker和K8S安装
    if ! verify_docker_k8s_installation "$master_ip"; then
        error "Master节点Docker/K8S验证失败，重新安装..."
        install_docker_k8s "$master_ip"
    fi
    
    local init_script="
        set -e
        echo '开始初始化K8S主节点...'
        
        # 清理之前的配置
        kubeadm reset -f 2>/dev/null || true
        rm -rf /etc/kubernetes/manifests/* 2>/dev/null || true
        rm -rf /var/lib/etcd/* 2>/dev/null || true
        
        # 确保Docker和containerd运行
        systemctl restart docker containerd
        sleep 5
        
        # 使用国内镜像初始化
        if ! kubeadm init \
            --apiserver-advertise-address=$master_ip \
            --pod-network-cidr=$POD_SUBNET \
            --kubernetes-version=$K8S_VERSION \
            --image-repository=registry.aliyuncs.com/google_containers \
            --ignore-preflight-errors=all; then
            echo 'K8S初始化失败'
            exit 1
        fi
        
        # 配置kubectl
        mkdir -p /root/.kube
        cp /etc/kubernetes/admin.conf /root/.kube/config
        
        # 验证kubectl工作
        if ! kubectl get nodes; then
            echo 'kubectl配置失败'
            exit 1
        fi
        
        echo '下载Calico配置文件...'
        # 下载并修改Calico配置
        if ! wget -O calico.yaml https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml; then
            if ! curl -o calico.yaml https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml; then
                echo 'Calico下载失败，使用备用方案'
                kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml || exit 1
            else
                kubectl apply -f calico.yaml || exit 1
            fi
        else
            kubectl apply -f calico.yaml || exit 1
        fi
        
        echo 'K8S主节点初始化完成'
    "
    
    if execute_remote_command "$master_ip" "$init_script"; then
        success "K8S主节点初始化完成"
        
        # 验证主节点状态
        local verify_script="
            kubectl get nodes
            kubectl get pods --all-namespaces
        "
        execute_remote_command "$master_ip" "$verify_script" || warn "主节点状态检查有警告"
    else
        error "K8S主节点初始化失败"
        return 1
    fi
}

join_workers() {
    local master_ip=$(get_master_ip)
    
    # 获取加入命令
    local join_cmd=$(execute_remote_command "$master_ip" "kubeadm token create --print-join-command")
    
    if [[ -z "$join_cmd" ]]; then
        error "获取集群加入令牌失败"
        return 1
    fi
    
    # 加入worker节点
    for vm_id in "${!VM_CONFIGS[@]}"; do
        if [[ "$vm_id" != "101" ]]; then  # 跳过master节点
            local worker_ip=$(parse_vm_config "$vm_id" "ip")
            local worker_name=$(parse_vm_config "$vm_id" "name")
            
            log "将 $worker_name 加入集群..."
            
            # 首先验证worker节点的Docker和K8S安装
            if ! verify_docker_k8s_installation "$worker_ip"; then
                error "Worker节点 $worker_name Docker/K8S验证失败，重新安装..."
                install_docker_k8s "$worker_ip"
            fi
            
            local join_script="
                set -e
                echo '开始加入worker节点...'
                
                # 重置节点
                kubeadm reset -f 2>/dev/null || true
                
                # 确保Docker和containerd运行
                systemctl restart docker containerd
                sleep 5
                
                # 验证containerd socket
                if ! systemctl is-active containerd; then
                    echo 'containerd未运行，启动containerd...'
                    systemctl start containerd
                    sleep 3
                fi
                
                # 验证Docker
                if ! docker ps &>/dev/null; then
                    echo 'Docker未正常工作'
                    exit 1
                fi
                
                # 加入集群
                if ! $join_cmd --ignore-preflight-errors=all; then
                    echo 'Worker节点加入失败'
                    exit 1
                fi
                
                echo 'Worker节点加入完成'
            "
            
            if execute_remote_command "$worker_ip" "$join_script"; then
                success "Worker节点 $worker_name 加入完成"
                
                # 验证节点状态
                local verify_script="
                    kubectl get nodes | grep $worker_name || kubectl get nodes
                "
                execute_remote_command "$master_ip" "$verify_script" || warn "Worker节点 $worker_name 状态检查有警告"
            else
                error "Worker节点 $worker_name 加入失败"
                
                # 尝试修复
                warn "尝试修复Worker节点 $worker_name..."
                local fix_script="
                    echo '修复Worker节点...'
                    
                    # 清理失败的状态
                    kubeadm reset -f
                    
                    # 重启服务
                    systemctl restart docker containerd kubelet
                    sleep 10
                    
                    # 重新加入
                    $join_cmd --ignore-preflight-errors=all
                "
                
                if execute_remote_command "$worker_ip" "$fix_script"; then
                    success "Worker节点 $worker_name 修复成功"
                else
                    error "Worker节点 $worker_name 修复失败，请手动检查"
                fi
            fi
        fi
    done
    
    # 最终验证集群状态
    log "验证集群状态..."
    local cluster_status=$(execute_remote_command "$master_ip" "kubectl get nodes -o wide" 1)
    echo "$cluster_status"
    
    success "所有worker节点加入完成"
}

deploy_k8s() {
    log "部署K8S集群..."
    
    # 安装Docker和K8S组件
    local all_ips=($(get_all_ips))
    for ip in "${all_ips[@]}"; do
        install_docker_k8s "$ip"
    done
    
    # 初始化主节点
    init_k8s_master
    
    # 加入worker节点
    join_workers
    
    # 等待集群就绪
    local master_ip=$(get_master_ip)
    execute_remote_command "$master_ip" "kubectl wait --for=condition=Ready nodes --all --timeout=300s"
    
    success "K8S集群部署完成"
}

# ==========================================
# KubeSphere部署
# ==========================================
deploy_kubesphere() {
    local master_ip=$(get_master_ip)
    log "部署KubeSphere..."
    
    local deploy_script='
        # 下载配置文件
        wget -O kubesphere-installer.yaml https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml
        wget -O cluster-configuration.yaml https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml
        
        # 部署KubeSphere
        kubectl apply -f kubesphere-installer.yaml
        kubectl apply -f cluster-configuration.yaml
    '
    
    execute_remote_command "$master_ip" "$deploy_script"
    
    log "KubeSphere部署启动，监控安装进度..."
    execute_remote_command "$master_ip" "kubectl logs -n kubesphere-system \$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath='{.items[0].metadata.name}') -f" 1 || true
    
    success "KubeSphere部署完成"
}

# ==========================================
# 修复功能
# ==========================================
fix_docker_k8s() {
    log "修复Docker和K8S安装..."
    
    local all_ips=($(get_all_ips))
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        log "修复 $vm_name ($ip) 的Docker和K8S..."
        
        # 检查当前状态
        local status_script='
            echo "=== 检查当前状态 ==="
            echo "Docker状态: $(systemctl is-active docker 2>/dev/null || echo "未安装")"
            echo "containerd状态: $(systemctl is-active containerd 2>/dev/null || echo "未安装")"
            echo "kubelet状态: $(systemctl is-active kubelet 2>/dev/null || echo "未安装")"
            echo "kubectl版本: $(kubectl version --client 2>/dev/null || echo "未安装")"
        '
        
        execute_remote_command "$ip" "$status_script"
        
        # 强制重新安装
        if ! verify_docker_k8s_installation "$ip"; then
            warn "$vm_name Docker/K8S验证失败，重新安装..."
            install_docker_k8s "$ip"
        else
            success "$vm_name Docker/K8S验证成功"
        fi
    done
}

fix_k8s_cluster() {
    log "修复K8S集群..."
    
    local master_ip=$(get_master_ip)
    
    # 检查master节点状态
    log "检查master节点状态..."
    local master_status=$(execute_remote_command "$master_ip" "kubectl get nodes 2>/dev/null || echo 'CLUSTER_NOT_READY'" 1)
    
    if [[ "$master_status" == "CLUSTER_NOT_READY" ]]; then
        warn "K8S集群未就绪，重新初始化master节点..."
        init_k8s_master
    else
        log "Master节点状态正常"
        echo "$master_status"
    fi
    
    # 检查worker节点
    log "检查worker节点状态..."
    for vm_id in "${!VM_CONFIGS[@]}"; do
        if [[ "$vm_id" != "101" ]]; then
            local worker_ip=$(parse_vm_config "$vm_id" "ip")
            local worker_name=$(parse_vm_config "$vm_id" "name")
            
            # 检查节点是否在集群中
            local node_in_cluster=$(execute_remote_command "$master_ip" "kubectl get nodes | grep $worker_name || echo 'NOT_FOUND'" 1)
            
            if [[ "$node_in_cluster" == "NOT_FOUND" ]]; then
                warn "Worker节点 $worker_name 不在集群中，重新加入..."
                
                # 获取加入命令
                local join_cmd=$(execute_remote_command "$master_ip" "kubeadm token create --print-join-command")
                
                if [[ -n "$join_cmd" ]]; then
                    local rejoin_script="
                        kubeadm reset -f
                        systemctl restart docker containerd kubelet
                        sleep 5
                        $join_cmd --ignore-preflight-errors=all
                    "
                    
                    if execute_remote_command "$worker_ip" "$rejoin_script"; then
                        success "Worker节点 $worker_name 重新加入成功"
                    else
                        error "Worker节点 $worker_name 重新加入失败"
                    fi
                else
                    error "获取集群加入令牌失败"
                fi
            else
                log "Worker节点 $worker_name 状态: $node_in_cluster"
            fi
        fi
    done
}

fix_network_connectivity() {
    log "修复网络连接问题..."
    
    local all_ips=($(get_all_ips))
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        log "修复 $vm_name ($ip) 的网络连接..."
        
        local network_fix_script='
            echo "修复网络连接..."
            
            # 配置DNS
            echo "nameserver 119.29.29.29" > /etc/resolv.conf
            echo "nameserver 8.8.8.8" >> /etc/resolv.conf
            echo "nameserver 10.0.0.1" >> /etc/resolv.conf
            
            # 重启网络服务
            systemctl restart networking
            
            # 测试网络连接
            echo "测试网络连接..."
            ping -c 2 119.29.29.29 || echo "DNS连接失败"
            ping -c 2 baidu.com || echo "外网连接失败"
            
            # 测试镜像源
            curl -I https://mirrors.ustc.edu.cn/debian/ || echo "镜像源连接失败"
        '
        
        execute_remote_command "$ip" "$network_fix_script"
    done
}

# ==========================================
# 状态检查
# ==========================================
check_status() {
    local master_ip=$(get_master_ip)
    log "检查集群状态..."
    
    execute_remote_command "$master_ip" '
        echo "=== 节点状态 ==="
        kubectl get nodes -o wide
        
        echo "=== Pod状态 ==="
        kubectl get pods --all-namespaces
        
        echo "=== KubeSphere状态 ==="
        kubectl get pods -n kubesphere-system
        
        echo "=== 集群信息 ==="
        kubectl cluster-info
    '
}

# ==========================================
# 清理资源
# ==========================================
cleanup_all() {
    log "清理所有资源..."
    
    for vm_id in "${!VM_CONFIGS[@]}"; do
        local vm_name=$(parse_vm_config "$vm_id" "name")
        log "删除虚拟机: $vm_name (ID: $vm_id)"
        qm stop "$vm_id" 2>/dev/null || true
        sleep 2
        qm destroy "$vm_id" 2>/dev/null || true
    done
    
    rm -f /var/lib/vz/snippets/user-data-k8s-*.yml
    success "资源清理完成"
}

# ==========================================
# 用户界面
# ==========================================
show_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║           PVE K8S + KubeSphere 一键部署工具 v4.0            ║"
    echo "║                        重构精简版                            ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

show_menu() {
    echo -e "${YELLOW}═══════════════ 主菜单 ═══════════════${NC}"
    echo -e "${GREEN}部署功能：${NC}"
    echo -e "  ${CYAN}1.${NC} 一键全自动部署（推荐）"
    echo -e "  ${CYAN}2.${NC} 下载云镜像"
    echo -e "  ${CYAN}3.${NC} 创建虚拟机"
    echo -e "  ${CYAN}4.${NC} 部署K8S集群"
    echo -e "  ${CYAN}5.${NC} 部署KubeSphere"
    echo ""
    echo -e "${YELLOW}修复功能：${NC}"
    echo -e "  ${CYAN}6.${NC} 修复Docker和K8S安装"
    echo -e "  ${CYAN}7.${NC} 修复K8S集群"
    echo -e "  ${CYAN}8.${NC} 修复网络连接"
    echo -e "  ${CYAN}9.${NC} 修复SSH配置"
    echo ""
    echo -e "${BLUE}状态检查：${NC}"
    echo -e "  ${CYAN}10.${NC} 检查集群状态"
    echo ""
    echo -e "${RED}管理功能：${NC}"
    echo -e "  ${CYAN}11.${NC} 清理所有资源"
    echo -e "  ${CYAN}0.${NC} 退出"
    echo -e "${YELLOW}══════════════════════════════════════${NC}"
}

# ==========================================
# 主程序
# ==========================================
main() {
    init_logging
    log "脚本启动 - $SCRIPT_NAME v$SCRIPT_VERSION"
    
    check_environment
    
    while true; do
        clear
        show_banner
        show_menu
        
        read -p "请选择操作 [0-11]: " choice
        
        case $choice in
            1)
                log "开始一键全自动部署..."
                download_cloud_image && \
                create_all_vms && \
                wait_for_all_vms && \
                deploy_k8s && \
                deploy_kubesphere
                success "一键部署完成！"
                ;;
            2) download_cloud_image ;;
            3) create_all_vms && wait_for_all_vms ;;
            4) deploy_k8s ;;
            5) deploy_kubesphere ;;
            6) fix_docker_k8s ;;
            7) fix_k8s_cluster ;;
            8) fix_network_connectivity ;;
            9) fix_all_ssh_configs ;;
            10) check_status ;;
            11) cleanup_all ;;
            0) 
                log "退出脚本"
                exit 0 
                ;;
            *)
                warn "无效选择，请重新输入"
                ;;
        esac
        
        echo ""
        read -p "按回车键继续..."
    done
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 