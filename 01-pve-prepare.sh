#!/bin/bash

# PVE环境准备脚本
# 在PVE主机上创建KubeSphere所需的虚拟机

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

# 虚拟机配置
VM_BASE_ID=100
VM_COUNT=3
VM_CORES=8
VM_MEMORY=16384
VM_DISK_SIZE=300
STORAGE_NAME="local-lvm"
BRIDGE_NAME="vmbr0"

# 虚拟机配置数组 (名称:CPU:内存:磁盘:模板文件)
VM_CONFIGS=(
    "k8s-master:$VM_CORES:$VM_MEMORY:$VM_DISK_SIZE:debian-12-standard_12.2-1_amd64.tar.zst"
    "k8s-worker1:$VM_CORES:$VM_MEMORY:$VM_DISK_SIZE:debian-12-standard_12.2-1_amd64.tar.zst"
    "k8s-worker2:$VM_CORES:$VM_MEMORY:$VM_DISK_SIZE:debian-12-standard_12.2-1_amd64.tar.zst"
)

# 网络配置
GATEWAY="10.0.0.1"
DNS_SERVERS="8.8.8.8,8.8.4.4"

# 检查PVE环境
check_pve_environment() {
    log_step "检查PVE环境..."
    
    # 检查是否在PVE环境中
    if ! command -v pveversion &> /dev/null; then
        log_error "此脚本需要在PVE环境中运行"
        exit 1
    fi
    
    # 检查PVE版本
    PVE_VERSION=$(pveversion -v | head -1)
    log_info "PVE版本: $PVE_VERSION"
    
    # 检查存储
    if ! pvesm status | grep -q "$STORAGE_NAME"; then
        log_error "存储 $STORAGE_NAME 不存在"
        exit 1
    fi
    
    # 检查网络桥接
    if ! ip link show | grep -q "$BRIDGE_NAME"; then
        log_error "网络桥接 $BRIDGE_NAME 不存在"
        exit 1
    fi
    
    log_info "PVE环境检查通过"
}

# 下载Debian模板
download_debian_template() {
    log_step "下载Debian 12模板..."
    
    TEMPLATE_URL="https://download.proxmox.com/images/system/debian-12-standard_12.2-1_amd64.tar.zst"
    TEMPLATE_FILE="debian-12-standard_12.2-1_amd64.tar.zst"
    
    cd /var/lib/vz/template/cache
    if [ ! -f "$TEMPLATE_FILE" ]; then
        log_info "下载Debian模板..."
        wget -q --show-progress $TEMPLATE_URL
        log_info "Debian模板下载完成"
    else
        log_info "Debian模板已存在，跳过下载"
    fi
}

# 创建虚拟机
create_vms() {
    log_step "创建虚拟机..."
    
    for i in "${!VM_CONFIGS[@]}"; do
        IFS=':' read -r vm_name cpu_count memory disk_size template_file <<< "${VM_CONFIGS[$i]}"
        vm_id=$((VM_BASE_ID + i))
        
        log_info "创建虚拟机: $vm_name (ID: $vm_id)"
        
        # 检查虚拟机是否已存在
        if qm list | grep -q "$vm_id"; then
            log_warn "虚拟机 $vm_name (ID: $vm_id) 已存在，跳过创建"
            continue
        fi
        
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
        
        log_info "虚拟机 $vm_name 创建完成"
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
        
        log_info "虚拟机 $vm_name 网络配置完成"
    done
}

# 启动虚拟机
start_vms() {
    log_step "启动虚拟机..."
    
    for i in "${!VM_CONFIGS[@]}"; do
        IFS=':' read -r vm_name cpu_count memory disk_size template_file <<< "${VM_CONFIGS[$i]}"
        vm_id=$((VM_BASE_ID + i))
        
        log_info "启动虚拟机: $vm_name"
        
        # 检查虚拟机状态
        if qm list | grep "$vm_id" | grep -q "running"; then
            log_warn "虚拟机 $vm_name 已在运行，跳过启动"
            continue
        fi
        
        qm start $vm_id
        log_info "虚拟机 $vm_name 启动完成"
        
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
            log_info "等待SSH端口开放..."
            sleep 5
        done
        
        # 等待系统完全启动
        while ! ssh -o ConnectTimeout=5 -o BatchMode=yes root@$vm_ip "echo 'ready'" > /dev/null 2>&1; do
            log_info "等待系统完全启动..."
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

# 显示虚拟机状态
show_vm_status() {
    log_step "虚拟机状态:"
    qm list | grep -E "(VMID|k8s)"
}

# 主函数
main() {
    log_info "开始PVE环境准备..."
    log_info "PVE主机: $PVE_HOST"
    log_info "虚拟机数量: $VM_COUNT"
    log_info "虚拟机配置: ${VM_CORES}核 ${VM_MEMORY}MB ${VM_DISK_SIZE}GB"
    echo ""
    
    # 检查PVE环境
    check_pve_environment
    
    # 下载Debian模板
    download_debian_template
    
    # 创建虚拟机
    create_vms
    
    # 配置虚拟机网络
    configure_vm_network
    
    # 启动虚拟机
    start_vms
    
    # 等待虚拟机完全启动
    wait_for_vms
    
    # 生成主机列表文件
    generate_hosts_file
    
    # 显示虚拟机状态
    show_vm_status
    
    log_info "PVE环境准备完成！"
    
    echo ""
    echo "=========================================="
    echo "🎉 PVE环境准备成功！"
    echo "=========================================="
    echo ""
    echo "📋 虚拟机信息："
    echo "   Master节点: 10.0.0.10"
    echo "   Worker1节点: 10.0.0.11"
    echo "   Worker2节点: 10.0.0.12"
    echo ""
    echo "🔧 访问信息："
    echo "   SSH用户: root"
    echo "   SSH密码: kubesphere123"
    echo ""
    echo "📚 下一步："
    echo "   运行: ./02-k8s-install.sh"
    echo "=========================================="
}

# 执行主函数
main "$@" 