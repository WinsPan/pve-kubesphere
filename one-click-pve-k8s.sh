#!/bin/bash

# 极简一键PVE K8S+KubeSphere全自动部署脚本（诊断+部署合并版）
# 功能：自动下载最新Debian ISO，创建3台KVM虚拟机（cloud-init无人值守），批量启动、检测、SSH初始化，自动K8S集群安装，自动KubeSphere部署
# 默认参数：local-lvm, vmbr0, 3台8核16G 300G, 最新Debian, root/kubesphere123
# 使用方法：
#   ./one-click-pve-k8s.sh          # 显示菜单选择
#   ./one-click-pve-k8s.sh deploy   # 直接部署模式
#   ./one-click-pve-k8s.sh diagnose # 直接诊断模式
#   ./one-click-pve-k8s.sh clean    # 直接清理模式

set -e

# 颜色
GREEN='\e[0;32m'
YELLOW='\e[1;33m'
RED='\e[0;31m'
BLUE='\e[0;34m'
CYAN='\e[0;36m'
NC='\e[0m'
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; }
debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }

# 配置
# 只保留Debian cloud镜像，支持cloud-init
CLOUD_IMAGE_URLS=(
  "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
  "https://mirrors.ustc.edu.cn/debian-cloud-images/bookworm/latest/debian-12-generic-amd64.qcow2"
  "https://mirrors.tuna.tsinghua.edu.cn/debian-cloud-images/bookworm/latest/debian-12-generic-amd64.qcow2"
  "https://mirrors.aliyun.com/debian-cloud-images/bookworm/latest/debian-12-generic-amd64.qcow2"
  "https://mirrors.huaweicloud.com/debian-cloud-images/bookworm/latest/debian-12-generic-amd64.qcow2"
)
CLOUD_IMAGE_FILE="debian-12-generic-amd64.qcow2"
CLOUD_IMAGE_PATH="/var/lib/vz/template/qcow/$CLOUD_IMAGE_FILE"

STORAGE="local-lvm"
BRIDGE="vmbr0"
VM_IDS=(101 102 103)
VM_NAMES=("k8s-master" "k8s-worker1" "k8s-worker2")
VM_IPS=("10.0.0.10" "10.0.0.11" "10.0.0.12")
VM_CORES=8
VM_MEM=16384
VM_DISK=300
CLOUDINIT_USER="root"
CLOUDINIT_PASS="kubesphere123"
GATEWAY="10.0.0.1"
DNS="10.0.0.2 119.29.29.29"

MASTER_IP="10.0.0.10"
WORKER_IPS=("10.0.0.11" "10.0.0.12")

# 诊断函数
diagnose_system() {
    echo "=========================================="
    echo "PVE虚拟机诊断报告"
    echo "=========================================="

    # 1. 检查PVE命令可用性
    log "1. 检查PVE环境..."
    if command -v qm &>/dev/null; then
        log "qm命令可用"
    else
        err "qm命令不可用，请确保在PVE环境中运行"
        return 1
    fi

    # 2. 检查虚拟机状态
    log "2. 检查虚拟机状态..."
    echo "当前所有虚拟机列表："
    qm list

    echo ""
    echo "目标虚拟机状态："
    for idx in ${!VM_IDS[@]}; do
        id=${VM_IDS[$idx]}
        name=${VM_NAMES[$idx]}
        ip=${VM_IPS[$idx]}
        
        if qm list | grep -q " $id "; then
            status=$(qm list | awk -v id="$id" '$1==id{print $3}')
            log "虚拟机 $id ($name): $status"
            
            # 检查虚拟机详细信息
            echo "  详细信息："
            qm config $id | grep -E "(memory|cpu|net|scsi|ide)" || true
            
            # 如果虚拟机正在运行，检查网络接口
            if [ "$status" = "running" ]; then
                echo "  网络接口："
                qm guest cmd $id network-get-interfaces 2>/dev/null || echo "    无法获取网络接口信息"
            fi
        else
            err "虚拟机 $id ($name) 不存在"
        fi
        echo ""
    done

    # 3. 检查网络连接
    log "3. 检查网络连接..."
    for idx in ${!VM_IDS[@]}; do
        id=${VM_IDS[$idx]}
        name=${VM_NAMES[$idx]}
        ip=${VM_IPS[$idx]}
        
        echo "检查 $name ($ip):"
        
        # Ping测试
        if ping -c 1 -W 2 $ip &>/dev/null; then
            log "  Ping成功"
        else
            err "  Ping失败"
        fi
        
        # SSH端口测试
        if nc -z $ip 22 &>/dev/null; then
            log "  SSH端口(22)开放"
        else
            err "  SSH端口(22)未开放"
        fi
        
        # 尝试SSH连接
        if command -v sshpass &>/dev/null; then
            if sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 $CLOUDINIT_USER@$ip "echo 'SSH连接成功'" &>/dev/null; then
                log "  SSH连接成功"
                
                # 获取系统信息
                echo "  系统信息："
                sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOINIT_USER@$ip "hostname && cat /etc/os-release | grep PRETTY_NAME && uname -a" 2>/dev/null || echo "    无法获取系统信息"
            else
                err "  SSH连接失败"
            fi
        else
            warn "  sshpass未安装，跳过SSH连接测试"
        fi
        echo ""
    done

    # 4. 检查PVE网络配置
    log "4. 检查PVE网络配置..."
    echo "网络接口："
    ip addr show | grep -E "(vmbr|eth)" || true

    echo ""
    echo "路由表："
    ip route show | head -10

    # 5. 检查存储
    log "5. 检查存储..."
    echo "存储信息："
    pvesm status 2>/dev/null || echo "无法获取存储信息"

    # 6. 检查系统资源
    log "6. 检查系统资源..."
    echo "内存使用："
    free -h

    echo ""
    echo "磁盘使用："
    df -h

    echo ""
    echo "CPU信息："
    nproc
    lscpu | grep "Model name" | head -1

    echo ""
    echo "=========================================="
    echo "诊断完成"
    echo "=========================================="

    # 7. 提供建议
    echo ""
    echo "常见问题解决方案："
    echo "1. 如果虚拟机无法启动：检查PVE资源是否充足"
    echo "2. 如果网络不通：检查vmbr0配置和防火墙设置"
    echo "3. 如果SSH连接失败：检查cloud-init配置和root密码"
    echo "4. 如果虚拟机已存在但状态异常：尝试重启虚拟机"
    echo ""
    echo "重启虚拟机的命令："
    for id in "${VM_IDS[@]}"; do
        echo "  qm stop $id && qm start $id"
    done
}

# 诊断PVE环境
diagnose_pve() {
    log "开始诊断PVE环境..."
    diagnose_system
    return $?
}

# 下载Debian Cloud镜像
download_cloud_image() {
    log "开始下载Debian Cloud镜像..."
    
    # 确保目录存在
    log "确保存储目录存在..."
    mkdir -p /var/lib/vz/template/qcow
    
    # 下载Debian cloud镜像
    log "检查Debian cloud镜像..."
    if [ ! -f "$CLOUD_IMAGE_PATH" ]; then
        log "尝试多源下载Debian cloud镜像: $CLOUD_IMAGE_FILE"
        IMAGE_OK=0
        for url in "${CLOUD_IMAGE_URLS[@]}"; do
            log "尝试下载: $url"
            if wget --timeout=30 --tries=3 -O "$CLOUD_IMAGE_PATH" "$url" 2>/dev/null; then
                IMAGE_OK=1
                log "Cloud镜像下载成功"
                break
            else
                warn "下载失败: $url"
                rm -f "$CLOUD_IMAGE_PATH"
            fi
        done
        if [ $IMAGE_OK -ne 1 ]; then
            err "Cloud镜像下载多次失败，无法继续！"
            return 1
        fi
    else
        log "Cloud镜像已存在: $CLOUD_IMAGE_PATH"
    fi

    # 验证镜像文件
    if [ ! -f "$CLOUD_IMAGE_PATH" ] || [ ! -s "$CLOUD_IMAGE_PATH" ]; then
        err "Cloud镜像文件无效或为空！"
        return 1
    fi
    
    log "Debian Cloud镜像下载/检查完成"
    return 0
}

