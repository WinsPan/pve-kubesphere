#!/bin/bash

#===============================================================================
# PVE Kubernetes + KubeSphere 一键部署脚本
# 
# 功能：在PVE环境中自动创建3个Debian VM并部署最新版K8S集群和KubeSphere
# 作者：homenet
# 版本：6.0
# 日期：2025-01-03
#
# VM配置：
# - k8s-master  (101): 10.0.0.10 - 8核16G内存300G硬盘
# - k8s-worker1 (102): 10.0.0.11 - 8核16G内存300G硬盘  
# - k8s-worker2 (103): 10.0.0.12 - 8核16G内存300G硬盘
#===============================================================================

set -euo pipefail

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# 脚本配置
readonly SCRIPT_VERSION="6.0"
readonly SCRIPT_NAME="PVE K8S + KubeSphere 部署工具"
readonly WORK_DIR="/tmp/pve-k8s-deploy"
readonly LOG_FILE="$WORK_DIR/deploy.log"

# 全局变量
STORAGE=""
DETECTED_BRIDGE=""

# VM配置数组
readonly VM_IDS=(101 102 103)
readonly VM_NAMES=("k8s-master" "k8s-worker1" "k8s-worker2")
readonly VM_IPS=("10.0.0.10" "10.0.0.11" "10.0.0.12")
readonly VM_CORES=(8 8 8)
readonly VM_MEMORY=(16384 16384 16384)
readonly VM_DISK=(300 300 300)

# 网络配置
readonly GATEWAY="10.0.0.1"
readonly DNS="119.29.29.29,8.8.8.8"
readonly BRIDGE="vmbr0"
# STORAGE将在环境检查时自动检测

# 认证配置
readonly VM_USER="root"
readonly VM_PASS="kubesphere123"

# K8S版本配置（使用最新稳定版）
readonly K8S_VERSION="v1.29.0"
readonly CONTAINERD_VERSION="1.7.12"
readonly RUNC_VERSION="v1.1.10"
readonly CNI_VERSION="v1.4.0"
readonly KUBESPHERE_VERSION="v3.4.1"

# GitHub镜像源
readonly GITHUB_MIRRORS=(
    "https://ghproxy.com/https://github.com"
    "https://mirror.ghproxy.com/https://github.com"
    "https://github.com"
)

#===============================================================================
# 工具函数
#===============================================================================

# 日志函数
log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"
}

warn() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN:${NC} $*" | tee -a "$LOG_FILE"
}

error() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" | tee -a "$LOG_FILE"
}

success() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo -e "${GREEN}[$(date '+%H:%M:%S')] SUCCESS:${NC} $*" | tee -a "$LOG_FILE"
}

