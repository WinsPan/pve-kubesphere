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
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; }
debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }

# 配置
# 使用Debian cloud镜像，支持cloud-init
CLOUD_IMAGE_URLS=(
  "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
  "https://mirrors.ustc.edu.cn/debian-cloud-images/bookworm/latest/debian-12-generic-amd64.qcow2"
  "https://mirrors.tuna.tsinghua.edu.cn/debian-cloud-images/bookworm/latest/debian-12-generic-amd64.qcow2"
)
CLOUD_IMAGE_FILE="debian-12-generic-amd64.qcow2"
CLOUD_IMAGE_PATH="/var/lib/vz/template/qcow/$CLOUD_IMAGE_FILE"

# 保留原有的ISO配置作为备用方案
ISO_URLS=(
  "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.11.0-amd64-netinst.iso"
  "https://mirrors.ustc.edu.cn/debian-cd/current/amd64/iso-cd/debian-12.11.0-amd64-netinst.iso"
  "https://mirrors.tuna.tsinghua.edu.cn/debian-cd/current/amd64/iso-cd/debian-12.11.0-amd64-netinst.iso"
)
ISO_FILE="debian-12.11.0-amd64-netinst.iso"
ISO_PATH="/var/lib/vz/template/iso/$ISO_FILE"
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

# 显示菜单
show_menu() {
    clear
    echo "=========================================="
    echo "    PVE K8S+KubeSphere 一键部署脚本"
    echo "=========================================="
    echo ""
    echo "请选择要执行的操作："
    echo ""
    echo "  ${GREEN}1${NC}) 部署K8S+KubeSphere集群"
    echo "  ${GREEN}2${NC}) 诊断系统状态"
    echo "  ${GREEN}3${NC}) 清理虚拟机资源"
    echo "  ${GREEN}4${NC}) 查看部署信息"
    echo "  ${GREEN}5${NC}) 检查依赖环境"
    echo "  ${GREEN}0${NC}) 退出"
    echo ""
    echo "=========================================="
    echo ""
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

# 检查依赖环境
check_environment() {
    echo "=========================================="
    echo "检查依赖环境"
    echo "=========================================="
    
    log "检查PVE环境..."
    if command -v qm &>/dev/null; then
        log "✓ qm命令可用"
    else
        err "✗ qm命令不可用，请确保在PVE环境中运行"
        return 1
    fi
    
    log "检查依赖工具..."
    local missing_deps=()
    for cmd in wget sshpass nc; do
        if command -v $cmd &>/dev/null; then
            log "✓ $cmd 已安装"
        else
            err "✗ $cmd 未安装"
            missing_deps+=($cmd)
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo ""
        warn "缺少以下依赖工具："
        for dep in "${missing_deps[@]}"; do
            echo "  - $dep"
        done
        echo ""
        echo "安装命令："
        echo "  apt update && apt install -y ${missing_deps[*]}"
        return 1
    fi
    
    log "检查系统资源..."
    echo ""
    echo "内存使用情况："
    free -h
    
    echo ""
    echo "磁盘使用情况："
    df -h | head -5
    
    echo ""
    echo "CPU信息："
    echo "  核心数: $(nproc)"
    lscpu | grep "Model name" | head -1
    
    log "环境检查完成"
    echo "=========================================="
}

# 处理命令行参数
handle_args() {
    case "$1" in
        "deploy")
            DIAGNOSE_MODE=false
            LOGFILE="deploy.log"
            exec > >(tee -a "$LOGFILE") 2>&1
            trap 'err "脚本被中断或发生致命错误。请检查$LOGFILE，必要时清理部分资源后重试。"; exit 1' INT TERM
            check_dependencies
            deploy_k8s
            ;;
        "diagnose")
            DIAGNOSE_MODE=true
            LOGFILE="diagnose.log"
            exec > >(tee -a "$LOGFILE") 2>&1
            trap 'err "脚本被中断或发生致命错误。请检查$LOGFILE，必要时清理部分资源后重试。"; exit 1' INT TERM
            diagnose_system
            ;;
        "clean")
            clean_vms
            ;;
        "info")
            show_info
            ;;
        "check")
            check_environment
            ;;
        "")
            # 无参数，显示菜单
            ;;
        *)
            echo "用法: $0 [deploy|diagnose|clean|info|check]"
            echo ""
            echo "选项："
            echo "  deploy   直接部署K8S+KubeSphere"
            echo "  diagnose 诊断系统状态"
            echo "  clean    清理虚拟机资源"
            echo "  info     查看部署信息"
            echo "  check    检查依赖环境"
            echo ""
            echo "无参数时显示交互式菜单"
            exit 1
            ;;
    esac
}