# 创建并启动虚拟机
create_and_start_vms() {
    log "开始创建并启动虚拟机..."
    
    # 确保cloud-init自定义配置存在
    log "确保cloud-init自定义配置存在..."
    mkdir -p /var/lib/vz/snippets
    CLOUDINIT_CUSTOM_USERCFG="/var/lib/vz/snippets/debian-root.yaml"
    
    # 创建更可靠的cloud-init配置
    cat > "$CLOUDINIT_CUSTOM_USERCFG" <<EOF
#cloud-config
disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
  list: |
    root:$CLOUDINIT_PASS
runcmd:
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  - grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
  - systemctl restart ssh
  - echo "root:$CLOUDINIT_PASS" | chpasswd
EOF

    # 同时创建一个简化版本作为备用
    cat > "/var/lib/vz/snippets/debian-simple.yaml" <<EOF
#cloud-config
disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
  list: |
    root:$CLOUDINIT_PASS
runcmd:
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  - grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
  - systemctl restart ssh
  - echo "root:$CLOUDINIT_PASS" | chpasswd
EOF

    log "Cloud-init配置文件内容:"
    cat "$CLOUDINIT_CUSTOM_USERCFG"

    # 创建虚拟机（使用cloud镜像）
    for idx in ${!VM_IDS[@]}; do
        id=${VM_IDS[$idx]}
        name=${VM_NAMES[$idx]}
        ip=${VM_IPS[$idx]}
        log "处理虚拟机 $name (ID:$id, IP:$ip) ..."
        if qm list | grep -q " $id "; then
            warn "虚拟机 $id 已存在，跳过创建"
            continue
        fi
        log "创建空虚拟机 $id..."
        if ! qm create $id \
            --name $name \
            --memory $VM_MEM \
            --cores $VM_CORES \
            --net0 virtio,bridge=$BRIDGE \
            --scsihw virtio-scsi-pci \
            --serial0 socket \
            --agent 1; then
            err "创建虚拟机 $id 失败，请检查PVE资源和配置"
            return 1
        fi
        log "导入cloud镜像到 $id..."
        if ! qm importdisk $id "$CLOUD_IMAGE_PATH" $STORAGE; then
            err "导入cloud镜像到 $id 失败，请检查镜像和存储"
            return 1
        fi
        log "关联scsi0磁盘..."
        if ! qm set $id --scsi0 $STORAGE:vm-${id}-disk-0; then
            err "设置scsi0磁盘失败"
            return 1
        fi
        log "配置cloud-init..."
        qm set $id --ide3 $STORAGE:cloudinit
        qm set $id --ciuser root --cipassword $CLOUDINIT_PASS
        qm set $id --ipconfig0 ip=$ip/24,gw=$GATEWAY
        qm set $id --nameserver "$DNS"
        qm set $id --boot order=scsi0
        qm set $id --onboot 1
        qm set $id --cicustom "user=local:snippets/debian-root.yaml"
        log "调整磁盘大小到 ${VM_DISK}G..."
        qm resize $id scsi0 ${VM_DISK}G
        log "虚拟机 $id 配置完成"
    done

    # 启动虚拟机
    log "批量启动虚拟机..."
    for id in "${VM_IDS[@]}"; do
        status=$(qm list | awk -v id="$id" '$1==id{print $3}')
        if [ "$status" = "running" ]; then
            warn "虚拟机 $id 已在运行，跳过"
        else
            log "启动虚拟机 $id ..."
            if ! qm start $id; then
                err "启动虚拟机 $id 失败，请检查PVE资源和配置"
                return 1
            fi
            log "虚拟机 $id 启动成功，等待5秒..."
            sleep 5
        fi
    done

    # 显示虚拟机状态
    log "当前虚拟机状态："
    qm list | grep -E "(VMID|101|102|103)"
    
    log "虚拟机创建和启动完成"
    return 0
}

# 修正已存在虚拟机的cloud-init配置
fix_existing_vms() {
    log "修正已存在虚拟机的cloud-init配置..."
    
    # 确保cloud-init自定义配置存在
    log "确保cloud-init自定义配置存在..."
    mkdir -p /var/lib/vz/snippets
    CLOUDINIT_CUSTOM_USERCFG="/var/lib/vz/snippets/debian-root.yaml"
    
    # 创建更可靠的cloud-init配置
    cat > "$CLOUDINIT_CUSTOM_USERCFG" <<EOF
#cloud-config
disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
  list: |
    root:$CLOUDINIT_PASS
runcmd:
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
  - grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
  - systemctl restart ssh
  - echo "root:$CLOUDINIT_PASS" | chpasswd
EOF

    log "Cloud-init配置文件内容:"
    cat "$CLOUDINIT_CUSTOM_USERCFG"

    for idx in ${!VM_IDS[@]}; do
        id=${VM_IDS[$idx]}
        name=${VM_NAMES[$idx]}
        ip=${VM_IPS[$idx]}
        if qm list | grep -q " $id "; then
            log "修正虚拟机 $id 的cloud-init配置..."
            # 停止虚拟机（如果正在运行）
            if qm status $id | grep -q "running"; then
                log "停止虚拟机 $id..."
                qm stop $id
                sleep 3
            fi
            # 更新cloud-init配置
            qm set $id --ciuser root --cipassword $CLOUDINIT_PASS
            qm set $id --ipconfig0 ip=$ip/24,gw=$GATEWAY
            qm set $id --nameserver "$DNS"
            qm set $id --cicustom "user=local:snippets/debian-root.yaml"
            log "虚拟机 $id 配置已修正"
        fi
    done
}

