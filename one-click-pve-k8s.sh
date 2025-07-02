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
readonly DNS="10.0.0.1"

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
    "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
    "https://mirrors.ustc.edu.cn/debian-cloud-images/bookworm/latest/debian-12-generic-amd64.qcow2"
)
readonly CLOUD_IMAGE_FILE="debian-12-generic-amd64.qcow2"
readonly CLOUD_IMAGE_PATH="/var/lib/vz/template/qcow/$CLOUD_IMAGE_FILE"

# K8S配置
readonly K8S_VERSION="v1.28.2"
readonly POD_SUBNET="10.244.0.0/16"

# 日志配置
readonly LOG_DIR="/var/log/pve-k8s-deploy"
readonly LOG_FILE="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"

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
    local max_wait="${2:-300}"
    
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
    local userdata_file="/var/lib/vz/snippets/user-data-k8s.yml"
    
    log "创建Cloud-init配置..."
    
    cat > "$userdata_file" << EOF
#cloud-config

chpasswd:
  expire: false
  users:
    - name: root
      password: $CLOUDINIT_PASS
      type: text

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

packages:
  - openssh-server
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - net-tools

runcmd:
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

final_message: "Cloud-init配置完成"
EOF
    
    success "Cloud-init配置创建完成"
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
        --cicustom "user=local:snippets/user-data-k8s.yml" \
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
    
    create_cloudinit_config
    
    for vm_id in "${!VM_CONFIGS[@]}"; do
        create_vm "$vm_id"
    done
    
    success "所有虚拟机创建完成"
}

wait_for_all_vms() {
    log "等待所有虚拟机启动..."
    
    local all_ips=($(get_all_ips))
    
    for ip in "${all_ips[@]}"; do
        wait_for_ssh "$ip"
    done
    
    # 等待Cloud-init完成
    for ip in "${all_ips[@]}"; do
        log "等待 $ip Cloud-init完成..."
        execute_remote_command "$ip" "cloud-init status --wait" 3 || warn "$ip Cloud-init超时"
    done
    
    success "所有虚拟机启动完成"
}

# ==========================================
# K8S部署
# ==========================================
install_docker_k8s() {
    local ip="$1"
    log "在 $ip 安装Docker和K8S..."
    
    local install_script='
        # 安装Docker
        curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
        echo "deb [arch=amd64] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io
        
        # 配置Docker
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json << "EOF"
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m"},
  "storage-driver": "overlay2"
}
EOF
        
        # 配置containerd
        mkdir -p /etc/containerd
        containerd config default > /etc/containerd/config.toml
        sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml
        
        systemctl daemon-reload
        systemctl enable docker containerd
        systemctl restart docker containerd
        
        # 安装K8S
        curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
        echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
        apt-get update -y
        apt-get install -y kubelet=1.28.2-00 kubeadm=1.28.2-00 kubectl=1.28.2-00
        apt-mark hold kubelet kubeadm kubectl
        
        systemctl enable kubelet
    '
    
    execute_remote_command "$ip" "$install_script"
}

init_k8s_master() {
    local master_ip=$(get_master_ip)
    log "初始化K8S主节点..."
    
    local init_script="
        kubeadm reset -f 2>/dev/null || true
        
        kubeadm init \
            --apiserver-advertise-address=$master_ip \
            --pod-network-cidr=$POD_SUBNET \
            --kubernetes-version=$K8S_VERSION \
            --ignore-preflight-errors=all
        
        mkdir -p /root/.kube
        cp /etc/kubernetes/admin.conf /root/.kube/config
        
        # 安装Calico
        kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml
    "
    
    execute_remote_command "$master_ip" "$init_script"
    success "K8S主节点初始化完成"
}

join_workers() {
    local master_ip=$(get_master_ip)
    
    # 获取加入命令
    local join_cmd=$(execute_remote_command "$master_ip" "kubeadm token create --print-join-command")
    
    # 加入worker节点
    for vm_id in "${!VM_CONFIGS[@]}"; do
        if [[ "$vm_id" != "101" ]]; then  # 跳过master节点
            local worker_ip=$(parse_vm_config "$vm_id" "ip")
            local worker_name=$(parse_vm_config "$vm_id" "name")
            
            log "将 $worker_name 加入集群..."
            execute_remote_command "$worker_ip" "kubeadm reset -f; $join_cmd --ignore-preflight-errors=all"
        fi
    done
    
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
    
    rm -f /var/lib/vz/snippets/user-data-k8s.yml
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
    echo -e "  ${CYAN}6.${NC} 修复SSH配置"
    echo -e "  ${CYAN}7.${NC} 检查集群状态"
    echo ""
    echo -e "${RED}管理功能：${NC}"
    echo -e "  ${CYAN}8.${NC} 清理所有资源"
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
        
        read -p "请选择操作 [0-8]: " choice
        
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
            6) fix_all_ssh_configs ;;
            7) check_status ;;
            8) cleanup_all ;;
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