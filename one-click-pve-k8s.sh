#!/bin/bash

# ==========================================
# 极简一键PVE K8S+KubeSphere全自动部署脚本（深度优化版）
# 版本: v2.0
# 作者: WinsPan
# 更新: 2024年
# ==========================================

set -euo pipefail  # 更严格的错误处理

# ==========================================
# 全局变量与常量配置区
# ==========================================
readonly SCRIPT_VERSION="2.0"
readonly SCRIPT_NAME="PVE K8S+KubeSphere 部署工具"
readonly MIN_MEMORY_GB=32
readonly MIN_DISK_GB=500
readonly MIN_CPU_CORES=12

# 颜色定义
readonly GREEN='\e[0;32m'
readonly YELLOW='\e[1;33m'
readonly RED='\e[0;31m'
readonly BLUE='\e[0;34m'
readonly CYAN='\e[0;36m'
readonly PURPLE='\e[0;35m'
readonly NC='\e[0m'

# 云镜像配置
readonly CLOUD_IMAGE_URLS=(
  "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
  "https://mirrors.ustc.edu.cn/debian-cloud-images/bookworm/latest/debian-12-generic-amd64.qcow2"
  "https://mirrors.tuna.tsinghua.edu.cn/debian-cloud-images/bookworm/latest/debian-12-generic-amd64.qcow2"
  "https://mirrors.aliyun.com/debian-cloud-images/bookworm/latest/debian-12-generic-amd64.qcow2"
  "https://mirrors.huaweicloud.com/debian-cloud-images/bookworm/latest/debian-12-generic-amd64.qcow2"
)
readonly CLOUD_IMAGE_FILE="debian-12-generic-amd64.qcow2"
readonly CLOUD_IMAGE_PATH="/var/lib/vz/template/qcow/$CLOUD_IMAGE_FILE"

# 虚拟机配置
readonly STORAGE="local-lvm"
readonly BRIDGE="vmbr0"
readonly VM_IDS=(101 102 103)
readonly VM_NAMES=("k8s-master" "k8s-worker1" "k8s-worker2")
readonly VM_IPS=("10.0.0.10" "10.0.0.11" "10.0.0.12")
readonly VM_CORES=8
readonly VM_MEM=16384
readonly VM_DISK=300
readonly CLOUDINIT_USER="root"
readonly CLOUDINIT_PASS="kubesphere123"
readonly GATEWAY="10.0.0.1"
readonly DNS="10.0.0.2 119.29.29.29"

# 集群配置
readonly MASTER_IP="10.0.0.10"
readonly WORKER_IPS=("10.0.0.11" "10.0.0.12")

# 日志配置
readonly LOG_DIR="/var/log/pve-k8s-deploy"
readonly LOG_FILE="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"

