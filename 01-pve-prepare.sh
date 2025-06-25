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

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# 配置变量
PVE_HOST="10.0.0.1"  # 请修改为您的PVE主机IP
PVE_USER="root"

# 虚拟机配置
VM_BASE_ID=101
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
GATEWAY="10.0.0.2"
DNS_SERVERS="10.0.0.2,119.29.29.29"

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

# 测试网络连接
test_network_connectivity() {
    log_step "测试网络连接..."
    
    # 测试基本网络连接
    if ! ping -c 3 8.8.8.8 > /dev/null 2>&1; then
        log_error "无法连接到外网，请检查网络配置"
        return 1
    fi
    
    # 测试DNS解析
    if ! nslookup download.proxmox.com > /dev/null 2>&1; then
        log_warn "DNS解析可能有问题，将尝试使用IP地址"
    fi
    
    log_info "网络连接测试通过"
    return 0
}

# 下载Debian模板
download_debian_template() {
    log_step "下载Debian 12模板..."
    
    # 多个下载源（优先使用中国镜像源）
    TEMPLATE_URLS=(
        "https://mirrors.ustc.edu.cn/proxmox/images/system/debian-12-standard_12.2-1_amd64.tar.zst"
        "https://mirrors.tuna.tsinghua.edu.cn/proxmox/images/system/debian-12-standard_12.2-1_amd64.tar.zst"
        "https://download.proxmox.com/images/system/debian-12-standard_12.2-1_amd64.tar.zst"
    )
    TEMPLATE_FILE="debian-12-standard_12.2-1_amd64.tar.zst"
    
    # 确保目录存在
    mkdir -p /var/lib/vz/template/cache
    cd /var/lib/vz/template/cache
    
    # 检查文件是否已存在
    if [ -f "$TEMPLATE_FILE" ]; then
        log_info "Debian模板已存在，跳过下载"
        return 0
    fi
    
    # 尝试从不同源下载
    for url in "${TEMPLATE_URLS[@]}"; do
        log_info "尝试从 $url 下载Debian模板..."
        
        if wget -q --show-progress --timeout=30 --tries=3 "$url"; then
            log_info "Debian模板下载完成"
            
            # 验证文件完整性
            if [ -f "$TEMPLATE_FILE" ] && [ -s "$TEMPLATE_FILE" ]; then
                log_info "文件下载成功，大小: $(du -h "$TEMPLATE_FILE" | cut -f1)"
                return 0
            else
                log_warn "文件下载可能不完整，尝试下一个源"
                rm -f "$TEMPLATE_FILE"
                continue
            fi
        else
            log_warn "从 $url 下载失败，尝试下一个源"
            continue
        fi
    done
    
    # 如果所有源都失败，尝试使用curl
    log_info "尝试使用curl下载..."
    for url in "${TEMPLATE_URLS[@]}"; do
        log_info "使用curl从 $url 下载..."
        
        if curl -L -o "$TEMPLATE_FILE" --connect-timeout 30 --max-time 300 "$url"; then
            log_info "使用curl下载成功"
            
            if [ -f "$TEMPLATE_FILE" ] && [ -s "$TEMPLATE_FILE" ]; then
                log_info "文件下载成功，大小: $(du -h "$TEMPLATE_FILE" | cut -f1)"
                return 0
            else
                log_warn "curl下载的文件可能不完整"
                rm -f "$TEMPLATE_FILE"
                continue
            fi
        else
            log_warn "curl从 $url 下载失败"
            continue
        fi
    done
    
    # 如果还是失败，尝试使用PVE内置的下载功能
    log_info "尝试使用PVE内置下载功能..."
    if pveam update && pveam download local debian-12-standard_12.2-1_amd64.tar.zst; then
        log_info "使用PVE内置功能下载成功"
        return 0
    fi
    
    # 如果所有下载方法都失败，提供手动下载指导
    log_error "所有自动下载方法都失败了"
    log_info "请手动下载Debian模板文件："
    echo ""
    echo "=========================================="
    echo "🔧 手动下载指导"
    echo "=========================================="
    echo ""
    echo "1. 在PVE主机上执行以下命令："
    echo "   cd /var/lib/vz/template/cache"
    echo ""
    echo "2. 尝试以下下载命令（选择一个）："
    echo "   # 方法1：使用wget"
    echo "   wget https://download.proxmox.com/images/system/debian-12-standard_12.2-1_amd64.tar.zst"
    echo ""
    echo "   # 方法2：使用curl"
    echo "   curl -L -o debian-12-standard_12.2-1_amd64.tar.zst https://download.proxmox.com/images/system/debian-12-standard_12.2-1_amd64.tar.zst"
    echo ""
    echo "   # 方法3：使用PVE内置功能"
    echo "   pveam update"
    echo "   pveam download local debian-12-standard_12.2-1_amd64.tar.zst"
    echo ""
    echo "3. 如果网络有问题，可以："
    echo "   - 检查网络连接和防火墙设置"
    echo "   - 尝试使用代理"
    echo "   - 从其他机器下载后传输到PVE主机"
    echo ""
    echo "4. 下载完成后，重新运行此脚本"
    echo "=========================================="
    echo ""
    
    # 询问用户是否继续
    read -p "是否继续创建最小化模板？(y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_warn "用户选择创建最小化模板"
        create_minimal_template
        return 0
    else
        log_error "用户选择退出，请手动下载模板后重新运行脚本"
        exit 1
    fi
}