# 交互式菜单处理
interactive_menu() {
    while true; do
        show_menu
        read -p "请输入选项 (0-5): " choice
        
        case $choice in
            1)
                echo ""
                log "选择: 部署K8S+KubeSphere集群"
                echo ""
                read -p "确认开始部署吗？(y/N): " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    DIAGNOSE_MODE=false
                    LOGFILE="deploy.log"
                    exec > >(tee -a "$LOGFILE") 2>&1
                    trap 'err "脚本被中断或发生致命错误。请检查$LOGFILE，必要时清理部分资源后重试。"; exit 1' INT TERM
                    check_dependencies
                    deploy_k8s
                    break
                else
                    log "取消部署"
                    read -p "按回车键继续..."
                fi
                ;;
            2)
                echo ""
                log "选择: 诊断系统状态"
                echo ""
                DIAGNOSE_MODE=true
                LOGFILE="diagnose.log"
                exec > >(tee -a "$LOGFILE") 2>&1
                trap 'err "脚本被中断或发生致命错误。请检查$LOGFILE，必要时清理部分资源后重试。"; exit 1' INT TERM
                diagnose_system
                read -p "按回车键继续..."
                ;;
            3)
                echo ""
                log "选择: 清理虚拟机资源"
                echo ""
                clean_vms
                read -p "按回车键继续..."
                ;;
            4)
                echo ""
                log "选择: 查看部署信息"
                echo ""
                show_info
                read -p "按回车键继续..."
                ;;
            5)
                echo ""
                log "选择: 检查依赖环境"
                echo ""
                check_environment
                read -p "按回车键继续..."
                ;;
            0)
                echo ""
                log "退出程序"
                exit 0
                ;;
            *)
                echo ""
                err "无效选项，请重新选择"
                read -p "按回车键继续..."
                ;;
        esac
    done
}

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
                sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$ip "hostname && cat /etc/os-release | grep PRETTY_NAME && uname -a" 2>/dev/null || echo "    无法获取系统信息"
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