# 诊断单个虚拟机的cloud-init状态
diagnose_vm_cloudinit() {
    local vm_id=$1
    local vm_name=$2
    local vm_ip=$3
    
    log "诊断虚拟机 $vm_name (ID: $vm_id, IP: $vm_ip) 的cloud-init状态..."
    
    echo ""
    echo "${CYAN}=== 虚拟机 $vm_name 诊断信息 ===${NC}"
    
    # 检查虚拟机状态
    if qm list | grep -q " $vm_id "; then
        status=$(qm list | awk -v id="$vm_id" '$1==id{print $3}')
        echo "虚拟机状态: $status"
        
        if [ "$status" = "running" ]; then
            echo ""
            echo "${YELLOW}请手动执行以下诊断命令：${NC}"
            echo "1. 进入虚拟机控制台:"
            echo "   qm terminal $vm_id"
            echo ""
            echo "2. 在虚拟机内执行以下命令："
            echo "   # 检查cloud-init状态"
            echo "   cloud-init status --long"
            echo ""
            echo "   # 检查SSH服务状态"
            echo "   systemctl status ssh"
            echo ""
            echo "   # 检查网络配置"
            echo "   ip a"
            echo ""
            echo "   # 检查debug日志"
            echo "   cat /root/debug.log"
            echo ""
            echo "   # 尝试root登录"
            echo "   su - root"
            echo "   密码: $CLOUDINIT_PASS"
            echo ""
            echo "   # 检查cloud-init日志"
            echo "   journalctl -u cloud-init"
            echo ""
            echo "   # 检查SSH配置"
            echo "   cat /etc/ssh/sshd_config | grep -E '(PasswordAuthentication|PermitRootLogin)'"
            echo ""
            echo "   # 测试网络连通性"
            echo "   ping -c 3 $GATEWAY"
            echo ""
        else
            echo "虚拟机未运行，请先启动: qm start $vm_id"
        fi
    else
        echo "虚拟机不存在"
    fi
    
    echo ""
    echo "${CYAN}=== 网络连通性测试 ===${NC}"
    if ping -c 1 -W 2 $vm_ip &>/dev/null; then
        echo "✓ Ping $vm_ip 成功"
        if nc -z $vm_ip 22 &>/dev/null; then
            echo "✓ SSH端口22开放"
        else
            echo "✗ SSH端口22未开放"
        fi
    else
        echo "✗ Ping $vm_ip 失败"
    fi
    
    echo ""
    echo "${CYAN}=== Cloud-init配置检查 ===${NC}"
    qm config $vm_id | grep -E "(ciuser|cipassword|ipconfig|cicustom)" | sed 's/^/  /'
    
    echo ""
    echo "${CYAN}=== 建议的解决步骤 ===${NC}"
    echo "1. 如果cloud-init未生效，尝试重置："
    echo "   qm stop $vm_id"
    echo "   qm set $vm_id --ciuser root --cipassword $CLOUDINIT_PASS"
    echo "   qm start $vm_id"
    echo ""
    echo "2. 如果SSH服务未启动，手动启动："
    echo "   qm terminal $vm_id"
    echo "   systemctl enable ssh"
    echo "   systemctl start ssh"
    echo ""
    echo "3. 如果密码不正确，手动重置："
    echo "   qm terminal $vm_id"
    echo "   echo 'root:$CLOUDINIT_PASS' | chpasswd"
    echo ""
}

# 诊断cloud-init配置
diagnose_cloudinit() {
    log "诊断cloud-init配置..."
    
    echo ""
    echo "${CYAN}=== Cloud-init配置诊断 ===${NC}"
    
    # 检查配置文件
    if [ -f "$CLOUDINIT_CUSTOM_USERCFG" ]; then
        echo "✓ Cloud-init配置文件存在: $CLOUDINIT_CUSTOM_USERCFG"
        echo "配置文件内容:"
        cat "$CLOUDINIT_CUSTOM_USERCFG"
    else
        echo "✗ Cloud-init配置文件不存在: $CLOUDINIT_CUSTOM_USERCFG"
        echo "建议运行选项4: 修正已存在虚拟机配置"
    fi
    
    echo ""
    echo "${CYAN}=== 虚拟机状态检查 ===${NC}"
    for idx in ${!VM_IDS[@]}; do
        id=${VM_IDS[$idx]}
        name=${VM_NAMES[$idx]}
        ip=${VM_IPS[$idx]}
        
        echo "虚拟机 $name (ID: $id, IP: $ip):"
        
        # 检查虚拟机状态
        if qm list | grep -q " $id "; then
            status=$(qm list | awk -v id="$id" '$1==id{print $3}')
            echo "  状态: $status"
            
            # 检查cloud-init配置
            echo "  Cloud-init配置:"
            qm config $id | grep -E "(ciuser|cipassword|ipconfig|cicustom)" | sed 's/^/    /'
            
            # 检查网络连通性
            if ping -c 1 -W 2 $ip &>/dev/null; then
                echo "  网络: ✓ 可达"
                if nc -z $ip 22 &>/dev/null; then
                    echo "  SSH: ✓ 端口开放"
                else
                    echo "  SSH: ✗ 端口未开放"
                fi
            else
                echo "  网络: ✗ 不可达"
            fi
        else
            echo "  ✗ 虚拟机不存在"
        fi
        echo ""
    done
    
    echo "${CYAN}=== 手动测试SSH连接 ===${NC}"
    echo "如果SSH连接失败，请手动测试："
    for idx in ${!VM_IDS[@]}; do
        ip=${VM_IPS[$idx]}
        echo "sshpass -p '$CLOUDINIT_PASS' ssh -o StrictHostKeyChecking=no root@$ip"
    done
    echo ""
}

# 主菜单
show_menu() {
    clear
    echo -e "${CYAN}================================${NC}"
    echo -e "${CYAN}  PVE K8S+KubeSphere 部署工具${NC}"
    echo -e "${CYAN}================================${NC}"
    echo -e "${YELLOW}1.${NC} 诊断PVE环境"
    echo -e "${YELLOW}2.${NC} 下载Debian Cloud镜像"
    echo -e "${YELLOW}3.${NC} 创建并启动虚拟机"
    echo -e "${YELLOW}4.${NC} 修正已存在虚拟机配置"
    echo -e "${YELLOW}5.${NC} 部署K8S集群"
    echo -e "${YELLOW}6.${NC} 部署KubeSphere"
    echo -e "${YELLOW}7.${NC} 清理所有资源"
    echo -e "${YELLOW}8.${NC} 一键全自动部署"
    echo -e "${YELLOW}9.${NC} 诊断Cloud-init配置"
    echo -e "${YELLOW}10.${NC} 诊断单个虚拟机"
    echo -e "${YELLOW}11.${NC} 升级K8S和KubeSphere"
    echo -e "${YELLOW}0.${NC} 退出"
    echo -e "${CYAN}================================${NC}"
}

# 清理虚拟机资源
clean_vms() {
    echo "=========================================="
    echo "清理虚拟机资源"
    echo "=========================================="
    
    # 检查PVE环境
    if ! command -v qm &>/dev/null; then
        err "qm命令不可用，请确保在PVE环境中运行"
        return 1
    fi
    
    log "检查现有虚拟机..."
    qm list | grep -E "(VMID|101|102|103)" || echo "未找到目标虚拟机"
    
    echo ""
    echo "即将清理以下虚拟机："
    for idx in ${!VM_IDS[@]}; do
        id=${VM_IDS[$idx]}
        name=${VM_NAMES[$idx]}
        echo "  - $name (ID: $id)"
    done
    
    echo ""
    read -p "确认要删除这些虚拟机吗？(y/N): " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        log "开始清理虚拟机..."
        for id in "${VM_IDS[@]}"; do
            if qm list | grep -q " $id "; then
                log "停止虚拟机 $id..."
                qm stop $id 2>/dev/null || true
                sleep 2
                log "删除虚拟机 $id..."
                qm destroy $id 2>/dev/null || true
                log "虚拟机 $id 已删除"
            else
                warn "虚拟机 $id 不存在，跳过"
            fi
        done
        log "清理完成"
    else
        log "取消清理操作"
    fi
}