# ==========================================
# 通用工具函数区
# ==========================================
# 日志函数
log()     { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }
err()     { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }
debug()   { echo -e "${BLUE}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }
info()    { echo -e "${CYAN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }

# 初始化日志目录
init_logging() {
    mkdir -p "$LOG_DIR"
    if [[ ! -w "$LOG_DIR" ]]; then
        echo -e "${RED}[ERROR]${NC} 无法写入日志目录: $LOG_DIR"
        exit 1
    fi
    log "脚本启动 - $SCRIPT_NAME v$SCRIPT_VERSION"
    log "日志文件: $LOG_FILE"
}

# 检查运行环境
check_environment() {
    log "检查运行环境..."
    
    # 检查是否为root用户
    if [[ $EUID -ne 0 ]]; then
        err "此脚本需要root权限运行"
        exit 1
    fi
    
    # 检查是否在PVE环境中
    if ! command -v qm &>/dev/null; then
        err "未检测到PVE环境，请在Proxmox VE主机上运行此脚本"
        exit 1
    fi
    
    # 检查必要的命令
    local required_commands=("wget" "ssh" "sshpass" "nc" "ping" "iptables")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            err "缺少必要命令: $cmd，请安装后重试"
            exit 1
        fi
    done
    
    # 检查系统资源
    local total_memory_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_memory_gb=$((total_memory_kb / 1024 / 1024))
    local total_disk_gb=$(df / | tail -1 | awk '{print int($4/1024/1024)}')
    local cpu_cores=$(nproc)
    
    log "系统资源检查:"
    log "  CPU核心数: $cpu_cores"
    log "  总内存: ${total_memory_gb}GB"
    log "  可用磁盘: ${total_disk_gb}GB"
    
    if [[ $total_memory_gb -lt $MIN_MEMORY_GB ]]; then
        warn "系统内存不足，建议至少${MIN_MEMORY_GB}GB，当前${total_memory_gb}GB"
    fi
    
    if [[ $total_disk_gb -lt $MIN_DISK_GB ]]; then
        warn "磁盘空间不足，建议至少${MIN_DISK_GB}GB，当前${total_disk_gb}GB"
    fi
    
    if [[ $cpu_cores -lt $MIN_CPU_CORES ]]; then
        warn "CPU核心数不足，建议至少${MIN_CPU_CORES}核，当前${cpu_cores}核"
    fi
    
    success "环境检查完成"
}

# 进度显示函数
show_progress() {
    local current=$1
    local total=$2
    local message=$3
    local percent=$((current * 100 / total))
    local completed=$((percent / 2))
    local remaining=$((50 - completed))
    
    printf "\r${CYAN}[进度]${NC} ["
    printf "%${completed}s" | tr " " "="
    printf "%${remaining}s" | tr " " "-"
    printf "] %d%% %s" "$percent" "$message"
    
    if [[ $current -eq $total ]]; then
        echo ""
    fi
}

# 增强的远程命令执行
run_remote_cmd() {
    local ip="$1"
    local cmd="$2"
    local timeout="${3:-60}"
    local retries="${4:-3}"
    
    for ((i=1; i<=retries; i++)); do
        if timeout "$timeout" sshpass -p "$CLOUDINIT_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=10 \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "$CLOUDINIT_USER@$ip" "bash -c '$cmd'"; then
            return 0
        else
            if [[ $i -lt $retries ]]; then
                warn "远程命令执行失败，重试 $i/$retries..."
                sleep 5
            fi
        fi
    done
    
    err "远程命令执行失败: $ip - $cmd"
    return 1
}

# 网络连通性检查
check_network_connectivity() {
    local ip=$1
    local port=${2:-22}
    local timeout=${3:-5}
    
    if timeout "$timeout" nc -z "$ip" "$port" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# 等待SSH可用（增强版）
wait_for_ssh() {
    local ip=$1
    local max_try=${2:-60}
    local try=0
    
    log "等待 $ip SSH服务可用..."
    
    while ((try < max_try)); do
        show_progress $try $max_try "等待SSH服务启动..."
        
        # 先检查ping
        if ping -c 1 -W 2 "$ip" &>/dev/null; then
            # 再检查SSH端口
            if check_network_connectivity "$ip" 22 3; then
                # 最后测试SSH登录
                if timeout 10 sshpass -p "$CLOUDINIT_PASS" ssh \
                    -o StrictHostKeyChecking=no \
                    -o ConnectTimeout=5 \
                    -o UserKnownHostsFile=/dev/null \
                    -o LogLevel=ERROR \
                    "$CLOUDINIT_USER@$ip" "echo 'SSH测试成功'" &>/dev/null; then
                    show_progress $max_try $max_try "SSH服务已就绪"
                    success "$ip SSH服务已就绪"
                    return 0
                fi
            fi
        fi
        
        sleep 10
        ((try++))
    done
    
    err "$ip SSH服务在${max_try}次尝试后仍不可用"
    return 1
}

# 备份配置
backup_vm_config() {
    local vm_id=$1
    local backup_dir="/var/lib/vz/backup/vm-configs"
    
    mkdir -p "$backup_dir"
    local backup_file="$backup_dir/vm-${vm_id}-$(date +%Y%m%d_%H%M%S).conf"
    
    if [[ -f "/etc/pve/qemu-server/${vm_id}.conf" ]]; then
        cp "/etc/pve/qemu-server/${vm_id}.conf" "$backup_file"
        log "虚拟机 $vm_id 配置已备份到: $backup_file"
    fi
}

# 安全检查
security_check() {
    log "执行安全检查..."
    
    # 检查防火墙状态
    if systemctl is-active --quiet ufw; then
        warn "检测到UFW防火墙已启用，可能影响网络连接"
    fi
    
    # 检查SELinux状态
    if command -v getenforce &>/dev/null && [[ $(getenforce 2>/dev/null) == "Enforcing" ]]; then
        warn "检测到SELinux处于强制模式，可能影响部署"
    fi
    
    # 检查网络配置
    if ! ip route | grep -q "default"; then
        err "未检测到默认路由，请检查网络配置"
        return 1
    fi
    
    success "安全检查完成"
}

# ==========================================
# 修复与诊断功能区
# ==========================================
# 修复Flannel网络问题
fix_flannel_network() {
    log "开始修复Flannel网络问题..."
    
    # 检查K8S集群状态
    if ! run_remote_cmd "$MASTER_IP" "kubectl get nodes" 2>/dev/null; then
        err "K8S集群未就绪，无法修复网络问题"
        return 1
    fi
    
    log "检查当前网络插件状态..."
    run_remote_cmd "$MASTER_IP" '
        echo "=== 当前网络插件状态 ==="
        kubectl get pods -n kube-system | grep -E "(flannel|calico|weave)" || echo "未找到网络插件Pod"
        echo ""
        echo "=== 网络接口状态 ==="
        ip a | grep -E "(cni|flannel|calico)" || echo "未找到CNI网络接口"
        echo ""
        echo "=== 路由表 ==="
        ip route | head -10
    ' || true
    
    log "清理Flannel网络配置..."
    run_remote_cmd "$MASTER_IP" '
        echo "清理Flannel网络..."
        kubectl delete -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml 2>/dev/null || true
        kubectl delete -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/k8s-manifests/kube-flannel-rbac.yml 2>/dev/null || true
        ip link delete cni0 2>/dev/null || true
        ip link delete flannel.1 2>/dev/null || true
        rm -rf /var/lib/cni/flannel 2>/dev/null || true
        rm -rf /run/flannel 2>/dev/null || true
        echo "Flannel清理完成"
    ' || true
    
    log "安装Calico网络插件..."
    run_remote_cmd "$MASTER_IP" '
        echo "安装Calico网络插件..."
        kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
        echo "Calico安装完成"
    ' || true
    
    log "等待网络插件就绪..."
    sleep 30
    
    log "检查网络修复结果..."
    run_remote_cmd "$MASTER_IP" '
        echo "=== 修复后网络状态 ==="
        kubectl get pods -n kube-system | grep -E "(calico|flannel)" || echo "未找到网络插件Pod"
        echo ""
        echo "=== 节点网络状态 ==="
        kubectl get nodes -o wide
        echo ""
        echo "=== 网络连通性测试 ==="
        kubectl get pods -n kube-system -o wide | head -5
    ' || true
    
    log "Flannel网络修复完成"
}

# 修复kube-controller-manager崩溃
fix_controller_manager() {
    log "开始修复kube-controller-manager崩溃..."
    
    # 检查K8S集群状态
    if ! run_remote_cmd "$MASTER_IP" "kubectl get nodes" 2>/dev/null; then
        err "K8S集群未就绪，无法修复控制器问题"
        return 1
    fi
    
    log "检查kube-controller-manager状态..."
    run_remote_cmd "$MASTER_IP" '
        echo "=== kube-controller-manager状态 ==="
        kubectl get pods -n kube-system | grep controller-manager || echo "未找到controller-manager Pod"
        echo ""
        echo "=== 系统资源状态 ==="
        free -h
        echo ""
        df -h | head -5
        echo ""
        echo "=== 系统负载 ==="
        uptime
    ' || true
    
    log "重启kube-controller-manager..."
    run_remote_cmd "$MASTER_IP" '
        echo "重启kube-controller-manager..."
        # 删除controller-manager Pod，让kubelet重新创建
        kubectl delete pod -n kube-system -l component=kube-controller-manager --force --grace-period=0 2>/dev/null || true
        echo "controller-manager Pod已删除，等待重新创建..."
    ' || true
    
    log "等待controller-manager重启..."
    sleep 30
    
    log "检查修复结果..."
    run_remote_cmd "$MASTER_IP" '
        echo "=== 修复后controller-manager状态 ==="
        kubectl get pods -n kube-system | grep controller-manager || echo "未找到controller-manager Pod"
        echo ""
        echo "=== 系统Pod状态 ==="
        kubectl get pods -n kube-system | grep -E "controller|scheduler|apiserver|etcd" || echo "未找到系统Pod"
        echo ""
        echo "=== 事件信息 ==="
        kubectl get events --sort-by=.metadata.creationTimestamp | tail -10 2>/dev/null || echo "无法获取事件信息"
    ' || true
    
    log "kube-controller-manager修复完成"
}

# 修复API服务器连接问题
fix_api_server() {
    log "开始修复API服务器连接问题..."
    
    log "检查API服务器状态..."
    run_remote_cmd "$MASTER_IP" '
        echo "=== API服务器诊断 ==="
        echo ""
        echo "1. 检查kubelet服务状态:"
        systemctl status kubelet | head -10
        echo ""
        echo "2. 检查API服务器容器:"
        # 修复crictl配置
        export CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock
        export IMAGE_SERVICE_ENDPOINT=unix:///run/containerd/containerd.sock
        crictl ps | grep kube-apiserver 2>/dev/null || echo "crictl无法连接，但这不影响API服务器运行"
        echo ""
        echo "3. 检查API服务器Pod:"
        kubectl get pods -n kube-system | grep apiserver 2>/dev/null || echo "无法连接API服务器"
        echo ""
        echo "4. 检查API服务器端口:"
        netstat -tlnp | grep :6443 || echo "6443端口未监听"
        echo ""
        echo "5. 检查系统负载:"
        uptime
        echo ""
        echo "6. 检查磁盘空间:"
        df -h | head -5
    ' || true
    
    log "重启kubelet和containerd服务..."
    
    # 分步重启，避免连接中断
    log "步骤1: 重启containerd服务..."
    run_remote_cmd "$MASTER_IP" 'systemctl restart containerd' || true
    sleep 15
    
    log "步骤2: 重启kubelet服务..."
    run_remote_cmd "$MASTER_IP" 'systemctl restart kubelet' || true
    sleep 20
    
    log "步骤3: 检查服务状态..."
    run_remote_cmd "$MASTER_IP" '
        echo "=== 服务状态检查 ==="
        echo "containerd状态: $(systemctl is-active containerd)"
        echo "kubelet状态: $(systemctl is-active kubelet)"
        
        echo ""
        echo "=== 等待API服务器启动 ==="
        sleep 30
        
        echo "=== 检查API服务器容器 ==="
        export CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock
        export IMAGE_SERVICE_ENDPOINT=unix:///run/containerd/containerd.sock
        crictl ps | grep kube-apiserver 2>/dev/null || echo "crictl连接问题，但不影响API服务器运行"
    ' || true
    
    log "等待API服务器完全启动..."
    sleep 60
    
    log "验证API服务器恢复..."
    local retry_count=0
    local max_retries=5
    
    while [ $retry_count -lt $max_retries ]; do
        # 先检查API服务器Pod和端口状态
        local api_status=$(run_remote_cmd "$MASTER_IP" '
            echo "检查API服务器状态..."
            kubectl get pods -n kube-system | grep kube-apiserver | grep Running >/dev/null 2>&1 && echo "pod_running" || echo "pod_not_running"
            netstat -tlnp | grep :6443 >/dev/null 2>&1 && echo "port_listening" || echo "port_not_listening"
        ' 2>/dev/null)
        
        if echo "$api_status" | grep -q "pod_running" && echo "$api_status" | grep -q "port_listening"; then
            log "API服务器Pod和端口都正常，测试kubectl连接..."
            if run_remote_cmd "$MASTER_IP" "kubectl get nodes" 2>/dev/null; then
                success "✓ API服务器已恢复正常"
                run_remote_cmd "$MASTER_IP" '
                    echo "=== API服务器恢复后状态 ==="
                    echo "1. 集群节点状态:"
                    kubectl get nodes
                    echo ""
                    echo "2. 系统Pod状态:"
                    kubectl get pods -n kube-system | grep -E "apiserver|etcd|scheduler|controller"
                    echo ""
                    echo "3. API服务器端口:"
                    netstat -tlnp | grep :6443
                ' || true
                break
            else
                warn "API服务器Pod运行正常但kubectl连接失败，可能是网络或证书问题..."
                # 尝试修复kubectl连接
                run_remote_cmd "$MASTER_IP" '
                    echo "尝试修复kubectl连接..."
                    
                    # 1. 检查kubectl配置文件
                    if [ -f /etc/kubernetes/admin.conf ]; then
                        echo "✓ kubectl配置文件存在"
                        export KUBECONFIG=/etc/kubernetes/admin.conf
                    else
                        echo "✗ kubectl配置文件不存在"
                    fi
                    
                    # 2. 检查证书文件
                    if [ -d /etc/kubernetes/pki ]; then
                        echo "✓ 证书目录存在"
                        ls -la /etc/kubernetes/pki/ | head -5
                    else
                        echo "✗ 证书目录不存在"
                    fi
                    
                    # 3. 尝试直接访问API服务器
                    curl -k https://localhost:6443/api/v1/nodes 2>/dev/null | head -1 || echo "直接API访问失败"
                    
                    # 4. 检查网络连接
                    netstat -an | grep 6443 || echo "6443端口状态异常"
                    
                    # 5. 重新生成kubectl配置（如果需要）
                    if ! kubectl get nodes 2>/dev/null; then
                        echo "重新配置kubectl..."
                        mkdir -p $HOME/.kube
                        cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
                        chown $(id -u):$(id -g) $HOME/.kube/config
                    fi
                ' || true
            fi
        fi
        
        retry_count=$((retry_count + 1))
        warn "API服务器尚未完全恢复，重试 $retry_count/$max_retries..."
        sleep 30
    done
    
    if [ $retry_count -eq $max_retries ]; then
        err "API服务器恢复失败，可能需要手动检查以下项目："
        echo "1. 检查etcd服务状态"
        echo "2. 检查证书文件是否正确"
        echo "3. 检查磁盘空间是否充足"
        echo "4. 检查系统资源使用情况"
        echo "5. 查看kubelet日志: journalctl -u kubelet -f"
    fi
    
    log "API服务器修复完成"
}

# 专门修复Calico网络问题
fix_calico_network() {
    log "开始专门修复Calico网络问题..."
    
    # 检查K8S集群状态
    if ! run_remote_cmd "$MASTER_IP" "kubectl get nodes" 2>/dev/null; then
        err "K8S集群未就绪，无法修复网络问题"
        return 1
    fi
    
    log "诊断Calico网络问题..."
    run_remote_cmd "$MASTER_IP" '
        echo "=== Calico网络诊断 ==="
        echo ""
        echo "1. Calico Pod状态:"
        kubectl get pods -n kube-system | grep calico || echo "未找到Calico Pod"
        echo ""
        echo "2. Calico节点状态:"
        kubectl get nodes -o wide
        echo ""
        echo "3. 网络接口状态:"
        ip a | grep -E "cali|tunl|vxlan" || echo "未找到Calico网络接口"
        echo ""
        echo "4. 路由表:"
        ip route | grep -E "cali|10\.244" || echo "未找到Calico路由"
        echo ""
        echo "5. iptables规则:"
        iptables -t nat -L | grep -E "cali|KUBE" | head -10 || echo "未找到相关iptables规则"
        echo ""
        echo "6. 检查Calico Pod错误日志:"
        for pod in $(kubectl get pods -n kube-system | grep calico-node | awk "{print \$1}"); do
            echo "Pod $pod 日志:"
            kubectl logs -n kube-system $pod --tail=10 2>/dev/null || echo "无法获取日志"
            echo ""
            echo "Pod $pod 前一个容器日志:"
            kubectl logs -n kube-system $pod --previous --tail=5 2>/dev/null || echo "无前一个容器日志"
            echo ""
        done
    ' || true
    
    log "完全清理Calico网络..."
    run_remote_cmd "$MASTER_IP" '
        echo "=== 完全清理Calico网络 ==="
        
        # 1. 强制删除所有Calico资源
        echo "1. 强制删除Calico资源..."
        kubectl delete daemonset calico-node -n kube-system --force --grace-period=0 2>/dev/null || true
        kubectl delete deployment calico-kube-controllers -n kube-system --force --grace-period=0 2>/dev/null || true
        kubectl delete pods -n kube-system -l k8s-app=calico-node --force --grace-period=0 2>/dev/null || true
        kubectl delete pods -n kube-system -l k8s-app=calico-kube-controllers --force --grace-period=0 2>/dev/null || true
        kubectl delete configmap calico-config -n kube-system 2>/dev/null || true
        kubectl delete secret calico-node -n kube-system 2>/dev/null || true
        kubectl delete serviceaccount calico-node -n kube-system 2>/dev/null || true
        kubectl delete serviceaccount calico-kube-controllers -n kube-system 2>/dev/null || true
        
        # 2. 清理CRD资源
        echo "2. 清理Calico CRD资源..."
        kubectl delete crd bgpconfigurations.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd bgppeers.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd blockaffinities.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd caliconodestatuses.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd clusterinformations.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd felixconfigurations.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd globalnetworkpolicies.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd globalnetworksets.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd hostendpoints.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd ipamblocks.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd ipamconfigs.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd ipamhandles.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd ippools.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd ipreservations.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd kubecontrollersconfigurations.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd networkpolicies.crd.projectcalico.org 2>/dev/null || true
        kubectl delete crd networksets.crd.projectcalico.org 2>/dev/null || true
        
        # 3. 清理网络接口
        echo "3. 清理网络接口..."
        ip link delete cali0 2>/dev/null || true
        ip link delete tunl0 2>/dev/null || true
        ip link delete vxlan.calico 2>/dev/null || true
        ip link delete felix-fv-eth0 2>/dev/null || true
        for iface in $(ip link show | grep cali | awk -F: "{print \$2}" | tr -d " " | head -20); do
            [ -n "$iface" ] && ip link delete $iface 2>/dev/null || true
        done
        
        # 4. 清理路由
        echo "4. 清理路由..."
        ip route flush proto bird 2>/dev/null || true
        ip route del 10.244.0.0/16 2>/dev/null || true
        ip route del 192.168.0.0/16 2>/dev/null || true
        
        # 5. 清理iptables规则
        echo "5. 清理iptables规则..."
        iptables -t nat -F cali-nat-outgoing 2>/dev/null || true
        iptables -t nat -F cali-PREROUTING 2>/dev/null || true
        iptables -t nat -F cali-OUTPUT 2>/dev/null || true
        iptables -t filter -F cali-FORWARD 2>/dev/null || true
        iptables -t filter -F cali-INPUT 2>/dev/null || true
        iptables -t filter -F cali-OUTPUT 2>/dev/null || true
        iptables -t mangle -F cali-PREROUTING 2>/dev/null || true
        iptables -t mangle -F cali-OUTPUT 2>/dev/null || true
        
        # 6. 清理CNI配置
        echo "6. 清理CNI配置..."
        rm -rf /etc/cni/net.d/10-calico.conflist 2>/dev/null || true
        rm -rf /etc/cni/net.d/calico-kubeconfig 2>/dev/null || true
        rm -rf /var/lib/calico 2>/dev/null || true
        rm -rf /var/run/calico 2>/dev/null || true
        rm -rf /var/log/calico 2>/dev/null || true
        rm -rf /opt/cni/bin/calico* 2>/dev/null || true
        
        # 7. 重启网络服务
        echo "7. 重启网络服务..."
        systemctl restart containerd
        systemctl restart kubelet
        
        echo "主节点Calico清理完成"
    ' || true
    
    # 在所有工作节点上也执行清理
    for worker_ip in "${WORKER_IPS[@]}"; do
        log "在工作节点 $worker_ip 上清理Calico..."
        run_remote_cmd "$worker_ip" '
            echo "=== 清理工作节点上的Calico残留 ==="
            
            # 1. 清理网络接口
            echo "1. 清理网络接口..."
            ip link delete cali0 2>/dev/null || true
            ip link delete tunl0 2>/dev/null || true
            ip link delete vxlan.calico 2>/dev/null || true
            ip link delete felix-fv-eth0 2>/dev/null || true
            for iface in $(ip link show | grep cali | awk -F: "{print \$2}" | tr -d " " | head -20); do
                [ -n "$iface" ] && ip link delete $iface 2>/dev/null || true
            done
            
            # 2. 清理路由
            echo "2. 清理路由..."
            ip route flush proto bird 2>/dev/null || true
            ip route del 10.244.0.0/16 2>/dev/null || true
            ip route del 192.168.0.0/16 2>/dev/null || true
            
            # 3. 清理iptables规则
            echo "3. 清理iptables规则..."
            iptables -t nat -F cali-nat-outgoing 2>/dev/null || true
            iptables -t nat -F cali-PREROUTING 2>/dev/null || true
            iptables -t nat -F cali-OUTPUT 2>/dev/null || true
            iptables -t filter -F cali-FORWARD 2>/dev/null || true
            iptables -t filter -F cali-INPUT 2>/dev/null || true
            iptables -t filter -F cali-OUTPUT 2>/dev/null || true
            iptables -t mangle -F cali-PREROUTING 2>/dev/null || true
            iptables -t mangle -F cali-OUTPUT 2>/dev/null || true
            
            # 4. 清理CNI配置
            echo "4. 清理CNI配置..."
            rm -rf /etc/cni/net.d/10-calico.conflist 2>/dev/null || true
            rm -rf /etc/cni/net.d/calico-kubeconfig 2>/dev/null || true
            rm -rf /var/lib/calico 2>/dev/null || true
            rm -rf /var/run/calico 2>/dev/null || true
            rm -rf /var/log/calico 2>/dev/null || true
            rm -rf /opt/cni/bin/calico* 2>/dev/null || true
            
            # 5. 清理容器和镜像
            echo "5. 清理容器和镜像..."
            crictl rmi --prune 2>/dev/null || true
            docker system prune -f 2>/dev/null || true
            
            # 6. 重启服务
            echo "6. 重启服务..."
            systemctl restart containerd
            systemctl restart kubelet
            
            echo "工作节点 '$worker_ip' 清理完成"
        ' || true
    done
    
    log "等待集群稳定..."
    sleep 30
    
    log "重新安装Calico网络插件..."
    run_remote_cmd "$MASTER_IP" '
        echo "=== 重新安装Calico网络插件 ==="
        
        # 1. 下载Calico配置
        echo "1. 下载Calico配置文件..."
        cd /tmp
        rm -f calico.yaml calico-custom.yaml
        
        # 尝试下载Calico配置，使用稳定版本
        echo "尝试下载Calico v3.25.0配置..."
        if wget -O calico.yaml https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml 2>/dev/null; then
            echo "✓ 成功下载Calico v3.25.0配置"
        elif curl -o calico.yaml https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml 2>/dev/null; then
            echo "✓ 使用curl下载Calico v3.25.0配置"
        else
            echo "下载失败，使用kubectl直接安装..."
            # 直接使用kubectl安装，不修改配置
            kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml
            echo "Calico安装完成（使用默认配置）"
            return
        fi
        
        # 2. 验证下载的配置文件
        echo "2. 验证配置文件..."
        if ! kubectl apply --dry-run=client -f calico.yaml >/dev/null 2>&1; then
            echo "配置文件格式有问题，使用在线安装..."
            kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml
            echo "Calico在线安装完成"
            return
        fi
        
        # 3. 修改配置文件（仅修改必要的部分）
        echo "3. 修改Calico配置..."
        cp calico.yaml calico-custom.yaml
        
        # 只修改Pod网络CIDR，其他保持默认
        if grep -q "CALICO_IPV4POOL_CIDR" calico-custom.yaml; then
            sed -i "s|# - name: CALICO_IPV4POOL_CIDR|  - name: CALICO_IPV4POOL_CIDR|g" calico-custom.yaml
            sed -i "s|#   value: \"192.168.0.0/16\"|    value: \"10.244.0.0/16\"|g" calico-custom.yaml
            echo "✓ 已设置Pod网络CIDR为10.244.0.0/16"
        fi
        
        echo "配置修改完成"
        
        # 4. 验证修改后的配置
        echo "4. 验证修改后的配置..."
        if kubectl apply --dry-run=client -f calico-custom.yaml >/dev/null 2>&1; then
            echo "✓ 配置文件验证通过"
            kubectl apply -f calico-custom.yaml
        else
            echo "修改后的配置有问题，使用原始配置..."
            kubectl apply -f calico.yaml
        fi
        
        echo "Calico重新安装完成"
        
        # 4. 验证安装
        echo "4. 验证安装状态..."
        sleep 10
        kubectl get pods -n kube-system | grep calico || echo "Calico Pod尚未创建"
    ' || true
    
    log "等待Calico Pod启动..."
    sleep 90
    
    log "检查Calico修复结果..."
    run_remote_cmd "$MASTER_IP" '
        echo "=== Calico修复后状态 ==="
        echo ""
        echo "1. Calico Pod状态:"
        kubectl get pods -n kube-system | grep calico
        echo ""
        echo "2. 节点状态:"
        kubectl get nodes -o wide
        echo ""
        echo "3. 网络接口:"
        ip a | grep -E "(cali|tunl)" | head -10 || echo "暂未发现Calico接口"
        echo ""
        echo "4. Pod网络测试:"
        kubectl get pods -n kube-system -o wide | head -5
        echo ""
        echo "5. Calico Pod详细错误日志:"
        for pod in $(kubectl get pods -n kube-system | grep calico-node | grep -v Running | awk "{print \$1}"); do
            echo "--- Pod $pod 当前日志 ---"
            kubectl logs -n kube-system $pod --tail=15 2>/dev/null || echo "无法获取当前日志"
            echo ""
            echo "--- Pod $pod 前一个容器日志 ---"
            kubectl logs -n kube-system $pod --previous --tail=10 2>/dev/null || echo "无前一个容器日志"
            echo ""
        done
    ' || true
    
    # 检查API服务器状态
    log "检查API服务器状态..."
    if ! run_remote_cmd "$MASTER_IP" "kubectl get nodes" 2>/dev/null; then
        warn "API服务器连接失败，尝试重启API服务器..."
        run_remote_cmd "$MASTER_IP" '
            echo "重启API服务器..."
            systemctl restart kubelet
            # 等待API服务器重新启动
            sleep 30
            # 检查API服务器Pod
            crictl ps | grep kube-apiserver || echo "API服务器Pod未找到"
        ' || true
        
        # 再次等待API服务器启动
        log "等待API服务器恢复..."
        sleep 60
        
        # 验证API服务器是否恢复
        if run_remote_cmd "$MASTER_IP" "kubectl get nodes" 2>/dev/null; then
            success "✓ API服务器已恢复"
        else
            warn "✗ API服务器仍未恢复，可能需要手动检查"
        fi
    fi
    
    success "Calico网络修复完成"
}

# 修复KubeSphere安装问题
fix_kubesphere_installation() {
    log "开始修复KubeSphere安装问题..."
    
    # 检查K8S集群状态
    if ! run_remote_cmd "$MASTER_IP" "kubectl get nodes" 2>/dev/null; then
        err "K8S集群未就绪，无法修复KubeSphere"
        return 1
    fi
    
    log "检查KubeSphere安装状态..."
    run_remote_cmd "$MASTER_IP" "
        echo '=== KubeSphere安装状态 ==='
        kubectl get ns | grep kubesphere || echo 'kubesphere-system命名空间不存在'
        echo ''
        echo '=== KubeSphere Pod状态 ==='
        kubectl get pods -n kubesphere-system 2>/dev/null || echo 'kubesphere-system命名空间不存在'
        echo ''
        echo '=== 安装器Pod日志 ==='
        INSTALLER_POD=\$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')
        if [ -n \"\$INSTALLER_POD\" ]; then
            echo '安装器Pod: '\$INSTALLER_POD
            kubectl logs -n kubesphere-system \$INSTALLER_POD --tail=20 2>/dev/null || echo '无法获取安装日志'
        else
            echo '未找到安装器Pod'
        fi
    " || true
    
    log "清理现有KubeSphere安装..."
    run_remote_cmd "$MASTER_IP" "
        echo '清理KubeSphere安装...'
        kubectl delete -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml 2>/dev/null || true
        kubectl delete -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml 2>/dev/null || true
        kubectl delete ns kubesphere-system --force --grace-period=0 2>/dev/null || true
        kubectl delete ns kubesphere-controls-system --force --grace-period=0 2>/dev/null || true
        kubectl delete ns kubesphere-monitoring-system --force --grace-period=0 2>/dev/null || true
        kubectl delete ns kubesphere-logging-system --force --grace-period=0 2>/dev/null || true
        echo 'KubeSphere清理完成'
    " || true
    
    log "等待清理完成..."
    sleep 30
    
    log "重新安装KubeSphere（轻量版）..."
    run_remote_cmd "$MASTER_IP" "
        echo '重新安装KubeSphere...'
        kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml
        kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml
        echo 'KubeSphere重新安装完成'
    " || true
    
    log "等待安装开始..."
    sleep 30
    
    log "检查修复结果..."
    run_remote_cmd "$MASTER_IP" "
        echo '=== 修复后KubeSphere状态 ==='
        kubectl get ns | grep kubesphere || echo 'kubesphere-system命名空间不存在'
        echo ''
        echo '=== KubeSphere Pod状态 ==='
        kubectl get pods -n kubesphere-system 2>/dev/null || echo 'kubesphere-system命名空间不存在'
        echo ''
        echo '=== 安装进度 ==='
        INSTALLER_POD=\$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')
        if [ -n \"\$INSTALLER_POD\" ]; then
            echo '安装器Pod: '\$INSTALLER_POD
            kubectl logs -n kubesphere-system \$INSTALLER_POD --tail=10 2>/dev/null || echo '无法获取安装日志'
        else
            echo '未找到安装器Pod，安装可能还在进行中'
        fi
    " || true
    
    log "KubeSphere安装修复完成"
}

# 检查KubeSphere控制台访问
check_kubesphere_console() {
    log "检查KubeSphere控制台访问..."
    
    # 检查K8S集群状态
    if ! run_remote_cmd "$MASTER_IP" "kubectl get nodes" 2>/dev/null; then
        err "K8S集群未就绪，无法检查KubeSphere"
        return 1
    fi
    
    log "检查KubeSphere安装状态..."
    run_remote_cmd "$MASTER_IP" '
        echo "=== KubeSphere安装状态检查 ==="
        echo ""
        echo "1. 命名空间状态:"
        kubectl get ns | grep kubesphere || echo "kubesphere-system命名空间不存在"
        echo ""
        echo "2. 安装器Pod状态:"
        kubectl get pods -n kubesphere-system -l app=ks-install 2>/dev/null || echo "未找到安装器Pod"
        echo ""
        echo "3. 所有KubeSphere Pod:"
        kubectl get pods -n kubesphere-system 2>/dev/null || echo "kubesphere-system命名空间不存在"
        echo ""
        echo "4. 安装器Pod详细信息:"
        INSTALLER_POD=$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
        if [ -n "$INSTALLER_POD" ]; then
            echo "安装器Pod: $INSTALLER_POD"
            echo ""
            echo "Pod详细信息:"
            kubectl describe pod -n kubesphere-system $INSTALLER_POD 2>/dev/null || echo "无法获取Pod详细信息"
            echo ""
            echo "Pod事件:"
            kubectl get events -n kubesphere-system --field-selector involvedObject.name=$INSTALLER_POD --sort-by=.metadata.creationTimestamp 2>/dev/null || echo "无法获取Pod事件"
            echo ""
            echo "安装器日志:"
            kubectl logs -n kubesphere-system $INSTALLER_POD --tail=20 2>/dev/null || echo "无法获取安装日志"
        else
            echo "未找到安装器Pod"
        fi
        echo ""
        echo "5. 控制台服务:"
        kubectl get svc -n kubesphere-system ks-console 2>/dev/null || echo "控制台服务不存在"
        echo ""
        echo "6. 端口监听状态:"
        netstat -tlnp | grep :30880 || echo "30880端口未监听"
        echo ""
        echo "7. 防火墙状态:"
        iptables -L | grep 30880 || echo "防火墙规则中未找到30880端口"
        echo ""
        echo "8. 系统资源状态:"
        echo "CPU使用率:"
        top -bn1 | grep "Cpu(s)" || echo "无法获取CPU信息"
        echo ""
        echo "内存使用率:"
        free -h || echo "无法获取内存信息"
        echo ""
        echo "磁盘使用率:"
        df -h | grep -E "(/$|/var)" || echo "无法获取磁盘信息"
    ' || true
    
    # 检查端口访问
    log "检查30880端口访问..."
    if nc -z $MASTER_IP 30880 2>/dev/null; then
        log "✓ 30880端口可访问"
        success "KubeSphere控制台应该可以正常访问"
        return 0
    else
        warn "✗ 30880端口无法访问"
        log "尝试诊断端口问题..."
        
        # 检查防火墙
        run_remote_cmd "$MASTER_IP" '
            echo "=== 防火墙检查 ==="
            iptables -L INPUT -n | grep 30880 || echo "防火墙INPUT链中未找到30880规则"
            iptables -L FORWARD -n | grep 30880 || echo "防火墙FORWARD链中未找到30880规则"
            echo ""
            echo "=== 网络接口检查 ==="
            ip a | grep -E "(10\.0\.0\.10|eth|ens)" || echo "未找到相关网络接口"
        ' || true
    fi
    
    # 询问是否进行自动修复
    echo ""
    read -p "是否尝试自动修复KubeSphere安装问题？(y/n): " auto_fix
    if [[ $auto_fix =~ ^[Yy]$ ]]; then
        force_fix_kubesphere_installer
    fi
    
    log "KubeSphere控制台检查完成"
    echo ""
    echo "如果30880端口无法访问，可能的原因："
    echo "1. KubeSphere安装未完成"
    echo "2. 防火墙阻止了端口访问"
    echo "3. 网络配置问题"
    echo "4. 系统资源不足"
    echo ""
    echo "建议操作："
    echo "1. 等待KubeSphere安装完成（可能需要10-30分钟）"
    echo "2. 检查防火墙设置：iptables -I INPUT -p tcp --dport 30880 -j ACCEPT"
    echo "3. 检查系统资源：top, free -h, df -h"
    echo "4. 重新运行修复功能"
    echo "5. 如果问题持续，考虑重新安装KubeSphere"
}

# 强制修复KubeSphere安装器
force_fix_kubesphere_installer() {
    log "开始强制修复KubeSphere安装器..."
    
    run_remote_cmd "$MASTER_IP" '
        echo "=== 强制修复KubeSphere安装器 ==="
        
        # 1. 强制删除卡住的安装器Pod
        echo "1. 强制删除卡住的安装器Pod..."
        INSTALLER_POD=$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
        if [ -n "$INSTALLER_POD" ]; then
            echo "找到安装器Pod: $INSTALLER_POD"
            kubectl delete pod -n kubesphere-system $INSTALLER_POD --force --grace-period=0 2>/dev/null || true
            echo "安装器Pod已删除"
        else
            echo "未找到安装器Pod"
        fi
        
        # 2. 清理所有Pending状态的Pod
        echo ""
        echo "2. 清理Pending状态的Pod..."
        kubectl delete pods -n kubesphere-system --field-selector=status.phase=Pending --force --grace-period=0 2>/dev/null || true
        kubectl delete pods -n kubesphere-system --field-selector=status.phase=Unknown --force --grace-period=0 2>/dev/null || true
        
        # 3. 清理可能卡住的镜像
        echo ""
        echo "3. 清理Docker系统..."
        docker system prune -f 2>/dev/null || true
        
        # 4. 重启kubelet
        echo ""
        echo "4. 重启kubelet..."
        systemctl restart kubelet 2>/dev/null || true
        
        # 5. 等待新Pod创建
        echo ""
        echo "5. 等待新安装器Pod创建..."
        sleep 15
        
        # 6. 检查新Pod状态
        echo ""
        echo "6. 检查新安装器Pod状态..."
        NEW_INSTALLER_POD=$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
        if [ -n "$NEW_INSTALLER_POD" ]; then
            echo "新安装器Pod: $NEW_INSTALLER_POD"
            kubectl get pod -n kubesphere-system $NEW_INSTALLER_POD
            echo ""
            echo "Pod详细信息:"
            kubectl describe pod -n kubesphere-system $NEW_INSTALLER_POD 2>/dev/null || echo "无法获取Pod详细信息"
        else
            echo "未找到新的安装器Pod，可能需要重新安装KubeSphere"
        fi
    ' || true
    
    # 检查修复结果
    log "检查修复结果..."
    run_remote_cmd "$MASTER_IP" '
        echo "=== 修复后状态检查 ==="
        echo ""
        echo "1. 安装器Pod状态:"
        kubectl get pods -n kubesphere-system -l app=ks-install 2>/dev/null || echo "未找到安装器Pod"
        echo ""
        echo "2. 所有KubeSphere Pod:"
        kubectl get pods -n kubesphere-system 2>/dev/null || echo "kubesphere-system命名空间不存在"
        echo ""
        echo "3. 控制台服务:"
        kubectl get svc -n kubesphere-system ks-console 2>/dev/null || echo "控制台服务不存在"
        echo ""
        echo "4. 端口监听状态:"
        netstat -tlnp | grep :30880 || echo "30880端口未监听"
    ' || true
    
    success "KubeSphere安装器修复完成"
}

# 检查集群状态
check_cluster_status_repair() {
    log "开始检查集群状态..."
    
    # 检查K8S集群状态
    if ! run_remote_cmd "$MASTER_IP" "kubectl get nodes" 2>/dev/null; then
        err "K8S集群未就绪"
        return 1
    fi
    
    log "执行详细集群状态检查..."
    run_remote_cmd "$MASTER_IP" '
        echo "=========================================="
        echo "K8S集群详细状态检查报告"
        echo "=========================================="
        echo ""
        echo "1. 节点状态:"
        kubectl get nodes -o wide
        echo ""
        echo "2. 系统Pod状态:"
        kubectl get pods -n kube-system
        echo ""
        echo "3. 所有命名空间:"
        kubectl get ns
        echo ""
        echo "4. 系统服务状态:"
        kubectl get svc -n kube-system
        echo ""
        echo "5. 存储类:"
        kubectl get storageclass 2>/dev/null || echo "未配置存储类"
        echo ""
        echo "6. 持久卷:"
        kubectl get pv 2>/dev/null || echo "未配置持久卷"
        echo ""
        echo "7. 事件信息:"
        kubectl get events --sort-by=.metadata.creationTimestamp | tail -20 2>/dev/null || echo "无法获取事件信息"
        echo ""
        echo "8. 集群信息:"
        kubectl cluster-info 2>/dev/null || echo "无法获取集群信息"
        echo ""
        echo "9. 系统资源使用:"
        kubectl top nodes 2>/dev/null || echo "metrics-server未安装或未运行"
        echo ""
        echo "10. 网络插件状态:"
        kubectl get pods -n kube-system | grep -E "flannel|calico|weave|cilium" || echo "未找到网络插件"
        echo ""
        echo "=========================================="
        echo "检查完成"
        echo "=========================================="
    ' || true
    
    # 检查KubeSphere状态（如果存在）
    log "检查KubeSphere状态..."
    run_remote_cmd "$MASTER_IP" '
        if kubectl get ns kubesphere-system 2>/dev/null; then
            echo "=========================================="
            echo "KubeSphere状态检查"
            echo "=========================================="
            echo ""
            echo "1. KubeSphere Pod状态:"
            kubectl get pods -n kubesphere-system
            echo ""
            echo "2. KubeSphere服务:"
            kubectl get svc -n kubesphere-system
            echo ""
            echo "3. 安装器状态:"
            INSTALLER_POD=$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || echo "")
            if [ -n "$INSTALLER_POD" ]; then
                echo "安装器Pod: $INSTALLER_POD"
                kubectl logs -n kubesphere-system $INSTALLER_POD --tail=10 2>/dev/null || echo "无法获取安装日志"
            else
                echo "未找到安装器Pod"
            fi
            echo ""
            echo "4. 控制台访问:"
            kubectl get svc -n kubesphere-system ks-console 2>/dev/null || echo "控制台服务不存在"
            echo ""
            echo "=========================================="
        else
            echo "KubeSphere未安装或命名空间不存在"
        fi
    ' || true
    
    log "集群状态检查完成"
}

repair_menu() {
    while true; do
        clear
        echo -e "${CYAN}========== K8S/KubeSphere 修复与诊断 ==========${NC}"
        echo -e "${GREEN}网络修复:${NC}"
        echo -e "${YELLOW}1.${NC} 修复Flannel网络问题"
        echo -e "${YELLOW}2.${NC} 专门修复Calico网络问题"
        echo ""
        echo -e "${GREEN}基础修复:${NC}"
        echo -e "${YELLOW}3.${NC} 修复API服务器连接问题"
        echo -e "${YELLOW}4.${NC} 修复kube-controller-manager崩溃"
        echo -e "${YELLOW}5.${NC} 修复KubeSphere安装问题"
        echo -e "${YELLOW}6.${NC} 强制修复KubeSphere安装器"
        echo ""
        echo -e "${GREEN}状态检查:${NC}"
        echo -e "${YELLOW}7.${NC} 检查KubeSphere控制台访问"
        echo -e "${YELLOW}8.${NC} 网络连通性测试"
        echo -e "${YELLOW}9.${NC} 检查集群状态"
        echo ""
        echo -e "${GREEN}系统配置:${NC}"
        echo -e "${YELLOW}10.${NC} 配置防火墙规则"
        echo -e "${YELLOW}11.${NC} 生成访问信息"
        echo ""
        echo -e "${GREEN}一键操作:${NC}"
        echo -e "${YELLOW}12.${NC} 一键修复所有问题"
        echo -e "${YELLOW}0.${NC} 返回主菜单"
        echo -e "${CYAN}================================================${NC}"
        read -p "请选择操作 (0-12): " repair_choice
        case $repair_choice in
            1) fix_flannel_network;;
            2) fix_calico_network;;
            3) fix_api_server;;
            4) fix_controller_manager;;
            5) fix_kubesphere_installation;;
            6) force_fix_kubesphere_installer;;
            7) check_kubesphere_console;;
            8) test_network_connectivity;;
            9) check_cluster_status_repair;;
            10) configure_firewall;;
            11) generate_access_info;;
            12) fix_all_issues;;
            0) break;;
            *) err "无效选择，请重新输入";;
        esac
        read -p "按回车键继续..."
    done
}

