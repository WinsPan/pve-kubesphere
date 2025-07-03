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

# 自动诊断系统问题
diagnose_system() {
    log "开始系统诊断..."
    
    local issues_found=0
    local all_ips=($(get_all_ips))
    
    # 检查虚拟机状态
    log "检查虚拟机状态..."
    for vm_id in "${!VM_CONFIGS[@]}"; do
        local vm_name=$(parse_vm_config "$vm_id" "name")
        local vm_status=$(qm status "$vm_id" 2>/dev/null | grep -o "status: [^,]*" | cut -d' ' -f2)
        
        if [[ "$vm_status" != "running" ]]; then
            warn "虚拟机 $vm_name (ID: $vm_id) 状态异常: $vm_status"
            ((issues_found++))
        else
            log "虚拟机 $vm_name (ID: $vm_id) 状态正常"
        fi
    done
    
    # 检查SSH连接
    log "检查SSH连接..."
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        if ! test_ssh_connection "$ip"; then
            warn "SSH连接失败: $vm_name ($ip)"
            ((issues_found++))
        else
            log "SSH连接正常: $vm_name ($ip)"
        fi
    done
    
    # 检查Docker和K8S安装
    log "检查Docker和K8S安装..."
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        if ! verify_docker_k8s_installation "$ip"; then
            warn "Docker/K8S安装异常: $vm_name ($ip)"
            ((issues_found++))
        else
            log "Docker/K8S安装正常: $vm_name ($ip)"
        fi
    done
    
    # 检查K8S集群状态
    log "检查K8S集群状态..."
    local master_ip=$(get_master_ip)
    local cluster_status=$(execute_remote_command "$master_ip" "kubectl get nodes 2>/dev/null || echo 'CLUSTER_NOT_READY'" 1)
    
    if [[ "$cluster_status" == "CLUSTER_NOT_READY" ]]; then
        warn "K8S集群未就绪"
        ((issues_found++))
    else
        log "K8S集群状态:"
        echo "$cluster_status"
        
        # 检查节点状态
        local not_ready_nodes=$(echo "$cluster_status" | grep -c "NotReady" || echo "0")
        if [[ "$not_ready_nodes" -gt 0 ]]; then
            warn "发现 $not_ready_nodes 个NotReady节点"
            ((issues_found++))
        fi
    fi
    
    # 诊断结果
    if [[ $issues_found -eq 0 ]]; then
        success "系统诊断完成，未发现问题"
    else
        warn "系统诊断完成，发现 $issues_found 个问题"
        echo ""
        echo -e "${YELLOW}建议的修复步骤：${NC}"
        echo -e "  ${CYAN}1.${NC} 运行菜单选项 6 - 修复Docker和K8S安装"
        echo -e "  ${CYAN}2.${NC} 运行菜单选项 7 - 修复K8S集群"
        echo -e "  ${CYAN}3.${NC} 运行菜单选项 8 - 修复网络连接"
        echo -e "  ${CYAN}4.${NC} 运行菜单选项 9 - 修复SSH配置"
        echo -e "  ${CYAN}5.${NC} 或者运行菜单选项 12 - 一键修复所有问题"
    fi
    
    return $issues_found
}

# 一键修复所有问题
fix_all_issues() {
    log "开始一键修复所有问题..."
    
    # 先诊断问题
    if ! diagnose_system; then
        log "发现问题，开始修复..."
        
        # 修复网络连接
        log "第1步：修复网络连接..."
        fix_network_connectivity
        
        # 修复SSH配置
        log "第2步：修复SSH配置..."
        fix_all_ssh_configs
        
        # 修复Docker和K8S安装
        log "第3步：修复Docker和K8S安装..."
        fix_docker_k8s
        
        # 修复K8S集群
        log "第4步：修复K8S集群..."
        fix_k8s_cluster
        
        # 再次诊断
        log "修复完成，重新诊断..."
        if ! diagnose_system; then
            warn "部分问题可能仍然存在，请检查诊断结果"
        else
            success "所有问题已修复！"
        fi
    else
        success "系统状态正常，无需修复"
    fi
}

# 强制重建整个集群
rebuild_cluster() {
    log "开始强制重建K8S集群..."
    
    read -p "警告：这将删除现有集群并重新创建。确认继续？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log "操作已取消"
        return 0
    fi
    
    local all_ips=($(get_all_ips))
    
    # 清理所有节点
    log "清理所有节点..."
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        log "清理节点 $vm_name ($ip)..."
        
        local cleanup_script='
            # 停止K8S服务
            systemctl stop kubelet 2>/dev/null || true
            
            # 重置kubeadm
            kubeadm reset -f 2>/dev/null || true
            
            # 清理配置文件
            rm -rf /etc/kubernetes/
            rm -rf /var/lib/etcd/
            rm -rf /var/lib/kubelet/
            rm -rf /etc/cni/
            rm -rf /opt/cni/
            rm -rf /var/lib/cni/
            rm -rf /run/flannel/
            
            # 清理iptables规则
            iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
            
            # 重启Docker和containerd
            systemctl restart docker containerd
            
            echo "节点清理完成"
        '
        
        execute_remote_command "$ip" "$cleanup_script"
    done
    
    # 重新部署集群
    log "重新部署K8S集群..."
    deploy_k8s
    
    success "集群重建完成"
}