# 主部署函数
deploy_k8s() {
    # 下载Debian cloud镜像
    log "检查Debian cloud镜像..."
    if [ ! -f "$CLOUD_IMAGE_PATH" ]; then
        log "尝试多源下载Debian cloud镜像: $CLOUD_IMAGE_FILE"
        IMAGE_OK=0
        for url in "${CLOUD_IMAGE_URLS[@]}"; do
            log "尝试下载: $url"
            if wget -O "$CLOUD_IMAGE_PATH" "$url"; then
                IMAGE_OK=1
                break
            else
                warn "下载失败: $url"
            fi
        done
        if [ $IMAGE_OK -ne 1 ]; then
            err "Cloud镜像下载多次失败，尝试使用ISO方式..."
            # 如果cloud镜像下载失败，回退到ISO方式
            deploy_with_iso
            return
        fi
    else
        log "Cloud镜像已存在: $CLOUD_IMAGE_PATH"
    fi

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
        
        # 使用cloud镜像创建虚拟机
        if ! qm create $id \
            --name $name \
            --memory $VM_MEM \
            --cores $VM_CORES \
            --net0 virtio,bridge=$BRIDGE \
            --scsihw virtio-scsi-pci \
            --serial0 socket \
            --agent 1 \
            --scsi0 $STORAGE:$VM_DISK \
            --import-from $CLOUD_IMAGE_PATH; then
            err "创建虚拟机 $id 失败，请检查PVE资源和配置"
            exit 1
        fi
        
        # 配置cloud-init
        qm set $id --ide3 $STORAGE:cloudinit
        qm set $id --ciuser $CLOUDINIT_USER --cipassword $CLOUDINIT_PASS
        qm set $id --ipconfig0 ip=$ip/24,gw=$GATEWAY
        qm set $id --nameserver "$DNS"
        qm set $id --onboot 1
        
        # 调整磁盘大小
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
                exit 1
            fi
            log "虚拟机 $id 启动成功，等待5秒..."
            sleep 5
        fi
    done

    # 显示虚拟机状态
    log "当前虚拟机状态："
    qm list | grep -E "(VMID|101|102|103)"

    # 等待所有虚拟机SSH可用
    log "开始等待所有虚拟机SSH可用..."
    for idx in ${!VM_IDS[@]}; do
        ip=${VM_IPS[$idx]}
        name=${VM_NAMES[$idx]}
        log "等待 $name ($ip) SSH可用..."
        if ! wait_for_ssh $ip; then
            err "等待 $name SSH失败，终止脚本"
            exit 1
        fi
        log "虚拟机 $name ($ip) SSH已就绪"
    done

    # SSH初始化
    log "批量SSH初始化..."
    for idx in ${!VM_IDS[@]}; do
        name=${VM_NAMES[$idx]}
        ip=${VM_IPS[$idx]}
        log "初始化 $name ($ip) ..."
        
        # 先测试SSH连接
        log "测试 $name SSH连接..."
        if ! sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 $CLOUDINIT_USER@$ip "echo 'SSH连接测试成功'"; then
            err "$name SSH连接失败，请检查：\n- 虚拟机是否正常启动\n- cloud-init是否生效\n- root密码是否正确\n- 网络是否连通"
            exit 1
        fi
        
        # 执行初始化命令
        remote_cmd="hostnamectl set-hostname $name && apt-get update -y && apt-get install -y vim curl wget net-tools lsb-release sudo openssh-server && echo '初始化完成: $name'"
        log "执行初始化命令: $remote_cmd"
        if ! sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 $CLOUDINIT_USER@$ip "$remote_cmd"; then
            err "$name 初始化失败，命令: $remote_cmd"
            echo "[建议] 检查网络、cloud-init、root密码、PVE模板配置等。"
            exit 1
        fi
        log "$name 初始化成功"
    done

    log "所有虚拟机初始化完成，开始K8S部署..."

    # K8S和KubeSphere自动部署
    log "\n开始K8S集群和KubeSphere自动部署..."

    # 1. master节点初始化K8S（重试3次）
    log "[K8S] master节点初始化..."
    K8S_INIT_OK=0
    for try in {1..3}; do
        log "K8S master初始化尝试 $try/3..."
        remote_cmd="apt-get update -y && apt-get install -y apt-transport-https ca-certificates curl gnupg2 software-properties-common && curl -fsSL https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg && echo 'deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main' > /etc/apt/sources.list.d/kubernetes.list && apt-get update -y && apt-get install -y kubelet kubeadm kubectl && swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab && kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-advertise-address=$MASTER_IP --ignore-preflight-errors=NumCPU --ignore-preflight-errors=Mem && mkdir -p /root/.kube && cp /etc/kubernetes/admin.conf /root/.kube/config && kubectl taint nodes --all node-role.kubernetes.io/control-plane- && kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml && echo 'K8S master初始化完成'"
        if sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "$remote_cmd"; then
            K8S_INIT_OK=1
            log "K8S master初始化成功"
            break
        fi
        warn "K8S master初始化失败，重试($try/3)"
        sleep 30
    done
    [ $K8S_INIT_OK -eq 1 ] || { err "K8S master初始化最终失败"; exit 1; }

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
        exit 1
    fi

    # 3. worker节点加入集群（重试）
    for ip in "${WORKER_IPS[@]}"; do
        log "[K8S] $ip 加入集群..."
        JOIN_OK=0
        for try in {1..3}; do
            log "$ip 加入集群尝试 $try/3..."
            remote_cmd="apt-get update -y && apt-get install -y apt-transport-https ca-certificates curl gnupg2 software-properties-common && curl -fsSL https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg && echo 'deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main' > /etc/apt/sources.list.d/kubernetes.list && apt-get update -y && apt-get install -y kubelet kubeadm kubectl && swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab && $JOIN_CMD --ignore-preflight-errors=NumCPU --ignore-preflight-errors=Mem && echo 'K8S worker加入完成'"
            if sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$ip "$remote_cmd"; then
                JOIN_OK=1
                log "$ip 加入集群成功"
                break
            fi
            warn "$ip 加入集群失败，重试($try/3)"
            sleep 30
        done
        [ $JOIN_OK -eq 1 ] || { err "$ip 加入集群最终失败"; exit 1; }
    done

    # 4. 检查K8S集群状态
    log "[K8S] 检查集群状态..."
    sleep 30  # 等待集群稳定
    if ! sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "kubectl get nodes -o wide && kubectl get pods -A"; then
        err "K8S集群状态异常，请检查deploy.log和K8S安装日志"
        exit 1
    fi

    # 5. 安装KubeSphere
    log "[KubeSphere] master节点安装KubeSphere..."
    remote_cmd="curl -sfL https://get-ks.ksops.io | sh && ./kk create cluster -f ./config-sample.yaml || ./kk create cluster"
    if ! sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "$remote_cmd"; then
        err "KubeSphere安装失败，命令: $remote_cmd"
        echo "[建议] 检查KubeSphere安装日志、PVE资源、网络等。"
        exit 1
    fi

    # 6. 检查KubeSphere端口
    wait_for_port $MASTER_IP 30880
    log "KubeSphere控制台: http://$MASTER_IP:30880 (首次访问需等待几分钟)"
    log "默认用户名: admin，密码: P@88w0rd"
    log "全部自动化部署完成，详细日志见 $LOGFILE"
}