# 根据VM ID获取索引
get_vm_index() {
    local vm_id="$1"
    for i in "${!VM_IDS[@]}"; do
        if [[ "${VM_IDS[$i]}" == "$vm_id" ]]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

# 根据IP获取VM ID
get_vm_id_by_ip() {
    local target_ip="$1"
    for i in "${!VM_IPS[@]}"; do
        if [[ "${VM_IPS[$i]}" == "$target_ip" ]]; then
            echo "${VM_IDS[$i]}"
            return 0
        fi
    done
    return 1
}

# 执行远程命令
execute_remote_command() {
    local ip="$1"
    local command="$2"
    local timeout="${3:-30}"
    
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout="$timeout" \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$VM_USER@$ip" "$command"
}

# 测试SSH连接
test_ssh_connection() {
    local ip="$1"
    local max_attempts="${2:-60}"
    
    log "等待 $ip SSH连接就绪..."
    
    for ((i=1; i<=max_attempts; i++)); do
        if execute_remote_command "$ip" "echo 'SSH连接成功'" 5 >/dev/null 2>&1; then
            success "$ip SSH连接就绪"
            return 0
        fi
        
        if ((i % 10 == 0)); then
            log "等待 $ip SSH连接... ($i/$max_attempts)"
        fi
        
        sleep 5
    done
    
    error "$ip SSH连接超时"
    return 1
}

# 下载文件（支持GitHub镜像）
download_with_retry() {
    local url="$1"
    local output="$2"
    local description="${3:-文件}"
    
    log "下载 $description..."
    
    # 如果是GitHub URL，尝试镜像源
    if [[ "$url" == *"github.com"* ]]; then
        for mirror in "${GITHUB_MIRRORS[@]}"; do
            local mirror_url="${url/https:\/\/github.com/$mirror}"
            log "尝试镜像源: $mirror"
            
            if curl -fsSL --connect-timeout 10 --max-time 300 "$mirror_url" -o "$output"; then
                success "$description 下载成功"
                return 0
            fi
            
            warn "镜像源失败: $mirror"
        done
    else
        if curl -fsSL --connect-timeout 10 --max-time 300 "$url" -o "$output"; then
            success "$description 下载成功"
            return 0
        fi
    fi
    
    error "$description 下载失败"
    return 1
}

#===============================================================================
# 环境检查和自动检测
#===============================================================================

# 检测可用存储
detect_storage() {
    # 如果已经手动指定存储，验证其可用性
    if [[ -n "$STORAGE" ]]; then
        log "验证指定存储: $STORAGE"
        if ! pvesm status "$STORAGE" >/dev/null 2>&1; then
            error "指定的存储 $STORAGE 不可用"
            log "可用存储列表："
            pvesm status | grep -E "(dir|lvm|zfs)" | grep -v "^Storage"
            exit 1
        fi
        success "使用指定存储: $STORAGE"
        return 0
    fi
    
    log "自动检测可用存储..."
    
    # 获取所有可用存储
    local storages=($(pvesm status | grep -E "(dir|lvm|zfs)" | grep -v "^Storage" | awk '{print $1}'))
    
    if [[ ${#storages[@]} -eq 0 ]]; then
        error "未找到可用存储"
        log "请检查PVE存储配置"
        exit 1
    fi
    
    log "发现可用存储: ${storages[*]}"
    
    # 优先选择顺序：local-lvm > local-zfs > local > 其他
    local preferred_storages=("local-lvm" "local-zfs" "local")
    
    for preferred in "${preferred_storages[@]}"; do
        for storage in "${storages[@]}"; do
            if [[ "$storage" == "$preferred" ]]; then
                STORAGE="$storage"
                success "自动选择存储: $STORAGE"
                return 0
            fi
        done
    done
    
    # 如果没有找到首选存储，使用第一个可用的
    STORAGE="${storages[0]}"
    success "使用存储: $STORAGE"
    
    # 验证存储可用性
    if ! pvesm status "$STORAGE" >/dev/null 2>&1; then
        error "存储 $STORAGE 不可用"
        exit 1
    fi
}

# 检测网络桥接
detect_bridge() {
    log "检测网络桥接..."
    
    # 获取所有网络桥接
    local bridges=($(ip link show | grep -E "^[0-9]+: vmbr" | awk -F': ' '{print $2}'))
    
    if [[ ${#bridges[@]} -eq 0 ]]; then
        warn "未检测到vmbr桥接，尝试检测其他网络接口..."
        bridges=($(ip link show | grep -E "^[0-9]+: (br|bridge)" | awk -F': ' '{print $2}'))
    fi
    
    if [[ ${#bridges[@]} -eq 0 ]]; then
        warn "未检测到网络桥接，使用默认值: vmbr0"
        DETECTED_BRIDGE="vmbr0"
    else
        # 优先使用vmbr0，否则使用第一个找到的
        for bridge in "${bridges[@]}"; do
            if [[ "$bridge" == "vmbr0" ]]; then
                DETECTED_BRIDGE="vmbr0"
                break
            fi
        done
        
        if [[ -z "$DETECTED_BRIDGE" ]]; then
            DETECTED_BRIDGE="${bridges[0]}"
        fi
    fi
    
    success "检测到网络桥接: $DETECTED_BRIDGE"
}

#===============================================================================
# 环境检查
#===============================================================================

check_environment() {
    log "检查运行环境..."
    
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要root权限运行"
        exit 1
    fi
    
    # 检查PVE环境
    if ! command -v qm >/dev/null 2>&1; then
        error "未检测到PVE环境，请在PVE主机上运行此脚本"
        exit 1
    fi
    
    # 检查必要命令并安装
    local required_commands=("curl" "sshpass" "ssh" "qm" "tar" "gzip")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log "安装缺失命令: $cmd"
            apt-get update -qq && apt-get install -y "$cmd" >/dev/null 2>&1
        fi
    done
    
    # 创建工作目录
    mkdir -p "$WORK_DIR"
    
    # 自动检测可用存储
    detect_storage
    
    # 自动检测网络桥接
    detect_bridge
    
    # 显示检测结果
    log "环境配置信息："
    log "  存储: $STORAGE"
    log "  网络桥接: ${DETECTED_BRIDGE:-$BRIDGE}"
    log "  网关: $GATEWAY"
    log "  DNS: $DNS"
    
    success "环境检查完成"
}

#===============================================================================
# 云镜像下载
#===============================================================================

download_debian_image() {
    local image_url="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
    local image_path="/var/lib/vz/template/iso/debian-12-generic-amd64.qcow2"
    local temp_file="${image_path}.tmp"
    
    # 信号处理函数
    cleanup_download() {
        log ""
        warn "下载被中断，正在清理临时文件..."
        rm -f "$temp_file"
        exit 1
    }
    
    # 设置信号处理
    trap cleanup_download INT TERM
    
    if [[ -f "$image_path" ]]; then
        log "Debian云镜像已存在: $image_path"
        local file_size=$(du -h "$image_path" | cut -f1)
        log "文件大小: $file_size"
        return 0
    fi
    
    log "下载Debian 12云镜像..."
    log "镜像URL: $image_url"
    log "保存路径: $image_path"
    mkdir -p "$(dirname "$image_path")"
    
    # 检查网络连接
    log "检查网络连接..."
    if ! curl -s --connect-timeout 10 --max-time 10 -I "https://cloud.debian.org" >/dev/null 2>&1; then
        error "无法连接到Debian官方镜像站点"
        log "请检查网络连接或防火墙设置"
        return 1
    fi
    
    # 检查磁盘空间
    local available_space=$(df "$(dirname "$image_path")" | awk 'NR==2 {print $4}')
    local required_space=524288  # 512MB in KB
    if [[ $available_space -lt $required_space ]]; then
        error "磁盘空间不足，需要至少512MB空间"
        log "可用空间: $(($available_space / 1024))MB"
        return 1
    fi
    log "磁盘空间检查通过: $(($available_space / 1024))MB 可用"
    
    # 显示下载进度
    log "开始下载，请耐心等待..."
    log "提示: 镜像文件约500MB，根据网速可能需要几分钟到十几分钟"
    
    # 记录开始时间
    local start_time=$(date +%s)
    
    # 使用wget显示进度，如果失败则使用curl
    if command -v wget >/dev/null 2>&1; then
        log "使用wget下载（显示进度）..."
        log "按 Ctrl+C 可以取消下载"
        
        # 使用已定义的临时文件
        
        if timeout 3600 wget --timeout=60 --tries=3 --progress=bar:force "$image_url" -O "$temp_file" 2>&1; then
            # 下载成功，移动到最终位置
            mv "$temp_file" "$image_path"
            success "Debian云镜像下载完成"
            local file_size=$(du -h "$image_path" | cut -f1)
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            log "文件大小: $file_size"
            log "下载耗时: ${duration}秒"
            # 清理信号处理
            trap - INT TERM
            return 0
        else
            # 清理临时文件
            rm -f "$temp_file"
            warn "wget下载失败，尝试使用curl..."
        fi
    fi
    
    # 备用下载方法：curl with progress
    log "使用curl下载..."
    log "按 Ctrl+C 可以取消下载"
    
    if curl -L --connect-timeout 30 --max-time 3600 \
            --progress-bar \
            --retry 3 \
            --retry-delay 5 \
            "$image_url" -o "$temp_file"; then
        # 下载成功，移动到最终位置
        mv "$temp_file" "$image_path"
        success "Debian云镜像下载完成"
        local file_size=$(du -h "$image_path" | cut -f1)
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log "文件大小: $file_size"
        log "下载耗时: ${duration}秒"
        # 清理信号处理
        trap - INT TERM
        return 0
    else
        # 清理临时文件
        rm -f "$temp_file"
        # 清理信号处理
        trap - INT TERM
        error "Debian云镜像下载失败"
        log "请检查网络连接或手动下载镜像到: $image_path"
        log ""
        log "手动下载命令："
        log "wget $image_url -O $image_path"
        log "或者："
        log "curl -L $image_url -o $image_path"
        log ""
        log "如果网络较慢，可以尝试使用国内镜像源："
        log "wget https://mirrors.aliyun.com/debian-cd/current/amd64/iso-cd/debian-12.8.0-amd64-netinst.iso -O /var/lib/vz/template/iso/debian-12-netinst.iso"
        return 1
    fi
}

#===============================================================================
# VM创建和配置
#===============================================================================

create_cloud_init_config() {
    local vm_index="$1"
    local vm_id="${VM_IDS[$vm_index]}"
    local vm_name="${VM_NAMES[$vm_index]}"
    local vm_ip="${VM_IPS[$vm_index]}"
    local config_file="/var/lib/vz/snippets/user-data-$vm_id.yml"
    
    log "创建VM $vm_id ($vm_name) 的cloud-init配置..."
    
    mkdir -p "$(dirname "$config_file")"
    
    cat > "$config_file" << EOF
#cloud-config
hostname: $vm_name
manage_etc_hosts: true

users:
  - name: root
    lock_passwd: false
    shell: /bin/bash

chpasswd:
  list: |
    root:$VM_PASS
  expire: False

ssh_pwauth: True
disable_root: false

network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses:
        - $vm_ip/24
      gateway4: $GATEWAY
      nameservers:
        addresses: [119.29.29.29, 8.8.8.8]

package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - apt-transport-https
  - ca-certificates
  - gnupg
  - lsb-release
  - software-properties-common
  - socat
  - conntrack

runcmd:
  # 配置时区
  - timedatectl set-timezone Asia/Shanghai
  
  # 禁用swap
  - swapoff -a
  - sed -i '/swap/d' /etc/fstab
  
  # 加载内核模块
  - modprobe overlay
  - modprobe br_netfilter
  - echo 'overlay' >> /etc/modules-load.d/k8s.conf
  - echo 'br_netfilter' >> /etc/modules-load.d/k8s.conf
  
  # 配置内核参数
  - |
    cat > /etc/sysctl.d/k8s.conf << 'SYSCTL_EOF'
    net.bridge.bridge-nf-call-iptables = 1
    net.bridge.bridge-nf-call-ip6tables = 1
    net.ipv4.ip_forward = 1
    SYSCTL_EOF
  - sysctl --system
  
  # 配置SSH
  - |
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
    systemctl restart ssh
  
  # 网络连接测试
  - ping -c 3 8.8.8.8 || echo "网络连接可能有问题"

final_message: "Cloud-init 配置完成，系统已就绪"
EOF

    success "VM $vm_id cloud-init配置创建完成"
}

create_vm() {
    local vm_index="$1"
    local vm_id="${VM_IDS[$vm_index]}"
    local vm_name="${VM_NAMES[$vm_index]}"
    local vm_ip="${VM_IPS[$vm_index]}"
    local vm_cores="${VM_CORES[$vm_index]}"
    local vm_memory="${VM_MEMORY[$vm_index]}"
    local vm_disk="${VM_DISK[$vm_index]}"
    
    log "创建虚拟机: $vm_name (ID: $vm_id, IP: $vm_ip)"
    
    # 删除已存在的VM
    if qm status "$vm_id" >/dev/null 2>&1; then
        log "删除已存在的VM $vm_id"
        qm stop "$vm_id" >/dev/null 2>&1 || true
        sleep 2
        qm destroy "$vm_id" >/dev/null 2>&1 || true
    fi
    
    # 根据存储类型确定磁盘格式和镜像路径
    local disk_format="qcow2"
    local image_path="/var/lib/vz/template/iso/debian-12-generic-amd64.qcow2"
    
    if [[ "$STORAGE" == *"lvm"* ]]; then
        disk_format="raw"
        log "检测到LVM存储，将使用raw格式"
        
        # 检查是否需要转换镜像
        local raw_image_path="/var/lib/vz/template/iso/debian-12-generic-amd64.raw"
        if [[ ! -f "$raw_image_path" ]]; then
            log "转换qcow2镜像为raw格式..."
            
            # 确保qemu-img可用
            if ! command -v qemu-img >/dev/null 2>&1; then
                log "安装qemu-utils..."
                apt-get update >/dev/null 2>&1 && apt-get install -y qemu-utils >/dev/null 2>&1
            fi
            
            # 转换镜像格式
            if qemu-img convert -f qcow2 -O raw "$image_path" "$raw_image_path"; then
                success "镜像格式转换完成"
            else
                error "镜像格式转换失败"
                return 1
            fi
        fi
        image_path="$raw_image_path"
    fi
    
    log "使用存储: $STORAGE, 磁盘格式: $disk_format"

    # 创建VM - 恢复原来简单有效的方式，在创建时就配置所有参数
    if qm create "$vm_id" \
        --name "$vm_name" \
        --cores "$vm_cores" \
        --memory "$vm_memory" \
        --net0 "virtio,bridge=${DETECTED_BRIDGE:-$BRIDGE}" \
        --scsihw virtio-scsi-pci \
        --ide2 "$STORAGE:cloudinit" \
        --serial0 socket \
        --vga std \
        --ipconfig0 "ip=$vm_ip/24,gw=$GATEWAY" \
        --nameserver "$DNS" \
        --ciuser "$CLOUDINIT_USER" \
        --cipassword "$CLOUDINIT_PASS" \
        --cicustom "user=local:snippets/user-data-$vm_id.yml" \
        --agent enabled=1; then
        
        log "VM创建成功，开始导入磁盘..."
        
        # 导入云镜像 - 使用原来的简单方式
        if qm importdisk "$vm_id" "$image_path" "$STORAGE" --format "$disk_format" >/dev/null 2>&1; then
            log "磁盘导入成功，设置为主磁盘..."
            
            # 设置主磁盘 - 使用原来的简单方式
            if qm set "$vm_id" --scsi0 "$STORAGE:vm-$vm_id-disk-0"; then
                log "设置启动磁盘..."
                qm set "$vm_id" --boot c --bootdisk scsi0
                
                # 调整磁盘大小
                log "调整磁盘大小到 ${vm_disk}G..."
                qm resize "$vm_id" scsi0 "${vm_disk}G" >/dev/null 2>&1 || {
                    warn "调整磁盘大小失败，继续使用默认大小"
                }
                
                # 启动虚拟机
                log "启动VM $vm_id..."
                if qm start "$vm_id"; then
                    success "虚拟机 $vm_name 创建并启动完成"
                    return 0
                else
                    error "启动VM失败"
                fi
            else
                error "设置主磁盘失败"
            fi
        else
            error "导入磁盘失败"
        fi
    else
        error "创建VM失败"
    fi
    
    # 如果到这里说明失败了，清理VM
    log "清理失败的VM..."
    qm destroy "$vm_id" >/dev/null 2>&1 || true
    return 1
}

create_all_vms() {
    log "开始创建所有虚拟机..."
    
    # 下载Debian云镜像
    download_debian_image
    
    # 创建所有VM
    for i in "${!VM_IDS[@]}"; do
        create_cloud_init_config "$i"
        create_vm "$i"
    done
    
    # 等待所有VM启动
    log "等待所有虚拟机启动..."
    sleep 60
    
    # 测试SSH连接
    for ip in "${VM_IPS[@]}"; do
        test_ssh_connection "$ip"
    done
    
    success "所有虚拟机创建完成并就绪"
}

#===============================================================================
# 容器运行时安装（从GitHub源码）
#===============================================================================

install_containerd() {
    local ip="$1"
    local vm_id=$(get_vm_id_by_ip "$ip")
    local vm_index=$(get_vm_index "$vm_id")
    local vm_name="${VM_NAMES[$vm_index]}"
    
    log "在 $vm_name ($ip) 安装containerd..."
    
    execute_remote_command "$ip" "
        set -e
        
        # 下载containerd
        cd /tmp
        curl -fsSL https://github.com/containerd/containerd/releases/download/v$CONTAINERD_VERSION/containerd-$CONTAINERD_VERSION-linux-amd64.tar.gz -o containerd.tar.gz
        tar Cxzvf /usr/local containerd.tar.gz
        
        # 下载runc
        curl -fsSL https://github.com/opencontainers/runc/releases/download/$RUNC_VERSION/runc.amd64 -o runc
        install -m 755 runc /usr/local/sbin/runc
        
        # 下载CNI插件
        mkdir -p /opt/cni/bin
        curl -fsSL https://github.com/containernetworking/plugins/releases/download/$CNI_VERSION/cni-plugins-linux-amd64-$CNI_VERSION.tgz -o cni-plugins.tgz
        tar Cxzvf /opt/cni/bin cni-plugins.tgz
        
        # 创建containerd配置
        mkdir -p /etc/containerd
        containerd config default > /etc/containerd/config.toml
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        
        # 创建systemd服务
        cat > /etc/systemd/system/containerd.service << 'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd

Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
        
        # 启动containerd
        systemctl daemon-reload
        systemctl enable containerd
        systemctl start containerd
        
        echo 'containerd安装完成'
    " 60
    
    success "$vm_name containerd安装完成"
}

#===============================================================================
# Kubernetes安装（从GitHub源码）
#===============================================================================

install_kubernetes() {
    local ip="$1"
    local vm_id=$(get_vm_id_by_ip "$ip")
    local vm_index=$(get_vm_index "$vm_id")
    local vm_name="${VM_NAMES[$vm_index]}"
    
    log "在 $vm_name ($ip) 安装Kubernetes..."
    
    execute_remote_command "$ip" "
        set -e
        
        # 下载K8S二进制文件
        cd /tmp
        
        # 下载kubectl
        curl -fsSL https://github.com/kubernetes/kubernetes/releases/download/$K8S_VERSION/kubernetes-client-linux-amd64.tar.gz -o kubectl.tar.gz
        tar -xzf kubectl.tar.gz
        install -o root -g root -m 0755 kubernetes/client/bin/kubectl /usr/local/bin/kubectl
        
        # 下载kubeadm和kubelet
        curl -fsSL https://github.com/kubernetes/kubernetes/releases/download/$K8S_VERSION/kubernetes-server-linux-amd64.tar.gz -o k8s-server.tar.gz
        tar -xzf k8s-server.tar.gz
        install -o root -g root -m 0755 kubernetes/server/bin/kubeadm /usr/local/bin/kubeadm
        install -o root -g root -m 0755 kubernetes/server/bin/kubelet /usr/local/bin/kubelet
        
        # 创建kubelet systemd服务
        cat > /etc/systemd/system/kubelet.service << 'EOF'
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/home/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        
        # 创建kubelet配置目录
        mkdir -p /etc/systemd/system/kubelet.service.d
        cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf << 'EOF'
[Service]
Environment=\"KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf\"
Environment=\"KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml\"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet \\\$KUBELET_KUBECONFIG_ARGS \\\$KUBELET_CONFIG_ARGS \\\$KUBELET_KUBEADM_ARGS \\\$KUBELET_EXTRA_ARGS
EOF
        
        # 启用kubelet
        systemctl daemon-reload
        systemctl enable kubelet
        
        echo 'Kubernetes安装完成'
    " 120
    
    success "$vm_name Kubernetes安装完成"
}

#===============================================================================
# K8S集群部署
#===============================================================================

install_all_nodes() {
    log "在所有节点安装容器运行时和Kubernetes..."
    
    # 并行安装containerd和kubernetes
    for ip in "${VM_IPS[@]}"; do
        {
            install_containerd "$ip"
            install_kubernetes "$ip"
        } &
    done
    
    wait
    success "所有节点安装完成"
}

init_master_node() {
    local master_ip="${VM_IPS[0]}"
    
    log "初始化Master节点..."
    
    execute_remote_command "$master_ip" "
        set -e
        
        # 初始化集群
        kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=$master_ip --kubernetes-version=$K8S_VERSION
        
        # 配置kubectl
        mkdir -p /root/.kube
        cp -i /etc/kubernetes/admin.conf /root/.kube/config
        chown root:root /root/.kube/config
        
        # 安装Flannel网络插件
        kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
        
        echo 'Master节点初始化完成'
    " 300
    
    success "Master节点初始化完成"
}

join_worker_nodes() {
    local master_ip="${VM_IPS[0]}"
    
    log "获取worker节点加入命令..."
    
    local join_command=$(execute_remote_command "$master_ip" "kubeadm token create --print-join-command" 30)
    
    log "Worker节点加入集群..."
    
    # 跳过master节点，从索引1开始
    for i in $(seq 1 $((${#VM_IPS[@]} - 1))); do
        local worker_ip="${VM_IPS[$i]}"
        local worker_name="${VM_NAMES[$i]}"
        
        log "加入worker节点: $worker_name ($worker_ip)"
        
        execute_remote_command "$worker_ip" "$join_command" 120
        
        success "$worker_name 加入集群完成"
    done
    
    success "所有Worker节点加入完成"
}

deploy_kubernetes() {
    log "开始部署Kubernetes集群..."
    
    # 安装所有节点
    install_all_nodes
    
    # 初始化Master节点
    init_master_node
    
    # Worker节点加入集群
    join_worker_nodes
    
    # 等待所有节点就绪
    local master_ip="${VM_IPS[0]}"
    log "等待所有节点就绪..."
    
    for ((i=1; i<=60; i++)); do
        local ready_nodes=$(execute_remote_command "$master_ip" "kubectl get nodes --no-headers | grep -c Ready" 10 || echo "0")
        local total_nodes=${#VM_IPS[@]}
        
        if [[ "$ready_nodes" == "$total_nodes" ]]; then
            success "所有节点已就绪 ($ready_nodes/$total_nodes)"
            break
        fi
        
        if ((i % 10 == 0)); then
            log "等待节点就绪... ($ready_nodes/$total_nodes) - $i/60"
        fi
        
        sleep 10
    done
    
    success "Kubernetes集群部署完成"
}

#===============================================================================
# KubeSphere部署
#===============================================================================

deploy_kubesphere() {
    local master_ip="${VM_IPS[0]}"
    
    log "开始部署KubeSphere..."
    
    execute_remote_command "$master_ip" "
        set -e
        
        # 下载KubeSphere安装器
        curl -fsSL https://github.com/kubesphere/ks-installer/releases/download/$KUBESPHERE_VERSION/kubesphere-installer.yaml -o kubesphere-installer.yaml
        curl -fsSL https://github.com/kubesphere/ks-installer/releases/download/$KUBESPHERE_VERSION/cluster-configuration.yaml -o cluster-configuration.yaml
        
        # 应用KubeSphere
        kubectl apply -f kubesphere-installer.yaml
        kubectl apply -f cluster-configuration.yaml
        
        echo 'KubeSphere部署开始，请等待安装完成...'
    " 180
    
    log "KubeSphere部署已启动，正在安装中..."
    log "您可以通过以下命令查看安装进度："
    log "kubectl logs -n kubesphere-system \$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath='{.items[0].metadata.name}') -f"
    
    success "KubeSphere部署完成"
}

#===============================================================================
# 修复和诊断功能
#===============================================================================

# 诊断VM状态
diagnose_vm_status() {
    log "诊断VM状态..."
    
    for i in "${!VM_IDS[@]}"; do
        local vm_id="${VM_IDS[$i]}"
        local vm_name="${VM_NAMES[$i]}"
        local vm_ip="${VM_IPS[$i]}"
        
        echo -e "${YELLOW}检查VM: $vm_name (ID: $vm_id)${NC}"
        
        # 检查VM是否存在
        if ! qm status "$vm_id" >/dev/null 2>&1; then
            warn "VM $vm_id 不存在"
            continue
        fi
        
        # 检查VM运行状态
        local vm_status=$(qm status "$vm_id" | grep -o "status: [^,]*" | cut -d' ' -f2)
        echo "  状态: $vm_status"
        
        # 检查网络连接
        if [[ "$vm_status" == "running" ]]; then
            if ping -c 1 -W 3 "$vm_ip" >/dev/null 2>&1; then
                echo "  网络: ✅ 可达"
            else
                echo "  网络: ❌ 不可达"
            fi
            
            # 检查SSH连接
            if execute_remote_command "$vm_ip" "echo 'SSH测试'" 5 >/dev/null 2>&1; then
                echo "  SSH: ✅ 可连接"
            else
                echo "  SSH: ❌ 连接失败"
            fi
        else
            echo "  网络: ⏸️  VM未运行"
            echo "  SSH: ⏸️  VM未运行"
        fi
        echo ""
    done
}

# 修复VM网络问题
fix_vm_network() {
    log "修复VM网络问题..."
    
    for i in "${!VM_IDS[@]}"; do
        local vm_id="${VM_IDS[$i]}"
        local vm_name="${VM_NAMES[$i]}"
        local vm_ip="${VM_IPS[$i]}"
        
        if ! qm status "$vm_id" >/dev/null 2>&1; then
            warn "VM $vm_id 不存在，跳过"
            continue
        fi
        
        local vm_status=$(qm status "$vm_id" | grep -o "status: [^,]*" | cut -d' ' -f2)
        if [[ "$vm_status" != "running" ]]; then
            log "启动VM: $vm_name"
            qm start "$vm_id"
            sleep 10
        fi
        
        # 等待网络就绪
        log "等待 $vm_name 网络就绪..."
        for ((j=1; j<=30; j++)); do
            if ping -c 1 -W 3 "$vm_ip" >/dev/null 2>&1; then
                success "$vm_name 网络已就绪"
                break
            fi
            sleep 5
        done
        
        # 修复网络配置
        if execute_remote_command "$vm_ip" "echo 'SSH连接测试'" 5 >/dev/null 2>&1; then
            execute_remote_command "$vm_ip" "
                # 重启网络服务
                systemctl restart networking
                systemctl restart systemd-networkd
                
                # 刷新网络配置
                netplan apply 2>/dev/null || true
                
                # 检查网络接口
                ip addr show
            " 30 || warn "$vm_name 网络修复命令执行失败"
        fi
    done
}

# 修复SSH连接问题
fix_ssh_connection() {
    log "修复SSH连接问题..."
    
    for i in "${!VM_IDS[@]}"; do
        local vm_id="${VM_IDS[$i]}"
        local vm_name="${VM_NAMES[$i]}"
        local vm_ip="${VM_IPS[$i]}"
        
        if ! ping -c 1 -W 3 "$vm_ip" >/dev/null 2>&1; then
            warn "$vm_name 网络不可达，跳过SSH修复"
            continue
        fi
        
        log "修复 $vm_name SSH配置..."
        
        # 尝试修复SSH配置
        if execute_remote_command "$vm_ip" "echo 'SSH连接测试'" 5 >/dev/null 2>&1; then
            execute_remote_command "$vm_ip" "
                # 修复SSH配置
                sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
                sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
                sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
                
                # 重启SSH服务
                systemctl restart ssh
                systemctl restart sshd
                
                # 检查SSH状态
                systemctl status ssh --no-pager -l
            " 30 || warn "$vm_name SSH修复命令执行失败"
        else
            warn "$vm_name SSH连接失败，无法修复"
        fi
    done
}

# 修复容器运行时问题
fix_container_runtime() {
    log "修复容器运行时问题..."
    
    for ip in "${VM_IPS[@]}"; do
        local vm_id=$(get_vm_id_by_ip "$ip")
        local vm_index=$(get_vm_index "$vm_id")
        local vm_name="${VM_NAMES[$vm_index]}"
        
        if ! execute_remote_command "$ip" "echo 'SSH连接测试'" 5 >/dev/null 2>&1; then
            warn "$vm_name SSH连接失败，跳过容器运行时修复"
            continue
        fi
        
        log "修复 $vm_name 容器运行时..."
        
        execute_remote_command "$ip" "
            # 检查containerd状态
            if ! systemctl is-active containerd >/dev/null 2>&1; then
                echo '重启containerd服务...'
                systemctl restart containerd
                sleep 5
            fi
            
            # 检查containerd配置
            if [[ ! -f /etc/containerd/config.toml ]]; then
                echo '重新生成containerd配置...'
                mkdir -p /etc/containerd
                containerd config default > /etc/containerd/config.toml
                sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
                systemctl restart containerd
            fi
            
            # 检查容器运行时
            if ! ctr version >/dev/null 2>&1; then
                echo '容器运行时异常，尝试重新安装...'
                systemctl stop containerd
                sleep 2
                systemctl start containerd
            fi
            
            # 显示状态
            systemctl status containerd --no-pager -l
        " 60 || warn "$vm_name 容器运行时修复失败"
    done
}

# 修复K8S集群问题
fix_kubernetes_cluster() {
    local master_ip="${VM_IPS[0]}"
    
    log "修复Kubernetes集群问题..."
    
    # 检查master节点
    if ! execute_remote_command "$master_ip" "echo 'SSH连接测试'" 5 >/dev/null 2>&1; then
        error "Master节点SSH连接失败，无法修复集群"
        return 1
    fi
    
    log "修复Master节点..."
    execute_remote_command "$master_ip" "
        # 重启kubelet
        systemctl restart kubelet
        
        # 检查集群状态
        if ! kubectl get nodes >/dev/null 2>&1; then
            echo '集群API异常，尝试重启kube-apiserver...'
            systemctl restart kubelet
            sleep 10
        fi
        
        # 检查系统Pod
        kubectl get pods -n kube-system
        
        # 重启有问题的Pod
        kubectl get pods -n kube-system | grep -E '(Error|CrashLoopBackOff|ImagePullBackOff)' | awk '{print \$1}' | while read pod; do
            if [[ -n \"\$pod\" ]]; then
                echo \"重启异常Pod: \$pod\"
                kubectl delete pod \"\$pod\" -n kube-system
            fi
        done
    " 120 || warn "Master节点修复失败"
    
    # 修复Worker节点
    for i in $(seq 1 $((${#VM_IPS[@]} - 1))); do
        local worker_ip="${VM_IPS[$i]}"
        local worker_name="${VM_NAMES[$i]}"
        
        if ! execute_remote_command "$worker_ip" "echo 'SSH连接测试'" 5 >/dev/null 2>&1; then
            warn "$worker_name SSH连接失败，跳过"
            continue
        fi
        
        log "修复Worker节点: $worker_name"
        execute_remote_command "$worker_ip" "
            # 重启kubelet
            systemctl restart kubelet
            
            # 检查节点状态
            systemctl status kubelet --no-pager -l
        " 60 || warn "$worker_name 修复失败"
    done
    
    # 检查集群整体状态
    log "检查集群修复结果..."
    execute_remote_command "$master_ip" "
        kubectl get nodes
        kubectl get pods -n kube-system
    " 30 || warn "无法获取集群状态"
}

# 修复KubeSphere问题
fix_kubesphere() {
    local master_ip="${VM_IPS[0]}"
    
    log "修复KubeSphere问题..."
    
    if ! execute_remote_command "$master_ip" "echo 'SSH连接测试'" 5 >/dev/null 2>&1; then
        error "Master节点SSH连接失败，无法修复KubeSphere"
        return 1
    fi
    
    execute_remote_command "$master_ip" "
        # 检查KubeSphere命名空间
        if ! kubectl get namespace kubesphere-system >/dev/null 2>&1; then
            echo 'KubeSphere命名空间不存在，可能未安装'
            exit 1
        fi
        
        # 检查KubeSphere Pod状态
        kubectl get pods -n kubesphere-system
        
        # 重启有问题的Pod
        kubectl get pods -n kubesphere-system | grep -E '(Error|CrashLoopBackOff|ImagePullBackOff)' | awk '{print \$1}' | while read pod; do
            if [[ -n \"\$pod\" ]]; then
                echo \"重启异常Pod: \$pod\"
                kubectl delete pod \"\$pod\" -n kubesphere-system
            fi
        done
        
        # 检查KubeSphere安装状态
        if kubectl get pod -n kubesphere-system -l app=ks-install >/dev/null 2>&1; then
            echo 'KubeSphere安装器状态:'
            kubectl logs -n kubesphere-system \$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath='{.items[0].metadata.name}') --tail=20
        fi
    " 120 || warn "KubeSphere修复失败"
}

# 重置单个节点
reset_node() {
    local ip="$1"
    local vm_id=$(get_vm_id_by_ip "$ip")
    local vm_index=$(get_vm_index "$vm_id")
    local vm_name="${VM_NAMES[$vm_index]}"
    
    log "重置节点: $vm_name ($ip)"
    
    if ! execute_remote_command "$ip" "echo 'SSH连接测试'" 5 >/dev/null 2>&1; then
        warn "$vm_name SSH连接失败，跳过重置"
        return 1
    fi
    
    execute_remote_command "$ip" "
        # 停止K8S服务
        systemctl stop kubelet
        systemctl stop containerd
        
        # 重置kubeadm
        kubeadm reset -f
        
        # 清理网络配置
        iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
        
        # 清理文件
        rm -rf /etc/kubernetes/
        rm -rf /var/lib/kubelet/
        rm -rf /var/lib/etcd/
        rm -rf /etc/cni/net.d/
        rm -rf /opt/cni/bin/
        
        # 重启服务
        systemctl start containerd
        systemctl start kubelet
        
        echo '节点重置完成'
    " 120 || warn "$vm_name 重置失败"
}

# 修复菜单
show_fix_menu() {
    echo -e "${BOLD}${YELLOW}修复和诊断菜单：${NC}"
    echo -e "  ${CYAN}1.${NC} 🔍 诊断VM状态"
    echo -e "  ${CYAN}2.${NC} 🌐 修复VM网络问题"
    echo -e "  ${CYAN}3.${NC} 🔑 修复SSH连接问题"
    echo -e "  ${CYAN}4.${NC} 📦 修复容器运行时问题"
    echo -e "  ${CYAN}5.${NC} ☸️  修复K8S集群问题"
    echo -e "  ${CYAN}6.${NC} 🌐 修复KubeSphere问题"
    echo -e "  ${CYAN}7.${NC} 🔄 重置指定节点"
    echo -e "  ${CYAN}8.${NC} 🔧 一键自动修复"
    echo -e "  ${CYAN}0.${NC} ⬅️  返回主菜单"
    echo ""
}

fix_menu() {
    while true; do
        clear
        show_banner
        show_fix_menu
        
        read -p "请选择修复操作 [0-8]: " choice
        echo ""
        
        case $choice in
            1)
                diagnose_vm_status
                read -p "按回车键继续..."
                ;;
            2)
                fix_vm_network
                read -p "按回车键继续..."
                ;;
            3)
                fix_ssh_connection
                read -p "按回车键继续..."
                ;;
            4)
                fix_container_runtime
                read -p "按回车键继续..."
                ;;
            5)
                fix_kubernetes_cluster
                read -p "按回车键继续..."
                ;;
            6)
                fix_kubesphere
                read -p "按回车键继续..."
                ;;
            7)
                echo "可用节点："
                for i in "${!VM_IDS[@]}"; do
                    echo "  $((i+1)). ${VM_NAMES[$i]} (${VM_IPS[$i]})"
                done
                echo ""
                read -p "请选择要重置的节点 [1-${#VM_IDS[@]}]: " node_choice
                
                if [[ "$node_choice" -ge 1 && "$node_choice" -le "${#VM_IDS[@]}" ]]; then
                    local selected_index=$((node_choice-1))
                    local selected_ip="${VM_IPS[$selected_index]}"
                    local selected_name="${VM_NAMES[$selected_index]}"
                    
                    read -p "确认重置节点 $selected_name ($selected_ip)？(y/N): " confirm
                    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                        reset_node "$selected_ip"
                    else
                        log "操作已取消"
                    fi
                else
                    warn "无效选择"
                fi
                read -p "按回车键继续..."
                ;;
            8)
                log "开始一键自动修复..."
                diagnose_vm_status
                fix_vm_network
                fix_ssh_connection
                fix_container_runtime
                fix_kubernetes_cluster
                fix_kubesphere
                success "一键自动修复完成！"
                read -p "按回车键继续..."
                ;;
            0)
                return 0
                ;;
            *)
                warn "无效选择，请重新输入"
                sleep 2
                ;;
        esac
    done
}

#===============================================================================
# 状态检查
#===============================================================================

check_cluster_status() {
    local master_ip="${VM_IPS[0]}"
    
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    集群状态检查                              ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 检查节点状态
    echo -e "${YELLOW}节点状态：${NC}"
    execute_remote_command "$master_ip" "kubectl get nodes -o wide" 30 || warn "无法获取节点状态"
    echo ""
    
    # 检查Pod状态
    echo -e "${YELLOW}系统Pod状态：${NC}"
    execute_remote_command "$master_ip" "kubectl get pods --all-namespaces" 30 || warn "无法获取Pod状态"
    echo ""
    
    # 检查KubeSphere状态
    echo -e "${YELLOW}KubeSphere状态：${NC}"
    execute_remote_command "$master_ip" "kubectl get pods -n kubesphere-system" 30 || warn "KubeSphere可能未安装"
    echo ""
    
    # 显示访问信息
    echo -e "${YELLOW}访问信息：${NC}"
    echo -e "Kubernetes API: https://$master_ip:6443"
    echo -e "KubeSphere Console: http://$master_ip:30880"
    echo -e "默认用户名: admin"
    echo -e "默认密码: P@88w0rd"
    echo ""
    
    # 显示VM信息
    echo -e "${YELLOW}VM信息：${NC}"
    for i in "${!VM_IDS[@]}"; do
        echo -e "${VM_NAMES[$i]} (${VM_IDS[$i]}): ${VM_IPS[$i]} - ${VM_CORES[$i]}核${VM_MEMORY[$i]}MB内存${VM_DISK[$i]}GB硬盘"
    done
    echo ""
}

#===============================================================================
# 清理功能
#===============================================================================

cleanup_all() {
    log "开始清理所有资源..."
    
    read -p "警告：这将删除所有VM和相关资源。确认继续？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log "操作已取消"
        return 0
    fi
    
    # 停止并删除所有VM
    for vm_id in "${VM_IDS[@]}"; do
        local vm_index=$(get_vm_index "$vm_id")
        local vm_name="${VM_NAMES[$vm_index]}"
        log "删除虚拟机: $vm_name (ID: $vm_id)"
        
        qm stop "$vm_id" >/dev/null 2>&1 || true
        sleep 2
        qm destroy "$vm_id" >/dev/null 2>&1 || true
    done
    
    # 清理cloud-init配置文件
    rm -f /var/lib/vz/snippets/user-data-*.yml
    
    # 清理工作目录
    rm -rf "$WORK_DIR"
    
    success "资源清理完成"
}

#===============================================================================
# 主菜单
#===============================================================================

show_banner() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                      ║"
    echo "║    🚀 PVE K8S + KubeSphere 智能部署工具 v${SCRIPT_VERSION}                     ║"
    echo "║                                                                      ║"
    echo "║    📋 在PVE环境中自动部署Kubernetes集群和KubeSphere平台                ║"
    echo "║    👨‍💻 支持最新版本K8S和容器运行时从GitHub源码安装                      ║"
    echo "║                                                                      ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

show_menu() {
    echo -e "${BOLD}${YELLOW}主菜单：${NC}"
    echo -e "  ${CYAN}1.${NC} 🚀 一键全自动部署（推荐）"
    echo -e "  ${CYAN}2.${NC} 🖥️  创建虚拟机"
    echo -e "  ${CYAN}3.${NC} ☸️  部署Kubernetes集群"
    echo -e "  ${CYAN}4.${NC} 🌐 部署KubeSphere"
    echo -e "  ${CYAN}5.${NC} 📊 检查集群状态"
    echo -e "  ${CYAN}6.${NC} 🔧 修复和诊断"
    echo -e "  ${CYAN}7.${NC} 🗑️  清理所有资源"
    echo -e "  ${CYAN}0.${NC} ❌ 退出"
    echo ""
}

main_menu() {
    while true; do
        show_banner
        show_menu
        
        read -p "请选择操作 [0-7]: " choice
        echo ""
        
        case $choice in
            1)
                log "开始一键全自动部署..."
                create_all_vms
                deploy_kubernetes
                deploy_kubesphere
                check_cluster_status
                success "一键部署完成！"
                read -p "按回车键继续..."
                ;;
            2)
                create_all_vms
                read -p "按回车键继续..."
                ;;
            3)
                deploy_kubernetes
                read -p "按回车键继续..."
                ;;
            4)
                deploy_kubesphere
                read -p "按回车键继续..."
                ;;
            5)
                check_cluster_status
                read -p "按回车键继续..."
                ;;
            6)
                fix_menu
                ;;
            7)
                cleanup_all
                read -p "按回车键继续..."
                ;;
            0)
                log "感谢使用 $SCRIPT_NAME！"
                exit 0
                ;;
            *)
                warn "无效选择，请重新输入"
                sleep 2
                ;;
        esac
    done
}

#===============================================================================
# 主程序
#===============================================================================

main() {
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --storage)
                STORAGE="$2"
                shift 2
                ;;
            --bridge)
                DETECTED_BRIDGE="$2"
                shift 2
                ;;
            --help|-h|--version|-v|--auto)
                break
                ;;
            *)
                echo "错误：未知参数: $1"
                echo "使用 --help 查看帮助信息"
                exit 1
                ;;
        esac
    done
    
    # 处理主要命令（帮助和版本信息不需要环境检查）
    case "${1:-}" in
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  -h, --help              显示帮助信息"
            echo "  -v, --version           显示版本信息"
            echo "  --auto                  自动部署模式"
            echo "  --storage <name>        指定存储名称（默认自动检测）"
            echo "  --bridge <name>         指定网络桥接（默认自动检测）"
            echo ""
            echo "VM配置:"
            for i in "${!VM_IDS[@]}"; do
                echo "  ${VM_NAMES[$i]} (${VM_IDS[$i]}): ${VM_IPS[$i]} - ${VM_CORES[$i]}核${VM_MEMORY[$i]}MB内存${VM_DISK[$i]}GB硬盘"
            done
            echo ""
            echo "示例:"
            echo "  $0 --storage local"
            echo "  $0 --bridge vmbr1"
            echo "  $0 --storage local-zfs --auto"
            echo ""
            exit 0
            ;;
        --version|-v)
            echo "$SCRIPT_NAME v$SCRIPT_VERSION"
            exit 0
            ;;
        --auto)
            # 检查环境
            check_environment
            log "开始自动部署模式..."
            create_all_vms
            deploy_kubernetes
            deploy_kubesphere
            check_cluster_status
            success "自动部署完成！"
            exit 0
            ;;
        "")
            # 检查环境
            check_environment
            # 交互模式
            main_menu
            ;;
        *)
            echo "错误：未知参数: $1"
            echo "使用 --help 查看帮助信息"
            exit 1
            ;;
    esac
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 