# 查看系统日志
view_logs() {
    log "查看系统日志..."
    
    echo -e "${YELLOW}请选择要查看的日志类型：${NC}"
    echo -e "  ${CYAN}1.${NC} 查看所有节点的系统日志"
    echo -e "  ${CYAN}2.${NC} 查看Docker日志"
    echo -e "  ${CYAN}3.${NC} 查看Kubelet日志"
    echo -e "  ${CYAN}4.${NC} 查看K8S Pod日志"
    echo -e "  ${CYAN}5.${NC} 查看Cloud-init日志"
    echo -e "  ${CYAN}0.${NC} 返回主菜单"
    
    read -p "请选择 [0-5]: " log_choice
    
    case $log_choice in
        1)
            local all_ips=($(get_all_ips))
            for ip in "${all_ips[@]}"; do
                local vm_name=$(get_vm_name_by_ip "$ip")
                echo -e "${CYAN}=== $vm_name ($ip) 系统日志 ===${NC}"
                execute_remote_command "$ip" "journalctl -n 50 --no-pager" || true
                echo ""
            done
            ;;
        2)
            local all_ips=($(get_all_ips))
            for ip in "${all_ips[@]}"; do
                local vm_name=$(get_vm_name_by_ip "$ip")
                echo -e "${CYAN}=== $vm_name ($ip) Docker日志 ===${NC}"
                execute_remote_command "$ip" "journalctl -u docker -n 20 --no-pager" || true
                echo ""
            done
            ;;
        3)
            local all_ips=($(get_all_ips))
            for ip in "${all_ips[@]}"; do
                local vm_name=$(get_vm_name_by_ip "$ip")
                echo -e "${CYAN}=== $vm_name ($ip) Kubelet日志 ===${NC}"
                execute_remote_command "$ip" "journalctl -u kubelet -n 20 --no-pager" || true
                echo ""
            done
            ;;
        4)
            local master_ip=$(get_master_ip)
            echo -e "${CYAN}=== K8S Pod日志 ===${NC}"
            execute_remote_command "$master_ip" "kubectl get pods --all-namespaces -o wide" || true
            echo ""
            echo -e "${CYAN}=== 问题Pod详情 ===${NC}"
            execute_remote_command "$master_ip" "kubectl get pods --all-namespaces | grep -E '(Error|CrashLoopBackOff|ImagePullBackOff|Pending)'" || true
            ;;
        5)
            local all_ips=($(get_all_ips))
            for ip in "${all_ips[@]}"; do
                local vm_name=$(get_vm_name_by_ip "$ip")
                echo -e "${CYAN}=== $vm_name ($ip) Cloud-init日志 ===${NC}"
                execute_remote_command "$ip" "tail -50 /var/log/cloud-init-output.log" || true
                echo ""
            done
            ;;
        0)
            return 0
            ;;
        *)
            warn "无效选择"
            ;;
    esac
}

# 生成故障报告
generate_troubleshooting_report() {
    log "生成故障排查报告..."
    
    local report_file="/tmp/k8s-troubleshooting-report-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "K8S集群故障排查报告"
        echo "生成时间: $(date)"
        echo "脚本版本: $SCRIPT_VERSION"
        echo "========================================"
        echo ""
        
        echo "虚拟机配置："
        for vm_id in "${!VM_CONFIGS[@]}"; do
            echo "  VM $vm_id: ${VM_CONFIGS[$vm_id]}"
        done
        echo ""
        
        echo "虚拟机状态："
        for vm_id in "${!VM_CONFIGS[@]}"; do
            local vm_name=$(parse_vm_config "$vm_id" "name")
            local vm_status=$(qm status "$vm_id" 2>/dev/null || echo "ERROR")
            echo "  $vm_name (ID: $vm_id): $vm_status"
        done
        echo ""
        
        echo "SSH连接测试："
        local all_ips=($(get_all_ips))
        for ip in "${all_ips[@]}"; do
            local vm_name=$(get_vm_name_by_ip "$ip")
            if test_ssh_connection "$ip"; then
                echo "  $vm_name ($ip): SSH连接正常"
            else
                echo "  $vm_name ($ip): SSH连接失败"
            fi
        done
        echo ""
        
        echo "Docker和K8S安装状态："
        for ip in "${all_ips[@]}"; do
            local vm_name=$(get_vm_name_by_ip "$ip")
            echo "  $vm_name ($ip):"
            
            local status_output=$(execute_remote_command "$ip" "
                echo '    Docker: '$(systemctl is-active docker 2>/dev/null || echo '未安装')
                echo '    containerd: '$(systemctl is-active containerd 2>/dev/null || echo '未安装')
                echo '    kubelet: '$(systemctl is-active kubelet 2>/dev/null || echo '未安装')
                echo '    kubectl: '$(kubectl version --client 2>/dev/null | head -1 || echo '未安装')
            " 1 2>/dev/null || echo "    无法获取状态信息")
            
            echo "$status_output"
        done
        echo ""
        
        echo "K8S集群状态："
        local master_ip=$(get_master_ip)
        local cluster_info=$(execute_remote_command "$master_ip" "kubectl get nodes -o wide 2>/dev/null || echo 'K8S集群未就绪'" 1)
        echo "$cluster_info"
        echo ""
        
        echo "Pod状态："
        local pod_info=$(execute_remote_command "$master_ip" "kubectl get pods --all-namespaces 2>/dev/null || echo 'K8S集群未就绪'" 1)
        echo "$pod_info"
        echo ""
        
        echo "========================================"
        echo "报告生成完成"
        
    } > "$report_file"
    
    success "故障排查报告已生成: $report_file"
    
    # 显示报告内容
    echo -e "${YELLOW}报告内容预览：${NC}"
    head -50 "$report_file"
    echo ""
    echo -e "${CYAN}完整报告路径: $report_file${NC}"
}