# 使用ISO方式的备用部署函数
deploy_with_iso() {
    log "使用ISO方式部署（需要手动安装）..."
    
    # 自动获取最新Debian netinst ISO文件名
    log "自动获取最新Debian ISO信息..."
    LATEST_ISO=$(wget -qO- https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ | grep -oE 'debian-[0-9.]+-amd64-netinst\.iso' | head -n1)
    if [ -z "$LATEST_ISO" ]; then
        err "无法自动获取最新Debian ISO文件名，请检查网络或手动指定。"
        echo -e "\n[解决方法] 请检查网络连接，或手动访问 https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ 获取最新ISO文件名\n"
        exit 1
    fi
    log "检测到最新Debian ISO: $LATEST_ISO"
    
    # 更新ISO文件名为最新版本
    ISO_FILE="$LATEST_ISO"
    ISO_PATH="/var/lib/vz/template/iso/$ISO_FILE"

    # 下载ISO，多源重试
    log "检查Debian ISO..."
    if [ ! -f "$ISO_PATH" ]; then
        log "尝试多源下载最新Debian ISO: $ISO_FILE"
        ISO_OK=0
        for url in "${ISO_URLS[@]}"; do
            # 替换URL中的文件名
            url=$(echo "$url" | sed "s/debian-12.11.0-amd64-netinst.iso/$LATEST_ISO/")
            log "尝试下载: $url"
            if wget -O "$ISO_PATH" "$url"; then
                ISO_OK=1
                break
            else
                warn "下载失败: $url"
            fi
        done
        if [ $ISO_OK -ne 1 ]; then
            err "ISO下载多次失败，请检查网络或手动下载到 $ISO_PATH"
            echo -e "\n[手动下载建议] 访问以下任一链接手动下载："
            for url in "${ISO_URLS[@]}"; do
                url=$(echo "$url" | sed "s/debian-12.11.0-amd64-netinst.iso/$LATEST_ISO/")
                echo "  $url"
            done
            echo -e "\n下载完成后，将文件重命名为 $ISO_FILE 并放置到 $ISO_PATH\n"
            exit 1
        fi
    else
        log "ISO已存在: $ISO_PATH"
    fi

    # 创建虚拟机（使用ISO）
    for idx in ${!VM_IDS[@]}; do
        id=${VM_IDS[$idx]}
        name=${VM_NAMES[$idx]}
        ip=${VM_IPS[$idx]}
        log "处理虚拟机 $name (ID:$id, IP:$ip) ..."
        if qm list | grep -q " $id "; then
            warn "虚拟机 $id 已存在，跳过创建"
            continue
        fi
        if ! qm create $id \
            --name $name \
            --memory $VM_MEM \
            --cores $VM_CORES \
            --net0 virtio,bridge=$BRIDGE \
            --scsihw virtio-scsi-pci \
            --serial0 socket \
            --agent 1 \
            --scsi0 $STORAGE:$VM_DISK; then
            err "创建虚拟机 $id 失败，请检查PVE资源和配置"
            exit 1
        fi
        qm set $id --ide2 local:iso/$ISO_FILE,media=cdrom
        qm set $id --ide3 $STORAGE:cloudinit
        qm set $id --ciuser $CLOUDINIT_USER --cipassword $CLOUDINIT_PASS
        qm set $id --ipconfig0 ip=$ip/24,gw=$GATEWAY
        qm set $id --nameserver "$DNS"
        qm set $id --bootdisk scsi0
        qm set $id --onboot 1
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
                exit 1
            fi
            log "虚拟机 $id 启动成功，等待5秒..."
            sleep 5
        fi
    done

    warn "注意：使用ISO方式需要手动完成Debian安装"
    warn "请在虚拟机控制台中完成以下步骤："
    warn "1. 选择语言和键盘布局"
    warn "2. 配置网络（使用DHCP或手动设置IP）"
    warn "3. 设置主机名"
    warn "4. 设置root密码为: $CLOUDINIT_PASS"
    warn "5. 创建用户（可选）"
    warn "6. 分区磁盘（建议使用整个磁盘）"
    warn "7. 安装基本系统"
    warn "8. 选择软件包（建议选择SSH服务器）"
    warn "9. 完成安装并重启"
    warn ""
    warn "安装完成后，请手动重启虚拟机，然后脚本将继续执行"
    
    # 等待用户确认
    read -p "完成手动安装后，按回车键继续..."
    
    # 继续执行后续步骤
    deploy_k8s_continue
}