# 查看部署信息
show_info() {
    echo "=========================================="
    echo "部署信息"
    echo "=========================================="
    
    echo ""
    echo "${CYAN}虚拟机配置：${NC}"
    for idx in ${!VM_IDS[@]}; do
        id=${VM_IDS[$idx]}
        name=${VM_NAMES[$idx]}
        ip=${VM_IPS[$idx]}
        echo "  $name: ID=$id, IP=$ip"
    done
    
    echo ""
    echo "${CYAN}资源分配：${NC}"
    echo "  CPU: ${VM_CORES}核/节点"
    echo "  内存: ${VM_MEM}MB/节点"
    echo "  存储: ${VM_DISK}GB/节点"
    
    echo ""
    echo "${CYAN}网络配置：${NC}"
    echo "  网桥: $BRIDGE"
    echo "  网关: $GATEWAY"
    echo "  DNS: $DNS"
    echo "  用户: $CLOUDINIT_USER"
    echo "  密码: $CLOUDINIT_PASS"
    
    echo ""
    echo "${CYAN}访问信息：${NC}"
    echo "  KubeSphere控制台: http://$MASTER_IP:30880"
    echo "  用户名: admin"
    echo "  密码: P@88w0rd"
    
    echo ""
    echo "${CYAN}系统要求：${NC}"
    echo "  总内存需求: $((VM_MEM * 3 / 1024))GB"
    echo "  总存储需求: $((VM_DISK * 3))GB"
    echo "  总CPU需求: $((VM_CORES * 3))核"
    
    echo ""
    echo "=========================================="
}

# 检查依赖
check_dependencies() {
    for cmd in qm wget sshpass nc; do
        if ! command -v $cmd &>/dev/null; then
            err "缺少依赖: $cmd，请先安装！"
            echo -e "\n[解决方法] 运行: apt update && apt install -y $cmd\n"
            exit 1
        fi
    done
}

wait_for_ssh() {
    local ip=$1
    local max_try=60  # 增加等待时间到60次
    local try=0
    log "开始等待 $ip SSH可用..."
    while ((try < max_try)); do
        if ping -c 1 -W 2 $ip &>/dev/null; then
            debug "Ping $ip 成功"
            if nc -z $ip 22 &>/dev/null; then
                log "$ip SSH端口已开放"
                # 额外等待几秒确保SSH服务完全启动
                sleep 10
                return 0
            else
                debug "$ip SSH端口未开放"
            fi
        else
            debug "Ping $ip 失败"
        fi
        sleep 10  # 增加等待间隔
        ((try++))
        log "等待 $ip SSH可用... ($try/$max_try)"
    done
    err "$ip SSH不可用，可能原因：\n- 虚拟机未获取到IP\n- cloud-init未生效或root密码未设置\n- 网络未通或防火墙阻断"
    return 1
}

wait_for_port() {
    local ip=$1
    local port=$2
    local max_try=60
    local try=0
    while ((try < max_try)); do
        if nc -z $ip $port &>/dev/null; then
            return 0
        fi
        sleep 10
        ((try++))
        log "等待 $ip:$port 可用... ($try/$max_try)"
    done
    err "$ip:$port 未开放，可能原因：\n- KubeSphere服务未启动或安装失败\n- 网络/防火墙阻断\n- 资源不足导致服务未正常运行"
    exit 1
}