# 显示快速修复手册
show_quick_fix_guide() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                     快速修复手册                             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}常见问题及解决方法：${NC}"
    echo ""
    echo -e "${GREEN}1. 虚拟机无法SSH连接${NC}"
    echo -e "   - 检查虚拟机是否正在运行"
    echo -e "   - 运行菜单选项 9 修复SSH配置"
    echo -e "   - 检查网络配置是否正确"
    echo ""
    echo -e "${GREEN}2. Docker/K8S安装失败${NC}"
    echo -e "   - 运行菜单选项 8 修复网络连接"
    echo -e "   - 运行菜单选项 6 修复Docker和K8S安装"
    echo -e "   - 检查镜像源是否可访问"
    echo ""
    echo -e "${GREEN}3. K8S集群初始化失败${NC}"
    echo -e "   - 运行菜单选项 7 修复K8S集群"
    echo -e "   - 检查master节点的Docker服务状态"
    echo -e "   - 确认所有节点时间同步"
    echo ""
    echo -e "${GREEN}4. Worker节点无法加入集群${NC}"
    echo -e "   - 检查worker节点的containerd服务状态"
    echo -e "   - 运行菜单选项 7 修复K8S集群"
    echo -e "   - 确认网络连通性"
    echo ""
    echo -e "${GREEN}5. Pod状态异常${NC}"
    echo -e "   - 运行菜单选项 15 查看系统日志"
    echo -e "   - 检查镜像拉取是否正常"
    echo -e "   - 检查节点资源是否充足"
    echo ""
    echo -e "${GREEN}6. 一键解决所有问题${NC}"
    echo -e "   - 运行菜单选项 10 系统诊断"
    echo -e "   - 运行菜单选项 12 一键修复所有问题"
    echo -e "   - 如果问题严重，运行菜单选项 13 强制重建集群"
    echo ""
    echo -e "${YELLOW}调试技巧：${NC}"
    echo -e "   - 使用菜单选项 16 生成详细的故障报告"
    echo -e "   - 使用菜单选项 15 查看具体的系统日志"
    echo -e "   - 检查 /var/log/cloud-init-output.log 了解初始化过程"
    echo ""
    echo -e "${RED}紧急情况：${NC}"
    echo -e "   - 如果系统完全无响应，使用菜单选项 14 清理所有资源"
    echo -e "   - 然后重新运行菜单选项 1 一键全自动部署"
    echo ""
}