# 继续K8S部署（用于ISO方式）
deploy_k8s_continue() {
    # 显示虚拟机状态
    log "当前虚拟机状态："
    qm list | grep -E "(VMID|101|102|103)"

    # 等待所有虚拟机SSH可用
    log "开始等待所有虚拟机SSH可用..."
    for idx in ${!VM_IDS[@]}; do
        ip=${VM_IPS[$idx]}
        name=${VM_NAMES[$idx]}
        log "等待 $name ($ip) SSH可用..."
        if ! wait_for_ssh $ip; then
            err "等待 $name SSH失败，终止脚本"
            exit 1
        fi
        log "虚拟机 $name ($ip) SSH已就绪"
    done

    # SSH初始化
    log "批量SSH初始化..."
    for idx in ${!VM_IDS[@]}; do
        name=${VM_NAMES[$idx]}
        ip=${VM_IPS[$idx]}
        log "初始化 $name ($ip) ..."
        
        # 先测试SSH连接
        log "测试 $name SSH连接..."
        if ! sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 $CLOUDINIT_USER@$ip "echo 'SSH连接测试成功'"; then
            err "$name SSH连接失败，请检查：\n- 虚拟机是否正常启动\n- root密码是否正确\n- 网络是否连通"
            exit 1
        fi
        
        # 执行初始化命令
        remote_cmd="hostnamectl set-hostname $name && apt-get update -y && apt-get install -y vim curl wget net-tools lsb-release sudo openssh-server && echo '初始化完成: $name'"
        log "执行初始化命令: $remote_cmd"
        if ! sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 $CLOUDINIT_USER@$ip "$remote_cmd"; then
            err "$name 初始化失败，命令: $remote_cmd"
            echo "[建议] 检查网络、root密码、PVE模板配置等。"
            exit 1
        fi
        log "$name 初始化成功"
    done

    log "所有虚拟机初始化完成，开始K8S部署..."

    # K8S和KubeSphere自动部署
    log "\n开始K8S集群和KubeSphere自动部署..."

    # 1. master节点初始化K8S（重试3次）
    log "[K8S] master节点初始化..."
    K8S_INIT_OK=0
    for try in {1..3}; do
        log "K8S master初始化尝试 $try/3..."
        remote_cmd="apt-get update -y && apt-get install -y apt-transport-https ca-certificates curl gnupg2 software-properties-common && curl -fsSL https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg && echo 'deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main' > /etc/apt/sources.list.d/kubernetes.list && apt-get update -y && apt-get install -y kubelet kubeadm kubectl && swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab && kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-advertise-address=$MASTER_IP --ignore-preflight-errors=NumCPU --ignore-preflight-errors=Mem && mkdir -p /root/.kube && cp /etc/kubernetes/admin.conf /root/.kube/config && kubectl taint nodes --all node-role.kubernetes.io/control-plane- && kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml && echo 'K8S master初始化完成'"
        if sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "$remote_cmd"; then
            K8S_INIT_OK=1
            log "K8S master初始化成功"
            break
        fi
        warn "K8S master初始化失败，重试($try/3)"
        sleep 30
    done
    [ $K8S_INIT_OK -eq 1 ] || { err "K8S master初始化最终失败"; exit 1; }

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
        exit 1
    fi

    # 3. worker节点加入集群（重试）
    for ip in "${WORKER_IPS[@]}"; do
        log "[K8S] $ip 加入集群..."
        JOIN_OK=0
        for try in {1..3}; do
            log "$ip 加入集群尝试 $try/3..."
            remote_cmd="apt-get update -y && apt-get install -y apt-transport-https ca-certificates curl gnupg2 software-properties-common && curl -fsSL https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg && echo 'deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main' > /etc/apt/sources.list.d/kubernetes.list && apt-get update -y && apt-get install -y kubelet kubeadm kubectl && swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab && $JOIN_CMD --ignore-preflight-errors=NumCPU --ignore-preflight-errors=Mem && echo 'K8S worker加入完成'"
            if sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$ip "$remote_cmd"; then
                JOIN_OK=1
                log "$ip 加入集群成功"
                break
            fi
            warn "$ip 加入集群失败，重试($try/3)"
            sleep 30
        done
        [ $JOIN_OK -eq 1 ] || { err "$ip 加入集群最终失败"; exit 1; }
    done

    # 4. 检查K8S集群状态
    log "[K8S] 检查集群状态..."
    sleep 30  # 等待集群稳定
    if ! sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "kubectl get nodes -o wide && kubectl get pods -A"; then
        err "K8S集群状态异常，请检查deploy.log和K8S安装日志"
        exit 1
    fi

    # 5. 安装KubeSphere
    log "[KubeSphere] master节点安装KubeSphere..."
    remote_cmd="curl -sfL https://get-ks.ksops.io | sh && ./kk create cluster -f ./config-sample.yaml || ./kk create cluster"
    if ! sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "$remote_cmd"; then
        err "KubeSphere安装失败，命令: $remote_cmd"
        echo "[建议] 检查KubeSphere安装日志、PVE资源、网络等。"
        exit 1
    fi

    # 6. 检查KubeSphere端口
    wait_for_port $MASTER_IP 30880
    log "KubeSphere控制台: http://$MASTER_IP:30880 (首次访问需等待几分钟)"
    log "默认用户名: admin，密码: P@88w0rd"
    log "全部自动化部署完成，详细日志见 $LOGFILE"
}

# 主程序
main() {
    # 处理命令行参数
    handle_args "$1"
    
    # 如果没有命令行参数，显示交互式菜单
    if [ -z "$1" ]; then
        interactive_menu
    fi
}

# 运行主程序
main "$@" 