# 创建最小化模板（备用方案）
create_minimal_template() {
    log_info "创建最小化Debian模板..."
    
    # 创建一个简单的虚拟机作为模板
    TEMP_VM_ID=999
    
    # 创建临时虚拟机
    qm create $TEMP_VM_ID \
        --name temp-debian \
        --memory 1024 \
        --cores 1 \
        --net0 bridge=$BRIDGE_NAME,model=virtio \
        --scsihw virtio-scsi-pci \
        --ide2 $STORAGE_NAME:cloudinit
    
    # 设置启动配置
    qm set $TEMP_VM_ID --ciuser root
    qm set $TEMP_VM_ID --cipassword kubesphere123
    qm set $TEMP_VM_ID --ipconfig0 ip=10.0.0.99/24,gw=$GATEWAY
    
    # 启动虚拟机进行初始化
    qm start $TEMP_VM_ID
    
    # 等待一段时间让系统初始化
    sleep 60
    
    # 停止虚拟机
    qm stop $TEMP_VM_ID
    
    # 转换为模板
    qm template $TEMP_VM_ID
    
    log_info "最小化模板创建完成"
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
            --net0 bridge=$BRIDGE_NAME,model=virtio \
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
        vm_id=$((VM_BASE_ID + i))
        
        log_info "等待虚拟机 $vm_name ($vm_ip) 启动..."
        
        # 检查虚拟机状态
        local vm_status=$(qm list | grep "$vm_id" | awk '{print $3}')
        log_info "虚拟机 $vm_name 状态: $vm_status"
        
        # 等待虚拟机完全启动（最多等待5分钟）
        local timeout=300
        local elapsed=0
        local ssh_timeout=60
        
        log_info "等待SSH端口开放 (超时: ${ssh_timeout}秒)..."
        
        # 等待SSH可用
        while [ $elapsed -lt $ssh_timeout ]; do
            if nc -z $vm_ip 22 2>/dev/null; then
                log_success "SSH端口已开放"
                break
            fi
            
            log_info "等待SSH端口开放... (${elapsed}/${ssh_timeout}秒)"
            sleep 5
            elapsed=$((elapsed + 5))
        done
        
        if [ $elapsed -ge $ssh_timeout ]; then
            log_error "SSH端口等待超时，尝试诊断问题..."
            
            # 诊断信息
            log_info "诊断信息："
            log_info "- 虚拟机状态: $(qm list | grep "$vm_id" | awk '{print $3}')"
            log_info "- 网络连接测试: $(ping -c 1 $vm_ip 2>/dev/null && echo "成功" || echo "失败")"
            log_info "- 端口扫描: $(nc -z $vm_ip 22 2>/dev/null && echo "SSH端口开放" || echo "SSH端口关闭")"
            
            # 尝试重启虚拟机
            log_warn "尝试重启虚拟机 $vm_name..."
            qm stop $vm_id 2>/dev/null || true
            sleep 10
            qm start $vm_id
            sleep 30
            
            # 再次尝试SSH连接
            elapsed=0
            while [ $elapsed -lt $ssh_timeout ]; do
                if nc -z $vm_ip 22 2>/dev/null; then
                    log_success "重启后SSH端口已开放"
                    break
                fi
                
                log_info "重启后等待SSH端口开放... (${elapsed}/${ssh_timeout}秒)"
                sleep 5
                elapsed=$((elapsed + 5))
            done
            
            if [ $elapsed -ge $ssh_timeout ]; then
                log_error "虚拟机 $vm_name SSH连接失败，请手动检查"
                log_info "手动检查命令："
                log_info "qm status $vm_id"
                log_info "qm terminal $vm_id"
                log_info "ping $vm_ip"
                continue
            fi
        fi
        
        # 等待系统完全启动（最多等待3分钟）
        log_info "等待系统完全启动 (超时: 180秒)..."
        elapsed=0
        
        while [ $elapsed -lt 180 ]; do
            if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no root@$vm_ip "echo 'ready'" > /dev/null 2>&1; then
                log_success "系统完全启动"
                break
            fi
            
            log_info "等待系统完全启动... (${elapsed}/180秒)"
            sleep 10
            elapsed=$((elapsed + 10))
        done
        
        if [ $elapsed -ge 180 ]; then
            log_warn "系统启动等待超时，但SSH已可用"
        fi
        
        log_info "虚拟机 $vm_name 启动完成"
    done
}