# 性能监控
monitor_cluster_performance() {
    log "监控集群性能..."
    
    local master_ip=$(get_master_ip)
    local all_ips=($(get_all_ips))
    
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                     集群性能监控                             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 节点资源使用情况
    echo -e "${YELLOW}节点资源使用情况：${NC}"
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        echo -e "${GREEN}=== $vm_name ($ip) ===${NC}"
        
        execute_remote_command "$ip" "
            echo 'CPU使用率:'
            top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\([0-9.]*\)%* id.*/\1/' | awk '{print 100 - \$1\"%\"}'
            echo 'Memory使用情况:'
            free -h | grep '^Mem'
            echo 'Disk使用情况:'
            df -h | grep -E '^/dev/'
            echo 'Load Average:'
            uptime
        " || warn "$vm_name 无法获取性能数据"
        echo ""
    done
    
    # K8S集群资源使用
    echo -e "${YELLOW}K8S集群资源使用：${NC}"
    execute_remote_command "$master_ip" "
        echo '=== 节点资源使用 ==='
        kubectl top nodes 2>/dev/null || echo 'metrics-server未安装'
        echo ''
        echo '=== Pod资源使用 ==='
        kubectl top pods --all-namespaces 2>/dev/null || echo 'metrics-server未安装'
        echo ''
        echo '=== 集群事件 ==='
        kubectl get events --sort-by=.metadata.creationTimestamp | tail -10
    " || warn "无法获取K8S集群性能数据"
    
    echo ""
    echo -e "${CYAN}提示：如需详细监控，建议安装 metrics-server 或 Prometheus${NC}"
}

# 备份集群配置
backup_cluster_config() {
    log "备份集群配置..."
    
    local backup_dir="/tmp/k8s-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    
    local master_ip=$(get_master_ip)
    
    # 备份K8S配置
    log "备份K8S配置文件..."
    execute_remote_command "$master_ip" "
        mkdir -p /tmp/k8s-config-backup
        cp -r /etc/kubernetes /tmp/k8s-config-backup/ 2>/dev/null || true
        kubectl get all --all-namespaces -o yaml > /tmp/k8s-config-backup/all-resources.yaml 2>/dev/null || true
        kubectl get nodes -o yaml > /tmp/k8s-config-backup/nodes.yaml 2>/dev/null || true
        kubectl get configmaps --all-namespaces -o yaml > /tmp/k8s-config-backup/configmaps.yaml 2>/dev/null || true
        kubectl get secrets --all-namespaces -o yaml > /tmp/k8s-config-backup/secrets.yaml 2>/dev/null || true
        tar -czf /tmp/k8s-config-backup.tar.gz -C /tmp k8s-config-backup
    "
    
    # 下载备份文件到本地
    log "下载备份文件到本地..."
    sshpass -p "$CLOUDINIT_PASS" scp -o StrictHostKeyChecking=no \
        "$CLOUDINIT_USER@$master_ip:/tmp/k8s-config-backup.tar.gz" \
        "$backup_dir/k8s-config-backup.tar.gz" 2>/dev/null || warn "备份文件下载失败"
    
    # 备份脚本配置
    log "备份脚本配置..."
    cat > "$backup_dir/vm-configs.txt" << EOF
# K8S集群虚拟机配置备份
# 生成时间: $(date)
# 脚本版本: $SCRIPT_VERSION

VM_CONFIGS:
EOF
    
    for vm_id in "${!VM_CONFIGS[@]}"; do
        echo "VM_$vm_id=${VM_CONFIGS[$vm_id]}" >> "$backup_dir/vm-configs.txt"
    done
    
    # 备份网络配置
    cat > "$backup_dir/network-config.txt" << EOF
# 网络配置备份
BRIDGE_NAME=$BRIDGE_NAME
NETWORK_CIDR=$NETWORK_CIDR
GATEWAY=$GATEWAY
DNS_SERVERS=$DNS_SERVERS
POD_SUBNET=$POD_SUBNET
SERVICE_SUBNET=$SERVICE_SUBNET
EOF
    
    success "集群配置备份完成: $backup_dir"
    echo -e "${CYAN}备份内容：${NC}"
    echo -e "  - K8S配置文件和资源定义"
    echo -e "  - 虚拟机配置信息"
    echo -e "  - 网络配置参数"
    echo -e "  - 备份路径: $backup_dir"
}

# 安装metrics-server
install_metrics_server() {
    log "安装metrics-server..."
    
    local master_ip=$(get_master_ip)
    
    local install_script='
        echo "下载metrics-server配置..."
        wget -O metrics-server.yaml https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
        
        # 修改配置以支持不安全的TLS
        sed -i "/- --cert-dir=\/tmp/a\        - --kubelet-insecure-tls" metrics-server.yaml
        sed -i "/- --secure-port=4443/a\        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname" metrics-server.yaml
        
        # 部署metrics-server
        kubectl apply -f metrics-server.yaml
        
        echo "等待metrics-server就绪..."
        kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=300s
        
        echo "验证metrics-server..."
        kubectl top nodes
    '
    
    if execute_remote_command "$master_ip" "$install_script"; then
        success "metrics-server安装成功"
    else
        error "metrics-server安装失败"
    fi
}

# 高级配置选项
advanced_config() {
    log "高级配置选项..."
    
    echo -e "${YELLOW}请选择高级配置选项：${NC}"
    echo -e "  ${CYAN}1.${NC} 安装metrics-server（性能监控）"
    echo -e "  ${CYAN}2.${NC} 配置Ingress控制器"
    echo -e "  ${CYAN}3.${NC} 安装存储类（StorageClass）"
    echo -e "  ${CYAN}4.${NC} 配置网络策略"
    echo -e "  ${CYAN}5.${NC} 安装Helm包管理器"
    echo -e "  ${CYAN}0.${NC} 返回主菜单"
    
    read -p "请选择 [0-5]: " config_choice
    
    case $config_choice in
        1)
            install_metrics_server
            ;;
        2)
            install_ingress_controller
            ;;
        3)
            install_storage_class
            ;;
        4)
            configure_network_policy
            ;;
        5)
            install_helm
            ;;
        0)
            return 0
            ;;
        *)
            warn "无效选择"
            ;;
    esac
}

# 安装Ingress控制器
install_ingress_controller() {
    log "安装Ingress控制器..."
    
    local master_ip=$(get_master_ip)
    
    local install_script='
        echo "安装NGINX Ingress控制器..."
        kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml
        
        echo "等待Ingress控制器就绪..."
        kubectl wait --namespace ingress-nginx \
            --for=condition=ready pod \
            --selector=app.kubernetes.io/component=controller \
            --timeout=300s
        
        echo "验证Ingress控制器..."
        kubectl get pods -n ingress-nginx
    '
    
    if execute_remote_command "$master_ip" "$install_script"; then
        success "Ingress控制器安装成功"
    else
        error "Ingress控制器安装失败"
    fi
}

# 安装存储类
install_storage_class() {
    log "安装本地存储类..."
    
    local master_ip=$(get_master_ip)
    
    local install_script='
        echo "创建本地存储类..."
        cat > local-storage-class.yaml << "EOF"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF
        
        kubectl apply -f local-storage-class.yaml
        
        echo "验证存储类..."
        kubectl get storageclass
    '
    
    if execute_remote_command "$master_ip" "$install_script"; then
        success "存储类安装成功"
    else
        error "存储类安装失败"
    fi
}

# 配置网络策略
configure_network_policy() {
    log "配置网络策略..."
    
    local master_ip=$(get_master_ip)
    
    local install_script='
        echo "创建默认网络策略..."
        cat > default-network-policy.yaml << "EOF"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: default
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: default
EOF
        
        kubectl apply -f default-network-policy.yaml
        
        echo "验证网络策略..."
        kubectl get networkpolicy
    '
    
    if execute_remote_command "$master_ip" "$install_script"; then
        success "网络策略配置成功"
    else
        error "网络策略配置失败"
    fi
}