# 部署K8S集群
deploy_k8s() {
    log "开始部署K8S集群..."
    
    # 等待所有虚拟机SSH可用
    log "开始等待所有虚拟机SSH可用..."
    for idx in ${!VM_IDS[@]}; do
        ip=${VM_IPS[$idx]}
        name=${VM_NAMES[$idx]}
        log "等待 $name ($ip) SSH可用..."
        if ! wait_for_ssh $ip; then
            err "等待 $name SSH失败，终止脚本"
            return 1
        fi
        log "虚拟机 $name ($ip) SSH已就绪"
    done

    # SSH初始化
    log "批量SSH初始化..."
    for idx in ${!VM_IDS[@]}; do
        name=${VM_NAMES[$idx]}
        ip=${VM_IPS[$idx]}
        log "初始化 $name ($ip) ..."
        
        # 增加SSH连接重试机制
        SSH_OK=0
        for ssh_try in {1..10}; do
            ssh-keygen -R "$ip" 2>/dev/null
            log "测试 $name SSH连接... (尝试 $ssh_try/10)"
            
            # 先测试基本连接
            if ! ping -c 1 -W 2 $ip &>/dev/null; then
                warn "Ping $ip 失败，跳过SSH测试"
                break
            fi
            
            # 测试SSH端口
            if ! nc -z $ip 22 &>/dev/null; then
                warn "SSH端口22未开放，等待10秒后重试..."
                sleep 10
                continue
            fi
            
            # 尝试SSH连接，增加详细输出
            log "尝试SSH连接到 $ip (用户: $CLOUDINIT_USER, 密码: $CLOUDINIT_PASS)"
            if sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=yes $CLOUDINIT_USER@$ip "echo 'SSH连接测试成功'" 2>&1 | tee /tmp/ssh_debug.log; then
                # 检查是否真的连接成功（没有Permission denied等错误）
                if grep -q "Permission denied\|Authentication failed" /tmp/ssh_debug.log; then
                    warn "SSH连接失败：认证失败"
                    SSH_OK=0
                else
                    SSH_OK=1
                    log "$name SSH连接成功"
                    break
                fi
            else
                SSH_OK=0
            fi
            
            if [ $SSH_OK -eq 0 ]; then
                err "$name SSH连接最终失败，尝试诊断cloud-init状态..."
                
                # 尝试通过qm terminal诊断
                log "通过qm terminal诊断虚拟机状态..."
                log "请手动执行以下命令诊断："
                log "qm terminal ${VM_IDS[$idx]}"
                log "然后在虚拟机内执行："
                log "  - 检查cloud-init状态: cloud-init status --long"
                log "  - 检查SSH服务: systemctl status ssh"
                log "  - 检查网络: ip a"
                log "  - 检查debug日志: cat /root/debug.log"
                log "  - 尝试登录: su - root (密码: $CLOUDINIT_PASS)"
                
                # 尝试使用简化配置
                log "停止虚拟机 ${VM_IDS[$idx]}..."
                qm stop ${VM_IDS[$idx]} 2>/dev/null || true
                sleep 5
                
                log "切换到简化cloud-init配置..."
                qm set ${VM_IDS[$idx]} --ciuser root --cipassword $CLOUDINIT_PASS
                qm set ${VM_IDS[$idx]} --ipconfig0 ip=$ip/24,gw=$GATEWAY
                qm set ${VM_IDS[$idx]} --nameserver "$DNS"
                qm set ${VM_IDS[$idx]} --cicustom "user=local:snippets/debian-simple.yaml"
                
                log "重新启动虚拟机 ${VM_IDS[$idx]}..."
                qm start ${VM_IDS[$idx]}
                sleep 45  # 给更多时间让cloud-init生效
                
                # 再次尝试SSH连接
                log "重新尝试SSH连接（简化配置）..."
                for retry in {1..5}; do
                    if sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=yes $CLOUDINIT_USER@$ip "echo 'SSH连接测试成功'" 2>&1 | tee /tmp/ssh_simple.log; then
                        if ! grep -q "Permission denied\|Authentication failed" /tmp/ssh_simple.log; then
                            SSH_OK=1
                            log "$name SSH连接成功（简化配置）"
                            break
                        fi
                    fi
                    warn "简化配置后SSH连接仍然失败，重试 $retry/5"
                    sleep 15
                done
                
                if [ $SSH_OK -eq 0 ]; then
                    err "$name SSH连接最终失败，请检查："
                    err "  1. 虚拟机是否正常启动: qm status ${VM_IDS[$idx]}"
                    err "  2. cloud-init是否生效: qm config ${VM_IDS[$idx]} | grep cicustom"
                    err "  3. 网络是否连通: ping $ip"
                    err "  4. SSH端口是否开放: nc -z $ip 22"
                    err "  5. 尝试手动SSH: sshpass -p '$CLOUDINIT_PASS' ssh root@$ip"
                    err ""
                    err "手动诊断步骤："
                    err "  1. 进入虚拟机: qm terminal ${VM_IDS[$idx]}"
                    err "  2. 检查cloud-init: cloud-init status --long"
                    err "  3. 检查SSH服务: systemctl status ssh"
                    err "  4. 检查网络: ip a"
                    err "  5. 查看debug日志: cat /root/debug.log"
                    err "  6. 尝试root登录: su - root (密码: $CLOUDINIT_PASS)"
                    err ""
                    err "如果问题持续，可以尝试手动重置密码："
                    err "  1. 停止虚拟机: qm stop ${VM_IDS[$idx]}"
                    err "  2. 重置cloud-init: qm set ${VM_IDS[$idx]} --ciuser root --cipassword $CLOUDINIT_PASS"
                    err "  3. 启动虚拟机: qm start ${VM_IDS[$idx]}"
                    err "  4. 等待2-3分钟后重试SSH连接"
                    return 1
                fi
            fi
        done
        
        if [ $SSH_OK -eq 0 ]; then
            err "$name SSH连接最终失败，请检查："
            err "  1. 虚拟机是否正常启动: qm status ${VM_IDS[$idx]}"
            err "  2. cloud-init是否生效: qm config ${VM_IDS[$idx]} | grep cicustom"
            err "  3. 网络是否连通: ping $ip"
            err "  4. SSH端口是否开放: nc -z $ip 22"
            err "  5. 尝试手动SSH: sshpass -p '$CLOUDINIT_PASS' ssh root@$ip"
            err ""
            err "手动诊断步骤："
            err "  1. 进入虚拟机: qm terminal ${VM_IDS[$idx]}"
            err "  2. 检查cloud-init: cloud-init status --long"
            err "  3. 检查SSH服务: systemctl status ssh"
            err "  4. 检查网络: ip a"
            err "  5. 查看debug日志: cat /root/debug.log"
            err "  6. 尝试root登录: su - root (密码: $CLOUDINIT_PASS)"
            err ""
            err "如果问题持续，可以尝试手动重置密码："
            err "  1. 停止虚拟机: qm stop ${VM_IDS[$idx]}"
            err "  2. 重置cloud-init: qm set ${VM_IDS[$idx]} --ciuser root --cipassword $CLOUDINIT_PASS"
            err "  3. 启动虚拟机: qm start ${VM_IDS[$idx]}"
            err "  4. 等待2-3分钟后重试SSH连接"
            return 1
        fi
    done

    # 1. K8S master初始化（重试）
    log "[K8S] master节点初始化..."
    K8S_INIT_OK=0
    for try in {1..3}; do
        log "K8S master初始化尝试 $try/3..."
        ssh-keygen -R "$MASTER_IP" 2>/dev/null
        
        # 先清理可能存在的K8S配置
        log "清理可能存在的K8S配置..."
        cleanup_cmd='set -e
echo "[K8S] 清理旧配置..." | tee -a /root/k8s-init.log
# 停止kubelet
systemctl stop kubelet 2>/dev/null || true
# 清理kubeadm配置
kubeadm reset -f 2>/dev/null || true
# 清理etcd数据
rm -rf /var/lib/etcd/* 2>/dev/null || true
# 清理kubelet配置
rm -rf /var/lib/kubelet/* 2>/dev/null || true
# 清理manifests
rm -rf /etc/kubernetes/manifests/* 2>/dev/null || true
# 清理kubeconfig
rm -rf /root/.kube 2>/dev/null || true
# 清理iptables规则
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X 2>/dev/null || true
# 清理网络接口
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true
# 等待端口释放
sleep 5
echo "[K8S] 清理完成" | tee -a /root/k8s-init.log'
        
        sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "bash -c '$cleanup_cmd'" || true
        
        remote_cmd='set -e
'\
'echo "[K8S] 步骤0: 加载br_netfilter并设置内核参数..." | tee -a /root/k8s-init.log
modprobe br_netfilter
 echo "br_netfilter" > /etc/modules-load.d/br_netfilter.conf
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system 2>&1 | tee -a /root/k8s-init.log
'\
'echo "[K8S] 步骤0.5: 安装containerd..." | tee -a /root/k8s-init.log
apt-get update 2>&1 | tee -a /root/k8s-init.log
apt-get install -y containerd 2>&1 | tee -a /root/k8s-init.log
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd
'\
'echo "[K8S] 步骤1: apt-get update..." | tee -a /root/k8s-init.log
apt-get update -y 2>&1 | tee -a /root/k8s-init.log
'\
'echo "[K8S] 步骤2: 安装依赖..." | tee -a /root/k8s-init.log
apt-get install -y apt-transport-https ca-certificates curl gnupg2 software-properties-common 2>&1 | tee -a /root/k8s-init.log
'\
'echo "[K8S] 步骤3: 添加K8S源..." | tee -a /root/k8s-init.log
curl -fsSL https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg 2>&1 | tee -a /root/k8s-init.log
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y 2>&1 | tee -a /root/k8s-init.log
'\
'echo "[K8S] 步骤4: 安装K8S组件..." | tee -a /root/k8s-init.log
apt-get install -y kubelet kubeadm kubectl 2>&1 | tee -a /root/k8s-init.log
'\
'echo "[K8S] 步骤5: 关闭swap..." | tee -a /root/k8s-init.log
swapoff -a 2>&1 | tee -a /root/k8s-init.log
sed -i "/ swap / s/^/#/" /etc/fstab
'\
'echo "[K8S] 步骤6: kubeadm init..." | tee -a /root/k8s-init.log
kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-advertise-address=$MASTER_IP --ignore-preflight-errors=NumCPU --ignore-preflight-errors=Mem --ignore-preflight-errors=Port-10257 --ignore-preflight-errors=Port-10250 --ignore-preflight-errors=FileAvailable--etc-kubernetes-manifests-kube-apiserver.yaml --ignore-preflight-errors=FileAvailable--etc-kubernetes-manifests-kube-controller-manager.yaml --ignore-preflight-errors=FileAvailable--etc-kubernetes-manifests-kube-scheduler.yaml --ignore-preflight-errors=FileAvailable--etc-kubernetes-manifests-etcd.yaml --ignore-preflight-errors=DirAvailable--var-lib-etcd 2>&1 | tee -a /root/k8s-init.log
'\
'echo "[K8S] 步骤7: 配置kubectl..." | tee -a /root/k8s-init.log
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
'\
'echo "[K8S] 步骤8: 去除master污点..." | tee -a /root/k8s-init.log
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>&1 | tee -a /root/k8s-init.log
'\
'echo "[K8S] 步骤9: 安装Calico网络..." | tee -a /root/k8s-init.log
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml 2>&1 | tee -a /root/k8s-init.log
'\
'echo "[K8S] master初始化完成" | tee -a /root/k8s-init.log
'
        if sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "bash -c '$remote_cmd'"; then
            K8S_INIT_OK=1
            log "K8S master初始化成功"
            break
        fi
        warn "K8S master初始化失败，重试($try/3)"
        log "[K8S] 收集诊断日志..."
        ssh-keygen -R "$MASTER_IP" 2>/dev/null
        sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "tail -n 50 /root/k8s-init.log || true; tail -n 50 /var/log/syslog || true; journalctl -xe --no-pager | tail -n 50 || true; dmesg | tail -n 30 || true" || true
        sleep 30
    done
    [ $K8S_INIT_OK -eq 1 ] || { err "K8S master初始化最终失败，请查看 /root/k8s-init.log 及上方诊断信息"; return 1; }

    # 2. 获取join命令（重试）
    log "获取K8S join命令..."
    JOIN_CMD=""
    for try in {1..10}; do
        log "获取join命令尝试 $try/10..."
        JOIN_CMD=$(sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "kubeadm token create --print-join-command" 2>/dev/null || true)
        if [[ $JOIN_CMD == kubeadm* ]]; then
            log "成功获取join命令"
            break
        fi
        warn "获取join命令失败，重试($try/10)"
        sleep 15
    done
    if [[ ! $JOIN_CMD == kubeadm* ]]; then
        err "无法获取K8S join命令，终止"
        return 1
    fi

    # 3. worker节点加入集群（重试）
    for ip in "${WORKER_IPS[@]}"; do
        log "[K8S] $ip 加入集群..."
        JOIN_OK=0
        for try in {1..3}; do
            ssh-keygen -R "$ip" 2>/dev/null
            log "$ip 加入集群尝试 $try/3..."
            
            # 先清理worker节点的K8S配置
            log "清理worker节点 $ip 的K8S配置..."
            cleanup_worker_cmd='set -e
echo "[K8S] 清理worker节点旧配置..." | tee -a /root/k8s-worker-join.log
# 停止kubelet
systemctl stop kubelet 2>/dev/null || true
# 清理kubeadm配置
kubeadm reset -f 2>/dev/null || true
# 清理etcd数据
rm -rf /var/lib/etcd/* 2>/dev/null || true
# 清理kubelet配置
rm -rf /var/lib/kubelet/* 2>/dev/null || true
# 清理manifests
rm -rf /etc/kubernetes/manifests/* 2>/dev/null || true
# 清理kubeconfig
rm -rf /root/.kube 2>/dev/null || true
# 清理iptables规则
iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X 2>/dev/null || true
# 清理网络接口
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true
# 等待端口释放
sleep 5
echo "[K8S] worker节点清理完成" | tee -a /root/k8s-worker-join.log'
            
            sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60 -o UserKnownHostsFile=/dev/null $CLOUDINIT_USER@$ip "bash -c '$cleanup_worker_cmd'" || true
            
            remote_cmd='set -e
'\
'echo "[K8S] worker节点准备加入集群..." | tee -a /root/k8s-worker-join.log
apt-get update -y 2>&1 | tee -a /root/k8s-worker-join.log
apt-get install -y apt-transport-https ca-certificates curl gnupg2 software-properties-common 2>&1 | tee -a /root/k8s-worker-join.log
curl -fsSL https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg 2>&1 | tee -a /root/k8s-worker-join.log
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y 2>&1 | tee -a /root/k8s-worker-join.log
apt-get install -y kubelet kubeadm kubectl 2>&1 | tee -a /root/k8s-worker-join.log
swapoff -a 2>&1 | tee -a /root/k8s-worker-join.log
sed -i "/ swap / s/^/#/" /etc/fstab
modprobe br_netfilter
 echo "br_netfilter" > /etc/modules-load.d/br_netfilter.conf
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system 2>&1 | tee -a /root/k8s-worker-join.log
'\
'echo "[K8S] 安装和配置containerd..." | tee -a /root/k8s-worker-join.log
# 安装containerd
apt-get install -y containerd 2>&1 | tee -a /root/k8s-worker-join.log
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
# 确保containerd启动
systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd
# 等待containerd完全启动
sleep 10
# 检查containerd状态
systemctl status containerd 2>&1 | tee -a /root/k8s-worker-join.log
# 检查containerd socket
ls -la /var/run/containerd/containerd.sock 2>&1 | tee -a /root/k8s-worker-join.log || echo "containerd socket不存在" | tee -a /root/k8s-worker-join.log
'\
'echo "[K8S] worker节点执行join..." | tee -a /root/k8s-worker-join.log
'"$JOIN_CMD --ignore-preflight-errors=NumCPU --ignore-preflight-errors=Mem --ignore-preflight-errors=CRI 2>&1 | tee -a /root/k8s-worker-join.log"'
'
            if sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60 -o UserKnownHostsFile=/dev/null $CLOUDINIT_USER@$ip "bash -c '$remote_cmd'"; then
                JOIN_OK=1
                log "$ip 加入集群成功"
                break
            fi
            warn "$ip 加入集群失败，重试($try/3)"
            log "[K8S] 收集worker诊断日志..."
            ssh-keygen -R "$ip" 2>/dev/null
            sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o UserKnownHostsFile=/dev/null $CLOUDINIT_USER@$ip "\
                echo '==== /root/k8s-worker-join.log ===='; tail -n 50 /root/k8s-worker-join.log 2>/dev/null; \
                echo '==== containerd status ===='; systemctl status containerd 2>&1 | tail -n 20; \
                echo '==== kubelet status ===='; systemctl status kubelet 2>&1 | tail -n 20; \
                echo '==== ping master ===='; ping -c 3 $MASTER_IP; \
                echo '==== telnet master 6443 ===='; (command -v telnet && telnet $MASTER_IP 6443 < /dev/null) || echo 'telnet not installed'; \
                echo '==== journalctl -xe ===='; journalctl -xe --no-pager | tail -n 50; \
            " || true
            sleep 30
        done
        [ $JOIN_OK -eq 1 ] || { err "$ip 加入集群最终失败，请查看 /root/k8s-worker-join.log 及上方诊断信息"; return 1; }
    done

    # 4. 检查K8S集群状态
    log "[K8S] 检查集群状态..."
    sleep 30  # 等待集群稳定
    
    # 详细的集群状态检查
    log "执行详细的集群状态检查..."
    cluster_check_cmd='
echo "=== K8S集群状态检查 ==="
echo ""
echo "1. 节点状态:"
kubectl get nodes -o wide 2>/dev/null || echo "无法获取节点信息"
echo ""
echo "2. Pod状态:"
kubectl get pods -A 2>/dev/null || echo "无法获取Pod信息"
echo ""
echo "3. 系统Pod状态:"
kubectl get pods -n kube-system 2>/dev/null || echo "无法获取kube-system Pod信息"
echo ""
echo "4. 服务状态:"
kubectl get svc -A 2>/dev/null || echo "无法获取服务信息"
echo ""
echo "5. 事件信息:"
kubectl get events --sort-by=.metadata.creationTimestamp | tail -20 2>/dev/null || echo "无法获取事件信息"
echo ""
echo "6. 集群信息:"
kubectl cluster-info 2>/dev/null || echo "无法获取集群信息"
echo ""
echo "=== 检查完成 ==="
'
    
    if sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "bash -c '$cluster_check_cmd'"; then
        log "K8S集群状态检查完成"
        
        # 检查是否有Ready节点
        READY_NODES=$(sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "kubectl get nodes --no-headers | grep -c ' Ready ' 2>/dev/null || echo '0'")
        TOTAL_NODES=$(sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "kubectl get nodes --no-headers | wc -l 2>/dev/null || echo '0'")
        
        log "集群节点状态: $READY_NODES/$TOTAL_NODES 节点就绪"
        
        if [ "$READY_NODES" -gt 0 ]; then
            log "K8S集群部署成功！"
            return 0
        else
            err "没有节点处于Ready状态，集群可能存在问题"
            return 1
        fi
    else
        err "K8S集群状态检查失败，请检查deploy.log和K8S安装日志"
        return 1
    fi
}

# 新增：一键升级K8S和KubeSphere
upgrade_k8s_kubesphere() {
    log "开始升级K8S和KubeSphere到最新版..."
    # 升级K8S（master和所有node）
    for idx in ${!VM_IDS[@]}; do
        ip=${VM_IPS[$idx]}
        name=${VM_NAMES[$idx]}
        log "升级 $name ($ip) ..."
        ssh-keygen -R "$ip" 2>/dev/null
        upgrade_cmd='set -e
apt-mark unhold kubelet kubeadm kubectl || true
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
kubeadm upgrade plan || true
kubeadm upgrade apply -y || true
systemctl restart kubelet || true'
        sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60 -o UserKnownHostsFile=/dev/null $CLOUDINIT_USER@$ip "bash -c '$upgrade_cmd'" || warn "$name 升级K8S失败"
    done
    # 升级KubeSphere（只在master）
    log "升级KubeSphere（master节点）..."
    ssh-keygen -R "$MASTER_IP" 2>/dev/null
    ks_upgrade_cmd='set -e
cd /root || cd ~
curl -sfL https://get-kk.kubesphere.io | VERSION=latest sh -
./kk upgrade -f config-sample.yaml || ./kk create cluster -f config-sample.yaml || ./kk create cluster'
    sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=120 -o UserKnownHostsFile=/dev/null $CLOUDINIT_USER@$MASTER_IP "bash -c '$ks_upgrade_cmd'" || warn "KubeSphere升级失败"
    log "升级流程结束，请检查各节点状态。"
}

# 修改K8S和KubeSphere安装逻辑，始终安装最新版
# K8S安装部分已默认用apt最新包，不指定版本
# KubeSphere安装部分：
deploy_kubesphere() {
    log "开始部署KubeSphere..."
    # 检查K8S集群状态
    log "检查K8S集群状态..."
    if ! sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "kubectl get nodes" 2>/dev/null; then
        err "K8S集群未就绪，请先部署K8S集群"
        return 1
    fi
    # 安装KubeSphere最新版
    log "在master节点安装KubeSphere（使用kubectl方式）..."
    remote_cmd='set -e
cd /root || cd ~
echo "[KubeSphere] 开始安装KubeSphere..." | tee -a /root/kubesphere-install.log

# 直接使用kubectl安装KubeSphere
echo "[KubeSphere] 使用kubectl直接安装KubeSphere..." | tee -a /root/kubesphere-install.log

# 下载并应用KubeSphere installer
echo "[KubeSphere] 下载KubeSphere installer..." | tee -a /root/kubesphere-install.log
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml 2>&1 | tee -a /root/kubesphere-install.log

# 下载并应用集群配置
echo "[KubeSphere] 下载集群配置..." | tee -a /root/kubesphere-install.log
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml 2>&1 | tee -a /root/kubesphere-install.log

echo "[KubeSphere] 安装命令已执行，等待安装开始..." | tee -a /root/kubesphere-install.log

# 等待安装pod启动
echo "[KubeSphere] 等待安装pod启动..." | tee -a /root/kubesphere-install.log
sleep 30

# 检查安装状态
echo "[KubeSphere] 检查安装状态..." | tee -a /root/kubesphere-install.log
kubectl get pod -n kubesphere-system 2>/dev/null | tee -a /root/kubesphere-install.log || echo "kubesphere-system命名空间不存在，安装可能还在进行中" | tee -a /root/kubesphere-install.log

# 获取安装pod名称并显示日志
echo "[KubeSphere] 获取安装进度..." | tee -a /root/kubesphere-install.log
INSTALLER_POD=$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
if [ -n "$INSTALLER_POD" ]; then
    echo "[KubeSphere] 安装pod: $INSTALLER_POD" | tee -a /root/kubesphere-install.log
    echo "[KubeSphere] 可以通过以下命令查看安装进度:" | tee -a /root/kubesphere-install.log
    echo "kubectl logs -n kubesphere-system $INSTALLER_POD -f" | tee -a /root/kubesphere-install.log
    echo "[KubeSphere] 当前安装日志:" | tee -a /root/kubesphere-install.log
    kubectl logs -n kubesphere-system $INSTALLER_POD --tail=20 2>/dev/null | tee -a /root/kubesphere-install.log || echo "无法获取安装日志" | tee -a /root/kubesphere-install.log
else
    echo "[KubeSphere] 未找到安装pod，可能安装还未开始" | tee -a /root/kubesphere-install.log
fi

# 检查NodePort服务
echo "[KubeSphere] 检查NodePort服务..." | tee -a /root/kubesphere-install.log
kubectl get svc -n kubesphere-system 2>/dev/null | tee -a /root/kubesphere-install.log || echo "未找到kubesphere-system服务" | tee -a /root/kubesphere-install.log

echo "[KubeSphere] 安装命令已执行，请等待安装完成" | tee -a /root/kubesphere-install.log
echo "[KubeSphere] 安装完成后，可以通过以下地址访问:" | tee -a /root/kubesphere-install.log
echo "http://$MASTER_IP:30880" | tee -a /root/kubesphere-install.log
echo "用户名: admin" | tee -a /root/kubesphere-install.log
echo "密码: P@88w0rd" | tee -a /root/kubesphere-install.log

echo "[KubeSphere] 安装完成" | tee -a /root/kubesphere-install.log'
    
    if ! sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "$remote_cmd" 2>/dev/null; then
        err "KubeSphere安装失败，命令: $remote_cmd"
        echo "[建议] 检查KubeSphere安装日志、PVE资源、网络等。"
        return 1
    fi
    
    # 检查安装状态
    log "检查KubeSphere安装状态..."
    sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "
        echo '=== KubeSphere安装状态 ==='
        kubectl get pod -n kubesphere-system 2>/dev/null || echo 'kubesphere-system命名空间不存在'
        echo ''
        echo '=== 安装日志 ==='
        INSTALLER_POD=\$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')
        if [ -n \"\$INSTALLER_POD\" ]; then
            kubectl logs -n kubesphere-system \$INSTALLER_POD --tail=10 2>/dev/null || echo '无法获取安装日志'
        else
            echo '未找到安装pod'
        fi
    " || true
    
    # 不等待端口，因为安装可能需要很长时间
    log "KubeSphere安装命令已执行，安装过程可能需要10-30分钟"
    log "您可以通过以下方式监控安装进度："
    log "1. SSH到master节点: ssh root@$MASTER_IP"
    log "2. 查看安装日志: kubectl logs -n kubesphere-system \$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath='{.items[0].metadata.name}') -f"
    log "3. 检查pod状态: kubectl get pod -n kubesphere-system"
    log ""
    log "安装完成后，可以通过以下地址访问KubeSphere："
    log "KubeSphere控制台: http://$MASTER_IP:30880"
    log "默认用户名: admin"
    log "默认密码: P@88w0rd"
    
    # 询问用户是否要等待安装完成
    echo ""
    read -p "是否要等待KubeSphere安装完成？(y/N): " wait_install
    if [[ $wait_install =~ ^[Yy]$ ]]; then
        log "等待KubeSphere安装完成..."
        log "这可能需要10-30分钟，请耐心等待..."
        
        # 等待安装完成的循环
        INSTALL_TIMEOUT=1800  # 30分钟超时
        INSTALL_START=$(date +%s)
        INSTALL_SUCCESS=false
        
        while [ $(($(date +%s) - INSTALL_START)) -lt $INSTALL_TIMEOUT ]; do
            # 检查KubeSphere服务是否可用
            if sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "kubectl get svc -n kubesphere-system ks-console 2>/dev/null | grep -q NodePort"; then
                log "KubeSphere控制台服务已创建"
                if nc -z $MASTER_IP 30880 2>/dev/null; then
                    log "KubeSphere控制台端口30880已开放"
                    INSTALL_SUCCESS=true
                    break
                fi
            fi
            
            # 显示安装进度
            log "检查安装进度... ($(($(date +%s) - INSTALL_START))/1800秒)"
            sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "
                echo '=== 安装状态 ==='
                kubectl get pod -n kubesphere-system 2>/dev/null | head -5 || echo 'kubesphere-system命名空间不存在'
                echo ''
                echo '=== 最新日志 ==='
                INSTALLER_POD=\$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')
                if [ -n \"\$INSTALLER_POD\" ]; then
                    kubectl logs -n kubesphere-system \$INSTALLER_POD --tail=5 2>/dev/null || echo '无法获取安装日志'
                fi
            " || true
            
            sleep 60  # 每分钟检查一次
        done
        
        if [ "$INSTALL_SUCCESS" = true ]; then
            log "🎉 KubeSphere安装完成！"
            log "KubeSphere控制台: http://$MASTER_IP:30880"
            log "默认用户名: admin"
            log "默认密码: P@88w0rd"
        else
            warn "KubeSphere安装超时，但安装可能仍在进行中"
            log "请手动检查安装状态："
            log "ssh root@$MASTER_IP"
            log "kubectl get pod -n kubesphere-system"
            log "kubectl logs -n kubesphere-system \$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath='{.items[0].metadata.name}') -f"
        fi
    else
        log "KubeSphere安装命令已执行，请手动监控安装进度"
    fi
    
    echo ""
    read -p "按回车键返回主菜单..."
    return 0
}

# 清理所有资源
cleanup_all() {
    log "清理所有资源..."
    echo ""
    read -p "确认要清理所有虚拟机资源吗？(y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log "取消清理"
        return
    fi
    
    # 停止并删除虚拟机
    for id in "${VM_IDS[@]}"; do
        if qm list | grep -q " $id "; then
            log "停止虚拟机 $id..."
            qm stop $id 2>/dev/null || true
            sleep 2
            log "删除虚拟机 $id..."
            qm destroy $id 2>/dev/null || true
            log "虚拟机 $id 已删除"
        else
            warn "虚拟机 $id 不存在，跳过"
        fi
    done
    
    # 清理镜像文件
    if [ -f "$CLOUD_IMAGE_PATH" ]; then
        log "删除cloud镜像文件..."
        rm -f "$CLOUD_IMAGE_PATH"
    fi
    
    log "清理完成"
}

# 一键全自动部署
auto_deploy_all() {
    log "开始一键全自动部署..."
    echo ""
    read -p "确认开始全自动部署吗？这将执行完整的部署流程 (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log "取消部署"
        return
    fi
    
    # 设置日志文件
    LOGFILE="auto_deploy_$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "$LOGFILE") 2>&1
    trap 'err "脚本被中断或发生致命错误。请检查$LOGFILE，必要时清理部分资源后重试。"; exit 1' INT TERM
    
    log "=== 开始全自动部署流程 ==="
    
    # 步骤1: 诊断PVE环境
    log "步骤1: 诊断PVE环境..."
    if ! diagnose_pve; then
        err "PVE环境诊断失败，请检查环境后重试"
        exit 1
    fi
    
    # 步骤2: 下载Debian Cloud镜像
    log "步骤2: 下载Debian Cloud镜像..."
    if ! download_cloud_image; then
        err "下载Debian Cloud镜像失败，请检查网络连接"
        exit 1
    fi
    
    # 步骤3: 创建并启动虚拟机
    log "步骤3: 创建并启动虚拟机..."
    if ! create_and_start_vms; then
        err "创建虚拟机失败，请检查资源是否充足"
        exit 1
    fi
    
    # 步骤4: 等待虚拟机完全启动
    log "步骤4: 等待虚拟机完全启动..."
    log "等待30秒让虚拟机完全启动..."
    sleep 30
    
    # 步骤5: 部署K8S集群
    log "步骤5: 部署K8S集群..."
    if ! deploy_k8s; then
        err "K8S集群部署失败，请检查虚拟机状态和网络连接"
        exit 1
    fi
    
    # 步骤6: 部署KubeSphere
    log "步骤6: 部署KubeSphere..."
    if ! deploy_kubesphere; then
        err "KubeSphere部署失败，请检查K8S集群状态"
        exit 1
    fi
    
    log "=== 全自动部署完成 ==="
    log "部署日志已保存到: $LOGFILE"
    echo ""
    echo -e "${GREEN}🎉 部署成功！${NC}"
    echo ""
    echo -e "${CYAN}访问信息：${NC}"
    echo -e "  KubeSphere控制台: ${YELLOW}http://$MASTER_IP:30880${NC}"
    echo -e "  用户名: ${YELLOW}admin${NC}"
    echo -e "  密码: ${YELLOW}P@88w0rd${NC}"
    echo ""
    echo -e "${CYAN}虚拟机信息：${NC}"
    for idx in ${!VM_IDS[@]}; do
        id=${VM_IDS[$idx]}
        name=${VM_NAMES[$idx]}
        ip=${VM_IPS[$idx]}
        echo -e "  $name: ${YELLOW}SSH root@$ip${NC} (密码: $CLOUDINIT_PASS)"
    done
    echo ""
    echo -e "${CYAN}部署日志：${NC} $LOGFILE"
}

# 主程序
main() {
    # 如果没有命令行参数，显示交互式菜单
    if [ -z "$1" ]; then
        while true; do
            show_menu
            read -p "请选择操作 [0-11]: " choice
            case $choice in
                1) diagnose_pve ;;
                2) download_cloud_image ;;
                3) create_and_start_vms ;;
                4) fix_existing_vms ;;
                5) deploy_k8s ;;
                6) deploy_kubesphere ;;
                7) cleanup_all ;;
                8) auto_deploy_all ;;
                9) diagnose_cloudinit ;;
                10) 
                     echo ""
                     echo "选择要诊断的虚拟机："
                     for idx in ${!VM_IDS[@]}; do
                         echo "  $((idx+1)). ${VM_NAMES[$idx]} (ID: ${VM_IDS[$idx]}, IP: ${VM_IPS[$idx]})"
                     done
                     echo ""
                     read -p "请选择虚拟机 [1-${#VM_IDS[@]}]: " vm_choice
                     if [[ $vm_choice =~ ^[0-9]+$ ]] && [ $vm_choice -ge 1 ] && [ $vm_choice -le ${#VM_IDS[@]} ]; then
                         idx=$((vm_choice-1))
                         diagnose_vm_cloudinit ${VM_IDS[$idx]} ${VM_NAMES[$idx]} ${VM_IPS[$idx]}
                         echo ""
                         read -p "按回车键继续..."
                     else
                         echo "无效选择"
                         sleep 2
                     fi
                     ;;
                11) upgrade_k8s_kubesphere ;;
                0) log "退出程序"; exit 0 ;;
                *) echo -e "${RED}无效选择，请重新输入${NC}"; sleep 2 ;;
            esac
        done
    else
        # 如果有命令行参数，显示帮助信息
        echo "用法: $0"
        echo ""
        echo "无参数时显示交互式菜单"
        echo "支持的功能："
        echo "  1. 诊断PVE环境"
        echo "  2. 下载Debian Cloud镜像"
        echo "  3. 创建并启动虚拟机"
        echo "  4. 修正已存在虚拟机配置"
        echo "  5. 部署K8S集群"
        echo "  6. 部署KubeSphere"
        echo "  7. 清理所有资源"
        echo "  8. 一键全自动部署"
        echo "  9. 诊断Cloud-init配置"
        echo "  10. 诊断单个虚拟机"
        echo "  11. 升级K8S和KubeSphere"
        echo "  0. 退出"
        exit 1
    fi
}

# 运行主程序
main "$@" 