# 配置虚拟机SSH和防火墙
configure_vm_services() {
    log_step "配置虚拟机SSH和防火墙..."
    
    for i in "${!VM_CONFIGS[@]}"; do
        IFS=':' read -r vm_name cpu_count memory disk_size template_file <<< "${VM_CONFIGS[$i]}"
        vm_ip="10.0.0.$((10 + i))"
        vm_id=$((VM_BASE_ID + i))
        
        log_info "配置 $vm_name ($vm_ip) 的SSH和防火墙..."
        
        # 等待SSH连接可用
        local retry_count=0
        while [ $retry_count -lt 30 ]; do
            if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no root@$vm_ip "echo 'SSH ready'" > /dev/null 2>&1; then
                break
            fi
            log_info "等待SSH连接... (${retry_count}/30)"
            sleep 10
            retry_count=$((retry_count + 1))
        done
        
        if [ $retry_count -ge 30 ]; then
            log_error "无法连接到 $vm_name，跳过配置"
            continue
        fi
        
        # 配置SSH服务
        log_info "配置SSH服务..."
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@$vm_ip << 'EOF'
# 启用SSH服务
systemctl enable ssh
systemctl start ssh

# 配置SSH允许root登录和密码认证
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config

# 重启SSH服务
systemctl restart ssh

# 检查SSH服务状态
systemctl status ssh --no-pager -l
EOF
        
        # 配置防火墙
        log_info "配置防火墙..."
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@$vm_ip << 'EOF'
# 安装ufw防火墙（如果未安装）
apt update
apt install -y ufw

# 配置防火墙规则
ufw --force reset

# 允许SSH连接
ufw allow ssh

# 允许Kubernetes相关端口
ufw allow 6443/tcp  # Kubernetes API
ufw allow 2379:2380/tcp  # etcd
ufw allow 10250/tcp  # Kubelet
ufw allow 10251/tcp  # kube-scheduler
ufw allow 10252/tcp  # kube-controller-manager
ufw allow 10255/tcp  # Kubelet read-only
ufw allow 179/tcp  # Calico BGP
ufw allow 4789/udp  # Calico VXLAN
ufw allow 5473/tcp  # Calico Typha
ufw allow 9099/tcp  # Calico Felix
ufw allow 9099/udp  # Calico Felix

# 允许KubeSphere相关端口
ufw allow 30880/tcp  # KubeSphere Console
ufw allow 30180/tcp  # KubeSphere API
ufw allow 30280/tcp  # KubeSphere Gateway

# 允许其他必要端口
ufw allow 80/tcp   # HTTP
ufw allow 443/tcp  # HTTPS
ufw allow 53/tcp   # DNS
ufw allow 53/udp   # DNS
ufw allow 67/udp   # DHCP
ufw allow 68/udp   # DHCP

# 启用防火墙
ufw --force enable

# 检查防火墙状态
ufw status verbose
EOF
        
        log_success "$vm_name SSH和防火墙配置完成"
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

# 检查模板文件
check_template_files() {
    log_step "检查模板文件..."
    
    for i in "${!VM_CONFIGS[@]}"; do
        IFS=':' read -r vm_name cpu_count memory disk_size template_file <<< "${VM_CONFIGS[$i]}"
        
        # 检查模板文件是否存在
        if [ ! -f "/var/lib/vz/template/cache/$template_file" ]; then
            log_error "模板文件不存在: $template_file"
            log_info "请确保已下载Debian模板文件"
            return 1
        fi
        
        log_info "模板文件 $template_file 存在"
    done
    
    log_info "所有模板文件检查通过"
    return 0
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
    
    # 测试网络连接
    test_network_connectivity
    
    # 下载Debian模板
    download_debian_template
    
    # 检查模板文件
    check_template_files
    
    # 创建虚拟机
    create_vms
    
    # 配置虚拟机网络
    configure_vm_network
    
    # 启动虚拟机
    start_vms
    
    # 等待虚拟机完全启动
    wait_for_vms
    
    # 配置虚拟机SSH和防火墙
    configure_vm_services
    
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