# 安装Helm
install_helm() {
    log "安装Helm包管理器..."
    
    local master_ip=$(get_master_ip)
    
    local install_script='
        echo "下载并安装Helm..."
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
        chmod 700 get_helm.sh
        ./get_helm.sh
        
        echo "验证Helm安装..."
        helm version
        
        echo "添加常用Helm仓库..."
        helm repo add stable https://charts.helm.sh/stable
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
        helm repo update
        
        echo "列出可用仓库..."
        helm repo list
    '
    
    if execute_remote_command "$master_ip" "$install_script"; then
        success "Helm安装成功"
    else
        error "Helm安装失败"
    fi
}

# 集群健康检查
cluster_health_check() {
    log "执行集群健康检查..."
    
    local master_ip=$(get_master_ip)
    local all_ips=($(get_all_ips))
    local health_score=0
    local max_score=100
    
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                     集群健康检查                             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 1. 虚拟机状态检查 (20分)
    echo -e "${YELLOW}1. 虚拟机状态检查...${NC}"
    local vm_healthy=0
    local vm_total=0
    for vm_id in "${!VM_CONFIGS[@]}"; do
        local vm_name=$(parse_vm_config "$vm_id" "name")
        local vm_status=$(qm status "$vm_id" 2>/dev/null | grep -o "status: [^,]*" | cut -d' ' -f2)
        ((vm_total++))
        
        if [[ "$vm_status" == "running" ]]; then
            echo -e "   ✓ $vm_name 运行正常"
            ((vm_healthy++))
        else
            echo -e "   ✗ $vm_name 状态异常: $vm_status"
        fi
    done
    
    local vm_score=$((vm_healthy * 20 / vm_total))
    health_score=$((health_score + vm_score))
    echo -e "   评分: $vm_score/20"
    echo ""
    
    # 2. SSH连接检查 (15分)
    echo -e "${YELLOW}2. SSH连接检查...${NC}"
    local ssh_healthy=0
    local ssh_total=0
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        ((ssh_total++))
        
        if test_ssh_connection "$ip"; then
            echo -e "   ✓ $vm_name ($ip) SSH连接正常"
            ((ssh_healthy++))
        else
            echo -e "   ✗ $vm_name ($ip) SSH连接失败"
        fi
    done
    
    local ssh_score=$((ssh_healthy * 15 / ssh_total))
    health_score=$((health_score + ssh_score))
    echo -e "   评分: $ssh_score/15"
    echo ""
    
    # 3. Docker和K8S服务检查 (25分)
    echo -e "${YELLOW}3. Docker和K8S服务检查...${NC}"
    local service_healthy=0
    local service_total=0
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        
        # 检查Docker
        ((service_total++))
        if execute_remote_command "$ip" "systemctl is-active docker" 1 >/dev/null 2>&1; then
            echo -e "   ✓ $vm_name Docker服务正常"
            ((service_healthy++))
        else
            echo -e "   ✗ $vm_name Docker服务异常"
        fi
        
        # 检查containerd
        ((service_total++))
        if execute_remote_command "$ip" "systemctl is-active containerd" 1 >/dev/null 2>&1; then
            echo -e "   ✓ $vm_name containerd服务正常"
            ((service_healthy++))
        else
            echo -e "   ✗ $vm_name containerd服务异常"
        fi
        
        # 检查kubelet
        ((service_total++))
        if execute_remote_command "$ip" "systemctl is-active kubelet" 1 >/dev/null 2>&1; then
            echo -e "   ✓ $vm_name kubelet服务正常"
            ((service_healthy++))
        else
            echo -e "   ✗ $vm_name kubelet服务异常"
        fi
    done
    
    local service_score=$((service_healthy * 25 / service_total))
    health_score=$((health_score + service_score))
    echo -e "   评分: $service_score/25"
    echo ""
    
    # 4. K8S集群状态检查 (25分)
    echo -e "${YELLOW}4. K8S集群状态检查...${NC}"
    local cluster_score=0
    
    # 检查集群连通性
    if execute_remote_command "$master_ip" "kubectl get nodes" 1 >/dev/null 2>&1; then
        echo -e "   ✓ K8S API服务器可访问"
        cluster_score=$((cluster_score + 10))
        
        # 检查节点状态
        local ready_nodes=$(execute_remote_command "$master_ip" "kubectl get nodes --no-headers | grep -c Ready" 1 2>/dev/null || echo "0")
        local total_nodes=$(execute_remote_command "$master_ip" "kubectl get nodes --no-headers | wc -l" 1 2>/dev/null || echo "0")
        
        if [[ "$ready_nodes" -eq "$total_nodes" ]] && [[ "$total_nodes" -gt 0 ]]; then
            echo -e "   ✓ 所有节点状态Ready ($ready_nodes/$total_nodes)"
            cluster_score=$((cluster_score + 15))
        else
            echo -e "   ✗ 部分节点状态异常 ($ready_nodes/$total_nodes Ready)"
            cluster_score=$((cluster_score + ready_nodes * 15 / total_nodes))
        fi
    else
        echo -e "   ✗ K8S API服务器不可访问"
    fi
    
    health_score=$((health_score + cluster_score))
    echo -e "   评分: $cluster_score/25"
    echo ""
    
    # 5. 系统资源检查 (15分)
    echo -e "${YELLOW}5. 系统资源检查...${NC}"
    local resource_score=0
    local resource_checks=0
    
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        
        # 检查内存使用率
        local mem_usage=$(execute_remote_command "$ip" "free | grep Mem | awk '{printf \"%.0f\", \$3/\$2 * 100}'" 1 2>/dev/null || echo "100")
        ((resource_checks++))
        
        if [[ "$mem_usage" -lt 80 ]]; then
            echo -e "   ✓ $vm_name 内存使用率正常 (${mem_usage}%)"
            ((resource_score += 3))
        else
            echo -e "   ⚠ $vm_name 内存使用率较高 (${mem_usage}%)"
            ((resource_score += 1))
        fi
        
        # 检查磁盘使用率
        local disk_usage=$(execute_remote_command "$ip" "df / | tail -1 | awk '{print \$5}' | sed 's/%//'" 1 2>/dev/null || echo "100")
        ((resource_checks++))
        
        if [[ "$disk_usage" -lt 80 ]]; then
            echo -e "   ✓ $vm_name 磁盘使用率正常 (${disk_usage}%)"
            ((resource_score += 2))
        else
            echo -e "   ⚠ $vm_name 磁盘使用率较高 (${disk_usage}%)"
            ((resource_score += 1))
        fi
    done
    
    # 标准化资源评分到15分
    resource_score=$((resource_score * 15 / (resource_checks * 5)))
    health_score=$((health_score + resource_score))
    echo -e "   评分: $resource_score/15"
    echo ""
    
    # 总体健康评估
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}集群健康评分: $health_score/$max_score${NC}"
    
    if [[ $health_score -ge 90 ]]; then
        echo -e "${GREEN}✓ 集群状态优秀！${NC}"
    elif [[ $health_score -ge 70 ]]; then
        echo -e "${YELLOW}⚠ 集群状态良好，但有改进空间${NC}"
    elif [[ $health_score -ge 50 ]]; then
        echo -e "${YELLOW}⚠ 集群状态一般，建议进行优化${NC}"
    else
        echo -e "${RED}✗ 集群状态较差，需要立即修复${NC}"
        echo -e "${CYAN}建议运行菜单选项 12 - 一键修复所有问题${NC}"
    fi
    
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
}