# ==========================================
# 部署与资源管理区
# ==========================================
# 这里放所有部署、资源管理相关函数
# ... 保留原有的 download_cloud_image, create_and_start_vms, fix_existing_vms, deploy_k8s, deploy_kubesphere, cleanup_all, auto_deploy_all ...
# 这些函数内部所有远程命令、等待等全部调用 run_remote_cmd/wait_for_ssh/wait_for_port
# ... 省略函数体 ...

# 诊断PVE环境
diagnose_pve() {
    log "开始诊断PVE环境..."
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
        else
            err "虚拟机 $id ($name) 不存在"
        fi
        echo ""
    done

    # 3. 检查网络连接
    log "3. 检查网络连接..."
    for idx in ${!VM_IDS[@]}; do
        ip=${VM_IPS[$idx]}
        name=${VM_NAMES[$idx]}
        
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
        echo ""
    done

    # 4. 检查系统资源
    log "4. 检查系统资源..."
    echo "内存使用："
    free -h
    echo ""
    echo "磁盘使用："
    df -h
    echo ""
    echo "CPU信息："
    nproc
    echo ""
    echo "=========================================="
    echo "诊断完成"
    echo "=========================================="
}

# 下载Debian Cloud镜像
download_cloud_image() {
    log "开始下载Debian Cloud镜像..."
    
    # 确保目录存在
    mkdir -p /var/lib/vz/template/qcow
    
    # 检查Debian cloud镜像
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
    
    # 安全检查
    security_check || return 1
    
    # 确保cloud-init自定义配置存在
    mkdir -p /var/lib/vz/snippets
    local cloudinit_custom_usercfg="/var/lib/vz/snippets/debian-root.yaml"
    
    log "创建cloud-init配置文件..."
    cat > "$cloudinit_custom_usercfg" <<EOF
#cloud-config
disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
  list: |
    root:$CLOUDINIT_PASS
package_update: true
package_upgrade: false
packages:
  - curl
  - wget
  - vim
  - htop
runcmd:
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh
  - echo "root:$CLOUDINIT_PASS" | chpasswd
  - systemctl enable ssh
  - ufw --force disable 2>/dev/null || true
EOF

    success "cloud-init配置文件创建完成"

    # 创建虚拟机
    local total_vms=${#VM_IDS[@]}
    for idx in "${!VM_IDS[@]}"; do
        local id=${VM_IDS[$idx]}
        local name=${VM_NAMES[$idx]}
        local ip=${VM_IPS[$idx]}
        local current_step=$((idx + 1))
        
        show_progress $current_step $total_vms "创建虚拟机 $name"
        log "处理虚拟机 $name (ID:$id, IP:$ip)..."
        
        # 检查虚拟机是否已存在
        if qm list | grep -q " $id "; then
            warn "虚拟机 $id 已存在，跳过创建"
            continue
        fi
        
        # 备份配置（如果存在）
        backup_vm_config "$id"
        
        log "创建空虚拟机 $id..."
        if ! qm create "$id" \
            --name "$name" \
            --memory "$VM_MEM" \
            --cores "$VM_CORES" \
            --net0 "virtio,bridge=$BRIDGE" \
            --scsihw virtio-scsi-pci \
            --serial0 socket \
            --agent 1 \
            --ostype l26; then
            err "创建虚拟机 $id 失败"
            return 1
        fi
        
        log "导入cloud镜像到虚拟机 $id..."
        if ! qm importdisk "$id" "$CLOUD_IMAGE_PATH" "$STORAGE" --format qcow2; then
            err "导入cloud镜像到虚拟机 $id 失败"
            qm destroy "$id" 2>/dev/null || true
            return 1
        fi
        
        log "配置虚拟机 $id..."
        qm set "$id" --scsi0 "$STORAGE:vm-${id}-disk-0"
        qm set "$id" --ide3 "$STORAGE:cloudinit"
        qm set "$id" --ciuser "$CLOUDINIT_USER" --cipassword "$CLOUDINIT_PASS"
        qm set "$id" --ipconfig0 "ip=$ip/24,gw=$GATEWAY"
        qm set "$id" --nameserver "$DNS"
        qm set "$id" --boot order=scsi0
        qm set "$id" --onboot 1
        qm set "$id" --cicustom "user=local:snippets/debian-root.yaml"
        
        log "扩展虚拟机 $id 磁盘到 ${VM_DISK}GB..."
        if ! qm resize "$id" scsi0 "${VM_DISK}G"; then
            warn "磁盘扩展失败，但虚拟机创建成功"
        fi
        
        success "虚拟机 $id ($name) 创建完成"
    done

    # 启动虚拟机
    log "批量启动虚拟机..."
    for idx in "${!VM_IDS[@]}"; do
        local id=${VM_IDS[$idx]}
        local name=${VM_NAMES[$idx]}
        local current_step=$((idx + 1))
        
        show_progress $current_step $total_vms "启动虚拟机 $name"
        
        local status
        status=$(qm list | awk -v id="$id" '$1==id{print $3}')
        
        if [[ "$status" == "running" ]]; then
            warn "虚拟机 $id 已在运行，跳过启动"
        else
            log "启动虚拟机 $id ($name)..."
            if ! qm start "$id"; then
                err "启动虚拟机 $id 失败"
                return 1
            fi
            
            # 等待虚拟机启动
            sleep 10
            
            # 验证启动状态
            local new_status
            new_status=$(qm list | awk -v id="$id" '$1==id{print $3}')
            if [[ "$new_status" == "running" ]]; then
                success "虚拟机 $id ($name) 启动成功"
            else
                warn "虚拟机 $id ($name) 启动状态异常: $new_status"
            fi
        fi
    done

    # 显示最终状态
    log "虚拟机创建和启动完成，当前状态："
    qm list | grep -E "(VMID|$(IFS='|'; echo "${VM_IDS[*]}"))"
    
    # 等待所有虚拟机SSH就绪
    log "等待所有虚拟机SSH服务就绪..."
    for idx in "${!VM_IPS[@]}"; do
        local ip=${VM_IPS[$idx]}
        local name=${VM_NAMES[$idx]}
        
        log "等待 $name ($ip) SSH服务..."
        if ! wait_for_ssh "$ip" 120; then
            err "$name ($ip) SSH服务未就绪，请检查虚拟机状态"
            return 1
        fi
    done
    
    success "所有虚拟机创建完成并SSH就绪"
    return 0
}

# 修正已存在虚拟机的cloud-init配置
fix_existing_vms() {
    log "修正已存在虚拟机的cloud-init配置..."
    
    mkdir -p /var/lib/vz/snippets
    CLOUDINIT_CUSTOM_USERCFG="/var/lib/vz/snippets/debian-root.yaml"
    
    # 创建cloud-init配置
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
  - systemctl restart ssh
  - echo "root:$CLOUDINIT_PASS" | chpasswd
EOF

    for idx in ${!VM_IDS[@]}; do
        id=${VM_IDS[$idx]}
        name=${VM_NAMES[$idx]}
        ip=${VM_IPS[$idx]}
        
        if qm list | grep -q " $id "; then
            log "修正虚拟机 $id 的cloud-init配置..."
            if qm status $id | grep -q "running"; then
                log "停止虚拟机 $id..."
                qm stop $id
                sleep 3
            fi
            qm set $id --ciuser root --cipassword $CLOUDINIT_PASS
            qm set $id --ipconfig0 ip=$ip/24,gw=$GATEWAY
            qm set $id --nameserver "$DNS"
            qm set $id --cicustom "user=local:snippets/debian-root.yaml"
            log "虚拟机 $id 配置已修正"
        fi
    done
}

# 部署K8S集群
deploy_k8s() {
    log "开始部署K8S集群..."
    
    # 等待所有虚拟机SSH可用
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

    # K8S master初始化
    log "[K8S] master节点初始化..."
        remote_cmd='set -e
echo "[K8S] 开始初始化..." | tee -a /root/k8s-init.log
apt-get update -y 2>&1 | tee -a /root/k8s-init.log
apt-get install -y apt-transport-https ca-certificates curl gnupg2 software-properties-common 2>&1 | tee -a /root/k8s-init.log
curl -fsSL https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg 2>&1 | tee -a /root/k8s-init.log
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y 2>&1 | tee -a /root/k8s-init.log
apt-get install -y kubelet kubeadm kubectl 2>&1 | tee -a /root/k8s-init.log
swapoff -a 2>&1 | tee -a /root/k8s-init.log
sed -i "/ swap / s/^/#/" /etc/fstab
modprobe br_netfilter
 echo "br_netfilter" > /etc/modules-load.d/br_netfilter.conf
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system 2>&1 | tee -a /root/k8s-init.log
apt-get install -y containerd 2>&1 | tee -a /root/k8s-init.log
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd
kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-advertise-address=$MASTER_IP --ignore-preflight-errors=NumCPU --ignore-preflight-errors=Mem 2>&1 | tee -a /root/k8s-init.log
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>&1 | tee -a /root/k8s-init.log
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml 2>&1 | tee -a /root/k8s-init.log
echo "[K8S] master初始化完成" | tee -a /root/k8s-init.log'
    
    if ! run_remote_cmd "$MASTER_IP" "$remote_cmd"; then
        err "K8S master初始化失败"
        return 1
    fi

    # 获取join命令
    log "获取K8S join命令..."
    JOIN_CMD=""
    for try in {1..10}; do
        JOIN_CMD=$(run_remote_cmd "$MASTER_IP" "kubeadm token create --print-join-command" 2>/dev/null || true)
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

    # worker节点加入集群
    for ip in "${WORKER_IPS[@]}"; do
        log "[K8S] $ip 加入集群..."
        worker_cmd='set -e
echo "[K8S] worker节点准备加入集群..." | tee -a /root/k8s-worker-join.log
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
apt-get install -y containerd 2>&1 | tee -a /root/k8s-worker-join.log
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd
sleep 10
'"$JOIN_CMD --ignore-preflight-errors=NumCPU --ignore-preflight-errors=Mem --ignore-preflight-errors=CRI 2>&1 | tee -a /root/k8s-worker-join.log"'
'
        
        if ! run_remote_cmd "$ip" "$worker_cmd"; then
            err "$ip 加入集群失败"
            return 1
        fi
        log "$ip 加入集群成功"
    done

    # 检查K8S集群状态
    log "[K8S] 检查集群状态..."
    sleep 30
    
    cluster_check_cmd='
echo "=== K8S集群状态检查 ==="
echo "1. 节点状态:"
kubectl get nodes -o wide 2>/dev/null || echo "无法获取节点信息"
echo ""
echo "2. Pod状态:"
kubectl get pods -n kube-system 2>/dev/null || echo "无法获取Pod信息"
echo ""
echo "=== 检查完成 ==="
'
    
    if run_remote_cmd "$MASTER_IP" "$cluster_check_cmd"; then
        READY_NODES=$(run_remote_cmd "$MASTER_IP" "kubectl get nodes --no-headers | grep -c \" Ready \" 2>/dev/null || echo \"0\"")
        TOTAL_NODES=$(run_remote_cmd "$MASTER_IP" "kubectl get nodes --no-headers | wc -l 2>/dev/null || echo \"0\"")
        
        log "集群节点状态: $READY_NODES/$TOTAL_NODES 节点就绪"
        
        if [ "$READY_NODES" -gt 0 ]; then
            log "K8S集群部署成功！"
    return 0
        else
            err "没有节点处于Ready状态，集群可能存在问题"
            return 1
        fi
    else
        err "K8S集群状态检查失败"
        return 1
    fi
}

# 部署KubeSphere
deploy_kubesphere() {
    log "开始部署KubeSphere..."
    
    # 检查K8S集群状态
    if ! run_remote_cmd "$MASTER_IP" "kubectl get nodes" 2>/dev/null; then
        err "K8S集群未就绪，请先部署K8S集群"
        return 1
    fi
    
    # 安装KubeSphere
    log "在master节点安装KubeSphere..."
    remote_cmd='set -e
cd /root || cd ~
echo "[KubeSphere] 开始安装KubeSphere..." | tee -a /root/kubesphere-install.log
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml 2>&1 | tee -a /root/kubesphere-install.log
kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml 2>&1 | tee -a /root/kubesphere-install.log
echo "[KubeSphere] 安装命令已执行，等待安装开始..." | tee -a /root/kubesphere-install.log
sleep 30
echo "[KubeSphere] 检查安装状态..." | tee -a /root/kubesphere-install.log
kubectl get pod -n kubesphere-system 2>/dev/null | tee -a /root/kubesphere-install.log || echo "kubesphere-system命名空间不存在，安装可能还在进行中" | tee -a /root/kubesphere-install.log
echo "[KubeSphere] 安装完成" | tee -a /root/kubesphere-install.log'
    
    if ! run_remote_cmd "$MASTER_IP" "$remote_cmd"; then
        err "KubeSphere安装失败"
        return 1
    fi
    
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

# 一键修复所有问题
fix_all_issues() {
    log "开始一键修复所有问题..."
                     echo ""
    echo -e "${CYAN}修复流程：${NC}"
    echo "1. 网络连通性测试"
    echo "2. 专门修复Calico网络问题"
    echo "3. 修复API服务器连接问题"
    echo "4. 修复kube-controller-manager崩溃"
    echo "5. 修复KubeSphere安装问题"
    echo "6. 强制修复KubeSphere安装器"
    echo "7. 配置防火墙规则"
    echo "8. 检查集群状态"
    echo "9. 检查KubeSphere控制台访问"
    echo "10. 生成访问信息"
                     echo ""
    read -p "是否继续执行一键修复？(y/n): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        warn "用户取消操作"
        return 0
    fi
    
    # 1. 网络连通性测试
    log "步骤1: 网络连通性测试"
    test_network_connectivity
    
    # 2. 专门修复Calico网络问题
    log "步骤2: 专门修复Calico网络问题"
    fix_calico_network
    

    
    # 等待网络稳定
    log "等待网络稳定..."
    sleep 60
    
    # 3. 修复API服务器连接问题
    log "步骤3: 修复API服务器连接问题"
    fix_api_server
    
    # 4. 修复kube-controller-manager崩溃
    log "步骤4: 修复kube-controller-manager崩溃"
    fix_controller_manager
    
    # 5. 修复KubeSphere安装问题
    log "步骤5: 修复KubeSphere安装问题"
    fix_kubesphere_installation
    
    # 6. 强制修复KubeSphere安装器
    log "步骤6: 强制修复KubeSphere安装器"
    force_fix_kubesphere_installer
    
    # 7. 配置防火墙规则
    log "步骤7: 配置防火墙规则"
    configure_firewall
    
    # 8. 检查集群状态
    log "步骤8: 检查集群状态"
    check_cluster_status_repair
    
    # 9. 检查KubeSphere控制台访问
    log "步骤9: 检查KubeSphere控制台访问"
    check_kubesphere_console
    
    # 10. 生成访问信息
    log "步骤10: 生成访问信息"
    generate_access_info
    
    success "一键修复完成！"
                         echo ""
    echo -e "${GREEN}修复总结：${NC}"
    echo "✓ 网络连通性已测试"
    echo "✓ Calico网络问题已专门修复"
    echo "✓ API服务器连接已修复"
    echo "✓ kube-controller-manager已重启"
    echo "✓ KubeSphere安装器已修复"
    echo "✓ 防火墙规则已配置"
    echo "✓ 集群状态已检查"
    echo "✓ 控制台访问已检查"
    echo "✓ 访问信息已生成"
    echo ""
    echo -e "${YELLOW}后续建议：${NC}"
    echo "1. 等待Calico网络完全稳定（5-10分钟）"
    echo "2. 等待KubeSphere安装完成（10-30分钟）"
    echo "3. 定期检查：kubectl get pods -n kubesphere-system"
    echo "4. 访问控制台：http://$MASTER_IP:30880"
    echo "5. 如有问题，可单独运行相应的修复功能"
}

# 快速状态检查
quick_status_check() {
    log "快速状态检查..."
    
    # 检查连接
    if ! run_remote_cmd "$MASTER_IP" "echo '连接测试成功'" 2>/dev/null; then
        err "无法连接到K8S主节点 $MASTER_IP"
        return 1
    fi
    
    # 检查K8S集群状态
    log "K8S集群状态:"
    run_remote_cmd "$MASTER_IP" "kubectl get nodes -o wide" || true
    
    # 检查关键Pod状态
    log "关键Pod状态:"
    run_remote_cmd "$MASTER_IP" '
        echo "=== kube-system ==="
        kubectl get pods -n kube-system | grep -E "(kube-apiserver|kube-controller-manager|kube-scheduler|etcd|calico|flannel)" || echo "未找到关键Pod"
        echo ""
        echo "=== kubesphere-system ==="
        kubectl get pods -n kubesphere-system 2>/dev/null || echo "kubesphere-system命名空间不存在"
    ' || true
    
    # 检查服务状态
    log "服务状态:"
    run_remote_cmd "$MASTER_IP" '
        echo "=== KubeSphere控制台服务 ==="
        kubectl get svc -n kubesphere-system ks-console 2>/dev/null || echo "控制台服务不存在"
        echo ""
        echo "=== 端口监听 ==="
        netstat -tlnp | grep -E ":30880|:6443" || echo "关键端口未监听"
    ' || true
    
    # 检查30880端口访问
    if nc -z $MASTER_IP 30880 2>/dev/null; then
        success "✓ KubeSphere控制台可访问 (http://$MASTER_IP:30880)"
    else
        warn "✗ KubeSphere控制台无法访问"
    fi
}

# 自动配置防火墙
configure_firewall() {
    log "配置防火墙规则..."
    
    run_remote_cmd "$MASTER_IP" '
        echo "=== 配置防火墙规则 ==="
        
        # 添加KubeSphere控制台端口
        iptables -I INPUT -p tcp --dport 30880 -j ACCEPT 2>/dev/null || true
        echo "✓ 已添加30880端口规则"
        
        # 添加K8S API端口
        iptables -I INPUT -p tcp --dport 6443 -j ACCEPT 2>/dev/null || true
        echo "✓ 已添加6443端口规则"
        
        # 添加NodePort范围
        iptables -I INPUT -p tcp --dport 30000:32767 -j ACCEPT 2>/dev/null || true
        echo "✓ 已添加NodePort范围规则"
        
        # 保存规则（如果系统支持）
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            echo "✓ 防火墙规则已保存"
        fi
        
        echo ""
        echo "当前防火墙规则:"
        iptables -L INPUT -n | grep -E "(30880|6443|30000:32767)" || echo "未找到相关规则"
    ' || true
    
    success "防火墙配置完成"
}

# 网络连通性测试
test_network_connectivity() {
    log "网络连通性测试..."
    
    # 测试主节点连接
    if ping -c 3 $MASTER_IP >/dev/null 2>&1; then
        success "✓ 主节点网络连通"
    else
        err "✗ 主节点网络不通"
    fi
    
    # 测试工作节点连接
    for worker_ip in "${WORKER_IPS[@]}"; do
        if ping -c 3 $worker_ip >/dev/null 2>&1; then
            success "✓ 工作节点 $worker_ip 网络连通"
        else
            warn "✗ 工作节点 $worker_ip 网络不通"
        fi
    done
    
    # 测试K8S API端口
    if nc -z $MASTER_IP 6443 2>/dev/null; then
        success "✓ K8S API端口 6443 可访问"
    else
        warn "✗ K8S API端口 6443 无法访问"
    fi
    
    # 测试KubeSphere控制台端口
    if nc -z $MASTER_IP 30880 2>/dev/null; then
        success "✓ KubeSphere控制台端口 30880 可访问"
    else
        warn "✗ KubeSphere控制台端口 30880 无法访问"
    fi
}

# 生成访问信息
generate_access_info() {
    log "生成访问信息..."
    
        echo ""
    echo -e "${CYAN}========== 访问信息 ==========${NC}"
    echo -e "${GREEN}KubeSphere控制台:${NC}"
    echo "  URL: http://$MASTER_IP:30880"
    echo "  默认用户名: admin"
    echo "  默认密码: P@88w0rd"
    echo ""
    echo -e "${GREEN}K8S集群信息:${NC}"
    echo "  API Server: https://$MASTER_IP:6443"
    echo "  主节点: $MASTER_IP"
    echo "  工作节点: ${WORKER_IPS[*]}"
    echo ""
    echo -e "${GREEN}常用命令:${NC}"
    echo "  检查节点: kubectl get nodes"
    echo "  检查Pod: kubectl get pods --all-namespaces"
    echo "  检查KubeSphere: kubectl get pods -n kubesphere-system"
    echo ""
    echo -e "${YELLOW}注意事项:${NC}"
    echo "1. 首次访问可能需要等待KubeSphere完全启动"
    echo "2. 如果无法访问，请检查防火墙设置"
    echo "3. 建议定期备份重要数据"
    echo -e "${CYAN}==============================${NC}"
}

# ==========================================
# 菜单与主流程区
# ==========================================
show_banner() {
    clear
    echo -e "${PURPLE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║                                                              ║${NC}"
    echo -e "${PURPLE}║  ${CYAN}$SCRIPT_NAME v$SCRIPT_VERSION${PURPLE}                    ║${NC}"
    echo -e "${PURPLE}║                                                              ║${NC}"
    echo -e "${PURPLE}║  ${GREEN}功能特性:${PURPLE}                                                ║${NC}"
    echo -e "${PURPLE}║  ${YELLOW}• 一键部署K8S+KubeSphere集群${PURPLE}                        ║${NC}"
    echo -e "${PURPLE}║  ${YELLOW}• 智能故障诊断与自动修复${PURPLE}                            ║${NC}"
    echo -e "${PURPLE}║  ${YELLOW}• 多源镜像下载与网络优化${PURPLE}                            ║${NC}"
    echo -e "${PURPLE}║  ${YELLOW}• 完整的日志记录与备份${PURPLE}                              ║${NC}"
    echo -e "${PURPLE}║                                                              ║${NC}"
    echo -e "${PURPLE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

show_menu() {
    show_banner
    echo -e "${CYAN}================================${NC}"
    echo -e "${CYAN}  主菜单${NC}"
    echo -e "${CYAN}================================${NC}"
    echo -e "${GREEN}基础功能:${NC}"
    echo -e "${YELLOW}1.${NC} 诊断PVE环境"
    echo -e "${YELLOW}2.${NC} 下载Debian Cloud镜像"
    echo -e "${YELLOW}3.${NC} 创建并启动虚拟机"
    echo -e "${YELLOW}4.${NC} 修正已存在虚拟机配置"
    echo ""
    echo -e "${GREEN}部署功能:${NC}"
    echo -e "${YELLOW}5.${NC} 部署K8S集群"
    echo -e "${YELLOW}6.${NC} 部署KubeSphere"
    echo -e "${YELLOW}7.${NC} 一键全自动部署"
    echo ""
    echo -e "${GREEN}管理功能:${NC}"
    echo -e "${YELLOW}8.${NC} 修复/诊断K8S与KubeSphere"
    echo -e "${YELLOW}9.${NC} 清理所有资源"
    echo ""
    echo -e "${GREEN}其他功能:${NC}"
    echo -e "${YELLOW}h.${NC} 显示帮助信息"
    echo -e "${YELLOW}v.${NC} 显示版本信息"
    echo -e "${YELLOW}0.${NC} 退出"
    echo -e "${CYAN}================================${NC}"
}

show_help() {
    clear
    echo -e "${CYAN}========== 帮助信息 ==========${NC}"
    echo ""
    echo -e "${GREEN}脚本说明:${NC}"
    echo "  这是一个在Proxmox VE环境中自动部署Kubernetes和KubeSphere的脚本"
    echo ""
    echo -e "${GREEN}系统要求:${NC}"
    echo "  • Proxmox VE 7.0+"
    echo "  • 内存: 至少32GB"
    echo "  • 磁盘: 至少500GB可用空间"
    echo "  • CPU: 至少12核心"
    echo "  • 网络: 互联网连接用于下载镜像"
    echo ""
    echo -e "${GREEN}虚拟机配置:${NC}"
    echo "  • k8s-master (10.0.0.10): 8核CPU, 16GB内存, 300GB磁盘"
    echo "  • k8s-worker1 (10.0.0.11): 8核CPU, 16GB内存, 300GB磁盘"
    echo "  • k8s-worker2 (10.0.0.12): 8核CPU, 16GB内存, 300GB磁盘"
    echo ""
    echo -e "${GREEN}使用流程:${NC}"
    echo "  1. 选择'1'诊断PVE环境"
    echo "  2. 选择'7'一键全自动部署，或按步骤逐一执行"
    echo "  3. 部署完成后访问: http://10.0.0.10:30880"
    echo "  4. 默认账号: admin / P@88w0rd"
    echo ""
    echo -e "${GREEN}故障排除:${NC}"
    echo "  • 如遇问题，选择'8'进入修复菜单"
    echo "  • 查看日志: $LOG_FILE"
    echo "  • 清理重新开始: 选择'9'清理所有资源"
    echo ""
    echo -e "${GREEN}注意事项:${NC}"
    echo "  • 确保网络配置正确，网关为10.0.0.1"
    echo "  • 部署过程需要20-60分钟，请耐心等待"
    echo "  • 建议在部署前备份重要数据"
    echo ""
    read -p "按回车键返回主菜单..."
}

show_version() {
    clear
    echo -e "${CYAN}========== 版本信息 ==========${NC}"
    echo ""
    echo -e "${GREEN}脚本名称:${NC} $SCRIPT_NAME"
    echo -e "${GREEN}版本号:${NC} v$SCRIPT_VERSION"
    echo -e "${GREEN}作者:${NC} WinsPan"
    echo -e "${GREEN}更新时间:${NC} 2024年"
    echo ""
    echo -e "${GREEN}更新历史:${NC}"
    echo "  v2.0 - 深度优化版"
    echo "    • 增强错误处理和日志记录"
    echo "    • 添加进度显示和用户反馈"
    echo "    • 优化网络连接和性能"
    echo "    • 增强安全性和稳定性检查"
    echo "    • 添加配置备份和恢复功能"
    echo ""
    echo "  v1.x - 基础功能版"
    echo "    • 基本的K8S和KubeSphere部署功能"
    echo "    • 故障诊断和修复功能"
    echo ""
    echo -e "${GREEN}系统信息:${NC}"
    echo "  • 操作系统: $(uname -s) $(uname -r)"
    echo "  • 架构: $(uname -m)"
    echo "  • PVE版本: $(pveversion 2>/dev/null | head -1 || echo '未检测到')"
    echo ""
    read -p "按回车键返回主菜单..."
}

# 配置验证
validate_config() {
    log "验证配置参数..."
    
    # 验证IP地址格式
    for ip in "${VM_IPS[@]}"; do
        if ! [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            err "无效的IP地址格式: $ip"
            return 1
        fi
    done
    
    # 验证虚拟机ID唯一性
    local used_ids=()
    for id in "${VM_IDS[@]}"; do
        if qm list | awk '{print $1}' | grep -q "^$id$"; then
            used_ids+=("$id")
        fi
    done
    
    if [[ ${#used_ids[@]} -gt 0 ]]; then
        warn "检测到已存在的虚拟机ID: ${used_ids[*]}"
        echo "  • 选择'4'修正已存在虚拟机配置"
        echo "  • 或选择'9'清理后重新部署"
    fi
    
    success "配置验证完成"
}

# 主菜单循环
main_menu() {
    while true; do
        show_menu
        read -p "请选择操作: " choice
        case $choice in
            1) diagnose_pve;;
            2) download_cloud_image;;
            3) create_and_start_vms;;
            4) fix_existing_vms;;
            5) deploy_k8s;;
            6) deploy_kubesphere;;
            7) auto_deploy_all;;
            8) repair_menu;;
            9) cleanup_all;;
            h|H) show_help;;
            v|V) show_version;;
            0) 
                log "用户退出程序"
                echo -e "${GREEN}感谢使用 $SCRIPT_NAME！${NC}"
                exit 0
                ;;
            *) 
                echo -e "${RED}无效选择，请重新输入${NC}"
                sleep 2
                ;;
        esac
    done
}

# 脚本入口点
main() {
    # 初始化
    init_logging
    
    # 显示启动信息
    show_banner
    echo -e "${GREEN}正在初始化...${NC}"
    
    # 环境检查
    check_environment
    
    # 安全检查
    security_check
    
    # 配置验证
    validate_config
    
    echo ""
    log "初始化完成，进入主菜单"
    sleep 2
    
    # 进入主菜单
    main_menu
}

# 脚本入口
main "$@" 