#!/bin/bash

# PVE KubeSphere 部署脚本 - 第一部分：PVE环境准备
# 作者：AI Assistant
# 日期：$(date +%Y-%m-%d)

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 配置变量
PVE_HOST="10.0.0.1"  # 请修改为您的PVE主机IP
PVE_USER="root"
STORAGE_NAME="local-lvm"  # 存储名称
VM_BASE_ID=100  # 虚拟机起始ID
VM_COUNT=3      # 虚拟机数量

# 虚拟机配置
VM_CONFIGS=(
    "k8s-master:8:16384:300:debian-12-standard_12.2-1_amd64.tar.zst"
    "k8s-worker1:8:16384:300:debian-12-standard_12.2-1_amd64.tar.zst"
    "k8s-worker2:8:16384:300:debian-12-standard_12.2-1_amd64.tar.zst"
)

# 网络配置
BRIDGE_NAME="vmbr0"
NETWORK_CIDR="10.0.0.0/24"
GATEWAY="10.0.0.1"
DNS_SERVERS="8.8.8.8,8.8.4.4"

# 检查PVE连接
check_pve_connection() {
    log_step "检查PVE连接..."
    
    if ! ping -c 1 $PVE_HOST > /dev/null 2>&1; then
        log_error "无法连接到PVE主机 $PVE_HOST"
        exit 1
    fi
    
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes $PVE_USER@$PVE_HOST "echo '连接成功'" > /dev/null 2>&1; then
        log_error "无法SSH连接到PVE主机，请确保SSH密钥已配置"
        exit 1
    fi
    
    log_info "PVE连接正常"
}

# 下载Debian模板
download_debian_template() {
    log_step "下载Debian 12模板..."
    
    TEMPLATE_URL="https://download.proxmox.com/images/system/debian-12-standard_12.2-1_amd64.tar.zst"
    TEMPLATE_FILE="debian-12-standard_12.2-1_amd64.tar.zst"
    
    ssh $PVE_USER@$PVE_HOST << EOF
        cd /var/lib/vz/template/cache
        if [ ! -f "$TEMPLATE_FILE" ]; then
            wget $TEMPLATE_URL
            echo "Debian模板下载完成"
        else
            echo "Debian模板已存在，跳过下载"
        fi
EOF
}

# 创建虚拟机
create_vms() {
    log_step "创建虚拟机..."
    
    for i in "${!VM_CONFIGS[@]}"; do
        IFS=':' read -r vm_name cpu_count memory disk_size template_file <<< "${VM_CONFIGS[$i]}"
        vm_id=$((VM_BASE_ID + i))
        
        log_info "创建虚拟机: $vm_name (ID: $vm_id)"
        
        ssh $PVE_USER@$PVE_HOST << EOF
            # 创建虚拟机
            qm create $vm_id \
                --name $vm_name \
                --memory $memory \
                --cores $cpu_count \
                --net0 name=net0,bridge=$BRIDGE_NAME,model=virtio \
                --scsihw virtio-scsi-pci
            
            # 导入磁盘
            qm importdisk $vm_id /var/lib/vz/template/cache/$template_file $STORAGE_NAME
            
            # 附加磁盘
            qm set $vm_id --scsi0 $STORAGE_NAME:vm-$vm_id-disk-0
            
            # 设置启动盘
            qm set $vm_id --boot c --bootdisk scsi0
            
            # 设置串行控制台
            qm set $vm_id --serial0 socket
            
            # 设置VGA
            qm set $vm_id --vga serial0
            
            # 启用QEMU代理
            qm set $vm_id --agent 1
            
            # 设置CPU类型
            qm set $vm_id --cpu host
            
            # 设置磁盘大小
            qm resize $vm_id scsi0 ${disk_size}G
            
            echo "虚拟机 $vm_name 创建完成"
EOF
    done
}