# 自动化运维
automation_ops() {
    log "自动化运维功能..."
    
    echo -e "${YELLOW}请选择自动化运维选项：${NC}"
    echo -e "  ${CYAN}1.${NC} 设置定时健康检查"
    echo -e "  ${CYAN}2.${NC} 设置定时备份"
    echo -e "  ${CYAN}3.${NC} 设置资源监控报警"
    echo -e "  ${CYAN}4.${NC} 查看定时任务状态"
    echo -e "  ${CYAN}5.${NC} 清理定时任务"
    echo -e "  ${CYAN}0.${NC} 返回主菜单"
    
    read -p "请选择 [0-5]: " auto_choice
    
    case $auto_choice in
        1)
            setup_health_check_cron
            ;;
        2)
            setup_backup_cron
            ;;
        3)
            setup_monitoring_alerts
            ;;
        4)
            show_cron_status
            ;;
        5)
            cleanup_cron_jobs
            ;;
        0)
            return 0
            ;;
        *)
            warn "无效选择"
            ;;
    esac
}

# 设置定时健康检查
setup_health_check_cron() {
    log "设置定时健康检查..."
    
    echo -e "${YELLOW}选择健康检查频率：${NC}"
    echo -e "  ${CYAN}1.${NC} 每小时检查一次"
    echo -e "  ${CYAN}2.${NC} 每4小时检查一次"
    echo -e "  ${CYAN}3.${NC} 每天检查一次"
    echo -e "  ${CYAN}4.${NC} 自定义频率"
    
    read -p "请选择 [1-4]: " freq_choice
    
    local cron_schedule=""
    case $freq_choice in
        1)
            cron_schedule="0 * * * *"
            ;;
        2)
            cron_schedule="0 */4 * * *"
            ;;
        3)
            cron_schedule="0 2 * * *"
            ;;
        4)
            read -p "请输入cron表达式（例如：0 */6 * * *）: " cron_schedule
            ;;
        *)
            warn "无效选择"
            return 1
            ;;
    esac
    
    # 创建健康检查脚本
    local health_script="/usr/local/bin/k8s-health-check.sh"
    cat > "$health_script" << 'EOF'
#!/bin/bash
# K8S集群健康检查脚本

LOGFILE="/var/log/k8s-health-check.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# 执行健康检查
log "开始集群健康检查..."
cd /root
./one-click-pve-k8s.sh 21 >> "$LOGFILE" 2>&1

# 检查结果并发送通知（如果配置了）
if [[ -f "/etc/k8s-alert-config" ]]; then
    source /etc/k8s-alert-config
    if [[ -n "$WEBHOOK_URL" ]]; then
        # 发送Webhook通知
        curl -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"K8S集群健康检查完成，详情请查看日志: $LOGFILE\"}" \
            2>/dev/null || true
    fi
fi

