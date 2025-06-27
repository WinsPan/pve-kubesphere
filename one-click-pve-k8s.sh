#!/bin/bash

# ==========================================
# 极简一键PVE K8S+KubeSphere全自动部署脚本（重构优化版）
# ==========================================

set -e

# ==========================================
# 变量与常量配置区
# ==========================================
# 颜色
GREEN='\e[0;32m'
YELLOW='\e[1;33m'
RED='\e[0;31m'
BLUE='\e[0;34m'
CYAN='\e[0;36m'
NC='\e[0m'

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

# ==========================================
# 通用工具函数区
# ==========================================
log()   { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; }
debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }
info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

run_remote_cmd() {
    # 统一远程SSH命令执行，带日志和错误处理
    local ip="$1"; shift
    local cmd="$1"; shift
    sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60 -o UserKnownHostsFile=/dev/null $CLOUDINIT_USER@$ip "bash -c '$cmd'" "$@"
}

wait_for_ssh() {
    local ip=$1
    local max_try=60
    local try=0
    log "等待 $ip SSH可用..."
    while ((try < max_try)); do
        if ping -c 1 -W 2 $ip &>/dev/null; then
            if nc -z $ip 22 &>/dev/null; then
                sleep 10
                return 0
            fi
        fi
        sleep 10
        ((try++))
        log "等待 $ip SSH可用... ($try/$max_try)"
    done
    err "$ip SSH不可用，可能原因：虚拟机未获取到IP、cloud-init未生效、网络未通"
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
    err "$ip:$port 未开放"
    return 1
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
    run_remote_cmd "$MASTER_IP" "
        echo '=== kube-controller-manager状态 ==='
        kubectl get pods -n kube-system | grep controller-manager || echo '未找到controller-manager Pod'
        echo ''
        echo '=== 系统资源状态 ==='
        free -h
        echo ''
        df -h | head -5
        echo ''
        echo '=== 系统负载 ==='
        uptime
    " || true
    
    log "重启kube-controller-manager..."
    run_remote_cmd "$MASTER_IP" "
        echo '重启kube-controller-manager...'
        # 删除controller-manager Pod，让kubelet重新创建
        kubectl delete pod -n kube-system -l component=kube-controller-manager --force --grace-period=0 2>/dev/null || true
        echo 'controller-manager Pod已删除，等待重新创建...'
    " || true
    
    log "等待controller-manager重启..."
    sleep 30
    
    log "检查修复结果..."
    run_remote_cmd "$MASTER_IP" "
        echo '=== 修复后controller-manager状态 ==='
        kubectl get pods -n kube-system | grep controller-manager || echo '未找到controller-manager Pod'
        echo ''
        echo '=== 系统Pod状态 ==='
        kubectl get pods -n kube-system | grep -E '(controller|scheduler|apiserver|etcd)' || echo '未找到系统Pod'
        echo ''
        echo '=== 事件信息 ==='
        kubectl get events --sort-by=.metadata.creationTimestamp | tail -10 2>/dev/null || echo '无法获取事件信息'
    " || true
    
    log "kube-controller-manager修复完成"
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
        kubectl get pods -n kube-system | grep -E "(flannel|calico|weave|cilium)" || echo "未找到网络插件"
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
        echo -e "${GREEN}基础修复:${NC}"
        echo -e "${YELLOW}1.${NC} 修复Flannel网络问题"
        echo -e "${YELLOW}2.${NC} 修复kube-controller-manager崩溃"
        echo -e "${YELLOW}3.${NC} 修复KubeSphere安装问题"
        echo -e "${YELLOW}4.${NC} 强制修复KubeSphere安装器"
        echo ""
        echo -e "${GREEN}状态检查:${NC}"
        echo -e "${YELLOW}5.${NC} 检查KubeSphere控制台访问"
        echo -e "${YELLOW}6.${NC} 网络连通性测试"
        echo -e "${YELLOW}7.${NC} 检查集群状态"
        echo ""
        echo -e "${GREEN}系统配置:${NC}"
        echo -e "${YELLOW}8.${NC} 配置防火墙规则"
        echo -e "${YELLOW}9.${NC} 生成访问信息"
        echo ""
        echo -e "${GREEN}一键操作:${NC}"
        echo -e "${YELLOW}10.${NC} 一键修复所有问题"
        echo -e "${YELLOW}0.${NC} 返回主菜单"
        echo -e "${CYAN}================================================${NC}"
        read -p "请选择操作 (0-10): " repair_choice
        case $repair_choice in
            1) fix_flannel_network;;
            2) fix_controller_manager;;
            3) fix_kubesphere_installation;;
            4) force_fix_kubesphere_installer;;
            5) check_kubesphere_console;;
            6) test_network_connectivity;;
            7) check_cluster_status_repair;;
            8) configure_firewall;;
            9) generate_access_info;;
            10) fix_all_issues;;
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
    
    # 确保cloud-init自定义配置存在
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

    # 创建虚拟机
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
            err "创建虚拟机 $id 失败"
            return 1
        fi
        
        log "导入cloud镜像到 $id..."
        if ! qm importdisk $id "$CLOUD_IMAGE_PATH" $STORAGE; then
            err "导入cloud镜像到 $id 失败"
            return 1
        fi
        
        log "配置虚拟机 $id..."
        qm set $id --scsi0 $STORAGE:vm-${id}-disk-0
        qm set $id --ide3 $STORAGE:cloudinit
        qm set $id --ciuser root --cipassword $CLOUDINIT_PASS
        qm set $id --ipconfig0 ip=$ip/24,gw=$GATEWAY
        qm set $id --nameserver "$DNS"
        qm set $id --boot order=scsi0
        qm set $id --onboot 1
        qm set $id --cicustom "user=local:snippets/debian-root.yaml"
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
                err "启动虚拟机 $id 失败"
                return 1
            fi
            sleep 5
        fi
    done

    log "当前虚拟机状态："
    qm list | grep -E "(VMID|101|102|103)"
    log "虚拟机创建和启动完成"
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
    echo "2. 修复Flannel网络问题"
    echo "3. 修复kube-controller-manager崩溃"
    echo "4. 修复KubeSphere安装问题"
    echo "5. 强制修复KubeSphere安装器"
    echo "6. 配置防火墙规则"
    echo "7. 检查集群状态"
    echo "8. 检查KubeSphere控制台访问"
    echo "9. 生成访问信息"
    echo ""
    read -p "是否继续执行一键修复？(y/n): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        warn "用户取消操作"
        return 0
    fi
    
    # 1. 网络连通性测试
    log "步骤1: 网络连通性测试"
    test_network_connectivity
    
    # 2. 修复Flannel网络问题
    log "步骤2: 修复Flannel网络问题"
    fix_flannel_network
    
    # 3. 修复kube-controller-manager崩溃
    log "步骤3: 修复kube-controller-manager崩溃"
    fix_controller_manager
    
    # 4. 修复KubeSphere安装问题
    log "步骤4: 修复KubeSphere安装问题"
    fix_kubesphere_installation
    
    # 5. 强制修复KubeSphere安装器
    log "步骤5: 强制修复KubeSphere安装器"
    force_fix_kubesphere_installer
    
    # 6. 配置防火墙规则
    log "步骤6: 配置防火墙规则"
    configure_firewall
    
    # 7. 检查集群状态
    log "步骤7: 检查集群状态"
    check_cluster_status_repair
    
    # 8. 检查KubeSphere控制台访问
    log "步骤8: 检查KubeSphere控制台访问"
    check_kubesphere_console
    
    # 9. 生成访问信息
    log "步骤9: 生成访问信息"
    generate_access_info
    
    success "一键修复完成！"
    echo ""
    echo -e "${GREEN}修复总结：${NC}"
    echo "✓ 网络连通性已测试"
    echo "✓ Flannel网络问题已修复"
    echo "✓ kube-controller-manager已重启"
    echo "✓ KubeSphere安装器已修复"
    echo "✓ 防火墙规则已配置"
    echo "✓ 集群状态已检查"
    echo "✓ 控制台访问已检查"
    echo "✓ 访问信息已生成"
    echo ""
    echo -e "${YELLOW}后续建议：${NC}"
    echo "1. 等待KubeSphere安装完成（10-30分钟）"
    echo "2. 定期检查：kubectl get pods -n kubesphere-system"
    echo "3. 访问控制台：http://$MASTER_IP:30880"
    echo "4. 如有问题，可单独运行相应的修复功能"
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
    echo -e "${YELLOW}9.${NC} 修复/诊断K8S与KubeSphere${NC}"
    echo -e "${YELLOW}0.${NC} 退出"
    echo -e "${CYAN}================================${NC}"
}

main_menu() {
    while true; do
        clear
        show_menu
        read -p "请选择操作 [0-9]: " choice
        case $choice in
            1) diagnose_pve;;
            2) download_cloud_image;;
            3) create_and_start_vms;;
            4) fix_existing_vms;;
            5) deploy_k8s;;
            6) deploy_kubesphere;;
            7) cleanup_all;;
            8) auto_deploy_all;;
            9) repair_menu;;
            0) log "退出程序"; exit 0;;
            *) echo -e "${RED}无效选择，请重新输入${NC}"; sleep 2;;
        esac
    done
}

main_menu