# 配置虚拟机网络
configure_vm_network() {
    log_step "配置虚拟机网络..."
    
    # 生成IP地址列表
    declare -a vm_ips=()
    for i in $(seq 0 $((VM_COUNT-1))); do
        vm_ips[$i]="10.0.0.$((10 + i))"
    done
    
    for i in "${!VM_CONFIGS[@]}"; do
        IFS=':' read -r vm_name cpu_count memory disk_size template_file <<< "${VM_CONFIGS[$i]}"
        vm_id=$((VM_BASE_ID + i))
        vm_ip="${vm_ips[$i]}"
        
        log_info "配置虚拟机 $vm_name 网络: $vm_ip"
        
        # 创建cloud-init配置
        ssh $PVE_USER@$PVE_HOST << EOF
            # 创建cloud-init配置
            qm set $vm_id --ide2 $STORAGE_NAME:cloudinit
            
            # 设置用户和密码
            qm set $vm_id --ciuser root
            qm set $vm_id --cipassword kubesphere123
            
            # 设置SSH密钥（如果有的话）
            if [ -f ~/.ssh/id_rsa.pub ]; then
                qm set $vm_id --sshkeys ~/.ssh/id_rsa.pub
            fi
            
            # 设置网络配置
            qm set $vm_id --ipconfig0 ip=$vm_ip/24,gw=$GATEWAY
            
            # 设置DNS
            qm set $vm_id --nameserver "$DNS_SERVERS"
            
            echo "虚拟机 $vm_name 网络配置完成"
EOF
    done
}

# 启动虚拟机
start_vms() {
    log_step "启动虚拟机..."
    
    for i in "${!VM_CONFIGS[@]}"; do
        IFS=':' read -r vm_name cpu_count memory disk_size template_file <<< "${VM_CONFIGS[$i]}"
        vm_id=$((VM_BASE_ID + i))
        
        log_info "启动虚拟机: $vm_name"
        
        ssh $PVE_USER@$PVE_HOST << EOF
            qm start $vm_id
            echo "虚拟机 $vm_name 启动完成"
EOF
        
        # 等待虚拟机启动
        sleep 30
    done
}

# 等待虚拟机完全启动
wait_for_vms() {
    log_step "等待虚拟机完全启动..."
    
    for i in "${!VM_CONFIGS[@]}"; do
        IFS=':' read -r vm_name cpu_count memory disk_size template_file <<< "${VM_CONFIGS[$i]}"
        vm_ip="10.0.0.$((10 + i))"
        
        log_info "等待虚拟机 $vm_name ($vm_ip) 启动..."
        
        # 等待SSH可用
        while ! nc -z $vm_ip 22; do
            sleep 5
        done
        
        # 等待系统完全启动
        while ! ssh -o ConnectTimeout=5 -o BatchMode=yes root@$vm_ip "echo 'ready'" > /dev/null 2>&1; do
            sleep 10
        done
        
        log_info "虚拟机 $vm_name 启动完成"
    done
}

# 生成主机列表文件
generate_hosts_file() {
    log_step "生成主机列表文件..."
    
    cat > hosts.txt << EOF
# KubeSphere集群主机列表
# 生成时间: $(date)

[k8s-master]
10.0.0.10

[k8s-workers]
10.0.0.11
10.0.0.12

[k8s:children]
k8s-master
k8s-workers

[k8s:vars]
ansible_user=root
ansible_password=kubesphere123
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF
    
    log_info "主机列表文件已生成: hosts.txt"
}

# 生成SSH密钥（如果需要）
generate_ssh_key() {
    log_step "检查SSH密钥..."
    
    if [ ! -f ~/.ssh/id_rsa ]; then
        log_info "生成SSH密钥对..."
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
        log_info "SSH密钥生成完成"
    else
        log_info "SSH密钥已存在"
    fi
}

# 主函数
main() {
    log_info "开始PVE KubeSphere环境准备..."
    
    check_pve_connection
    generate_ssh_key
    download_debian_template
    create_vms
    configure_vm_network
    start_vms
    wait_for_vms
    generate_hosts_file
    
    log_info "PVE环境准备完成！"
    log_info "虚拟机信息："
    log_info "- k8s-master: 10.0.0.10"
    log_info "- k8s-worker1: 10.0.0.11"
    log_info "- k8s-worker2: 10.0.0.12"
    log_info ""
    log_info "下一步：运行 02-k8s-install.sh 安装Kubernetes"
}

# 执行主函数
main "$@" 