log "健康检查完成"
EOF
    
    chmod +x "$health_script"
    
    # 添加到crontab
    (crontab -l 2>/dev/null | grep -v "k8s-health-check"; echo "$cron_schedule $health_script") | crontab -
    
    success "定时健康检查设置完成"
    echo -e "${CYAN}检查频率: $cron_schedule${NC}"
    echo -e "${CYAN}日志文件: /var/log/k8s-health-check.log${NC}"
}

# 设置定时备份
setup_backup_cron() {
    log "设置定时备份..."
    
    echo -e "${YELLOW}选择备份频率：${NC}"
    echo -e "  ${CYAN}1.${NC} 每天备份一次"
    echo -e "  ${CYAN}2.${NC} 每周备份一次"
    echo -e "  ${CYAN}3.${NC} 每月备份一次"
    echo -e "  ${CYAN}4.${NC} 自定义频率"
    
    read -p "请选择 [1-4]: " backup_choice
    
    local cron_schedule=""
    case $backup_choice in
        1)
            cron_schedule="0 3 * * *"
            ;;
        2)
            cron_schedule="0 3 * * 0"
            ;;
        3)
            cron_schedule="0 3 1 * *"
            ;;
        4)
            read -p "请输入cron表达式: " cron_schedule
            ;;
        *)
            warn "无效选择"
            return 1
            ;;
    esac
    
    # 创建备份脚本
    local backup_script="/usr/local/bin/k8s-backup.sh"
    cat > "$backup_script" << 'EOF'
#!/bin/bash
# K8S集群备份脚本

LOGFILE="/var/log/k8s-backup.log"
BACKUP_DIR="/var/backups/k8s"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# 创建备份目录
mkdir -p "$BACKUP_DIR"

# 执行备份
log "开始集群备份..."
cd /root
./one-click-pve-k8s.sh 19 >> "$LOGFILE" 2>&1

# 清理旧备份（保留最近7个）
find "$BACKUP_DIR" -name "k8s-backup-*" -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null || true

log "备份完成"
EOF
    
    chmod +x "$backup_script"
    
    # 添加到crontab
    (crontab -l 2>/dev/null | grep -v "k8s-backup"; echo "$cron_schedule $backup_script") | crontab -
    
    success "定时备份设置完成"
    echo -e "${CYAN}备份频率: $cron_schedule${NC}"
    echo -e "${CYAN}备份目录: /var/backups/k8s${NC}"
    echo -e "${CYAN}日志文件: /var/log/k8s-backup.log${NC}"
}

# 设置监控报警
setup_monitoring_alerts() {
    log "设置监控报警..."
    
    read -p "请输入Webhook URL（用于发送报警通知）: " webhook_url
    read -p "请输入报警阈值 - CPU使用率(%) [默认: 80]: " cpu_threshold
    read -p "请输入报警阈值 - 内存使用率(%) [默认: 80]: " mem_threshold
    read -p "请输入报警阈值 - 磁盘使用率(%) [默认: 80]: " disk_threshold
    
    cpu_threshold=${cpu_threshold:-80}
    mem_threshold=${mem_threshold:-80}
    disk_threshold=${disk_threshold:-80}
    
    # 创建报警配置文件
    cat > "/etc/k8s-alert-config" << EOF
# K8S监控报警配置
WEBHOOK_URL="$webhook_url"
CPU_THRESHOLD=$cpu_threshold
MEM_THRESHOLD=$mem_threshold
DISK_THRESHOLD=$disk_threshold
EOF
    
    # 创建监控脚本
    local monitor_script="/usr/local/bin/k8s-monitor.sh"
    cat > "$monitor_script" << 'EOF'
#!/bin/bash
# K8S集群监控脚本

source /etc/k8s-alert-config

LOGFILE="/var/log/k8s-monitor.log"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# 发送报警
send_alert() {
    local message="$1"
    log "发送报警: $message"
    
    if [[ -n "$WEBHOOK_URL" ]]; then
        curl -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"🚨 K8S集群报警: $message\"}" \
            2>/dev/null || log "报警发送失败"
    fi
}

# 检查资源使用率
check_resources() {
    local all_ips=(10.0.0.10 10.0.0.11 10.0.0.12)
    
    for ip in "${all_ips[@]}"; do
        # 检查CPU使用率
        local cpu_usage=$(sshpass -p "123456" ssh -o StrictHostKeyChecking=no root@$ip \
            "top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\([0-9.]*\)%* id.*/\1/' | awk '{print 100 - \$1}'" 2>/dev/null | cut -d. -f1)
        
        if [[ "$cpu_usage" -gt "$CPU_THRESHOLD" ]]; then
            send_alert "节点 $ip CPU使用率过高: ${cpu_usage}%"
        fi
        
        # 检查内存使用率
        local mem_usage=$(sshpass -p "123456" ssh -o StrictHostKeyChecking=no root@$ip \
            "free | grep Mem | awk '{printf \"%.0f\", \$3/\$2 * 100}'" 2>/dev/null)
        
        if [[ "$mem_usage" -gt "$MEM_THRESHOLD" ]]; then
            send_alert "节点 $ip 内存使用率过高: ${mem_usage}%"
        fi
        
        # 检查磁盘使用率
        local disk_usage=$(sshpass -p "123456" ssh -o StrictHostKeyChecking=no root@$ip \
            "df / | tail -1 | awk '{print \$5}' | sed 's/%//'" 2>/dev/null)
        
        if [[ "$disk_usage" -gt "$DISK_THRESHOLD" ]]; then
            send_alert "节点 $ip 磁盘使用率过高: ${disk_usage}%"
        fi
    done
}

log "开始监控检查..."
check_resources
log "监控检查完成"
EOF
    
    chmod +x "$monitor_script"
    
    # 添加到crontab（每5分钟检查一次）
    (crontab -l 2>/dev/null | grep -v "k8s-monitor"; echo "*/5 * * * * $monitor_script") | crontab -
    
    success "监控报警设置完成"
    echo -e "${CYAN}检查频率: 每5分钟${NC}"
    echo -e "${CYAN}CPU阈值: ${cpu_threshold}%${NC}"
    echo -e "${CYAN}内存阈值: ${mem_threshold}%${NC}"
    echo -e "${CYAN}磁盘阈值: ${disk_threshold}%${NC}"
    echo -e "${CYAN}Webhook URL: $webhook_url${NC}"
}

# 查看定时任务状态
show_cron_status() {
    log "查看定时任务状态..."
    
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                     定时任务状态                             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${YELLOW}当前定时任务：${NC}"
    crontab -l 2>/dev/null | grep -E "(k8s-health-check|k8s-backup|k8s-monitor)" || echo "没有K8S相关的定时任务"
    echo ""
    
    echo -e "${YELLOW}脚本文件状态：${NC}"
    for script in "/usr/local/bin/k8s-health-check.sh" "/usr/local/bin/k8s-backup.sh" "/usr/local/bin/k8s-monitor.sh"; do
        if [[ -f "$script" ]]; then
            echo -e "  ✓ $script 存在"
        else
            echo -e "  ✗ $script 不存在"
        fi
    done
    echo ""
    
    echo -e "${YELLOW}配置文件状态：${NC}"
    if [[ -f "/etc/k8s-alert-config" ]]; then
        echo -e "  ✓ /etc/k8s-alert-config 存在"
        echo -e "  配置内容："
        cat /etc/k8s-alert-config | sed 's/^/    /'
    else
        echo -e "  ✗ /etc/k8s-alert-config 不存在"
    fi
    echo ""
    
    echo -e "${YELLOW}日志文件状态：${NC}"
    for logfile in "/var/log/k8s-health-check.log" "/var/log/k8s-backup.log" "/var/log/k8s-monitor.log"; do
        if [[ -f "$logfile" ]]; then
            local size=$(du -h "$logfile" | cut -f1)
            echo -e "  ✓ $logfile ($size)"
        else
            echo -e "  - $logfile 不存在"
        fi
    done
}

# 清理定时任务
cleanup_cron_jobs() {
    log "清理定时任务..."
    
    echo -e "${YELLOW}将清理以下内容：${NC}"
    echo -e "  - 所有K8S相关的定时任务"
    echo -e "  - 自动化脚本文件"
    echo -e "  - 配置文件"
    echo -e "  - 日志文件"
    echo ""
    
    read -p "确认清理？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 清理定时任务
        crontab -l 2>/dev/null | grep -v -E "(k8s-health-check|k8s-backup|k8s-monitor)" | crontab -
        
        # 清理脚本文件
        rm -f /usr/local/bin/k8s-health-check.sh
        rm -f /usr/local/bin/k8s-backup.sh
        rm -f /usr/local/bin/k8s-monitor.sh
        
        # 清理配置文件
        rm -f /etc/k8s-alert-config
        
        # 清理日志文件
        rm -f /var/log/k8s-health-check.log
        rm -f /var/log/k8s-backup.log
        rm -f /var/log/k8s-monitor.log
        
        success "定时任务清理完成"
    else
        log "取消清理操作"
    fi
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
    echo -e "  ${CYAN}12.${NC} 一键修复所有问题"
    echo ""
    echo -e "${BLUE}诊断功能：${NC}"
    echo -e "  ${CYAN}10.${NC} 系统诊断"
    echo -e "  ${CYAN}11.${NC} 检查集群状态"
    echo -e "  ${CYAN}21.${NC} 集群健康检查"
    echo -e "  ${CYAN}15.${NC} 查看系统日志"
    echo -e "  ${CYAN}16.${NC} 生成故障报告"
    echo -e "  ${CYAN}17.${NC} 快速修复手册"
    echo ""
    echo -e "${PURPLE}高级功能：${NC}"
    echo -e "  ${CYAN}18.${NC} 性能监控"
    echo -e "  ${CYAN}19.${NC} 备份集群配置"
    echo -e "  ${CYAN}20.${NC} 高级配置选项"
    echo -e "  ${CYAN}22.${NC} 自动化运维"
    echo ""
    echo -e "${RED}管理功能：${NC}"
    echo -e "  ${CYAN}13.${NC} 强制重建集群"
    echo -e "  ${CYAN}14.${NC} 清理所有资源"
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
        
        read -p "请选择操作 [0-22]: " choice
        
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
            10) diagnose_system ;;
            11) check_status ;;
            12) fix_all_issues ;;
            13) rebuild_cluster ;;
            14) cleanup_all ;;
            15) view_logs ;;
            16) generate_troubleshooting_report ;;
            17) show_quick_fix_guide ;;
            18) monitor_cluster_performance ;;
            19) backup_cluster_config ;;
            20) advanced_config ;;
            21) cluster_health_check ;;
            22) automation_ops ;;
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