#!/bin/bash

# SSH连接诊断脚本
# 用于诊断虚拟机SSH连接问题

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
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

# 配置
VM_BASE_ID=101
VM_IPS=("10.0.0.10" "10.0.0.11" "10.0.0.12")
VM_NAMES=("k8s-master" "k8s-worker1" "k8s-worker2")

# 检查虚拟机状态
check_vm_status() {
    log_step "检查虚拟机状态..."
    
    for i in "${!VM_NAMES[@]}"; do
        vm_id=$((VM_BASE_ID + i))
        vm_name="${VM_NAMES[$i]}"
        vm_ip="${VM_IPS[$i]}"
        
        log_info "检查虚拟机: $vm_name (ID: $vm_id, IP: $vm_ip)"
        
        # 检查虚拟机是否存在
        if qm list | grep -q "$vm_id"; then
            vm_status=$(qm list | grep "$vm_id" | awk '{print $3}')
            log_info "  状态: $vm_status"
            
            # 检查虚拟机详细信息
            if [ "$vm_status" = "running" ]; then
                log_success "  虚拟机正在运行"
                
                # 检查网络配置
                log_info "  检查网络配置..."
                qm config $vm_id | grep -E "(net0|ipconfig0)" || log_warn "  未找到网络配置"
                
            else
                log_warn "  虚拟机未运行，尝试启动..."
                qm start $vm_id
                sleep 10
            fi
        else
            log_error "  虚拟机不存在"
        fi
        
        echo ""
    done
}

# 检查网络连接
check_network_connectivity() {
    log_step "检查网络连接..."
    
    for i in "${!VM_IPS[@]}"; do
        vm_ip="${VM_IPS[$i]}"
        vm_name="${VM_NAMES[$i]}"
        
        log_info "检查 $vm_name ($vm_ip) 网络连接..."
        
        # Ping测试
        if ping -c 1 $vm_ip > /dev/null 2>&1; then
            log_success "  Ping成功"
        else
            log_error "  Ping失败"
        fi
        
        # SSH端口测试
        if nc -z $vm_ip 22 2>/dev/null; then
            log_success "  SSH端口开放"
        else
            log_warn "  SSH端口关闭"
        fi
        
        # 尝试SSH连接
        if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no root@$vm_ip "echo 'SSH连接成功'" > /dev/null 2>&1; then
            log_success "  SSH连接成功"
        else
            log_warn "  SSH连接失败"
        fi
        
        echo ""
    done
}

# 检查虚拟机控制台
check_vm_console() {
    log_step "检查虚拟机控制台..."
    
    for i in "${!VM_NAMES[@]}"; do
        vm_id=$((VM_BASE_ID + i))
        vm_name="${VM_NAMES[$i]}"
        
        log_info "检查 $vm_name 控制台..."
        
        # 检查虚拟机状态
        vm_status=$(qm list | grep "$vm_id" | awk '{print $3}' 2>/dev/null || echo "unknown")
        
        if [ "$vm_status" = "running" ]; then
            log_info "  虚拟机正在运行，可以通过以下命令访问控制台："
            log_info "  qm terminal $vm_id"
        else
            log_warn "  虚拟机未运行，状态: $vm_status"
        fi
        
        echo ""
    done
}

# 重启虚拟机
restart_vms() {
    log_step "重启虚拟机..."
    
    for i in "${!VM_NAMES[@]}"; do
        vm_id=$((VM_BASE_ID + i))
        vm_name="${VM_NAMES[$i]}"
        
        log_info "重启 $vm_name (ID: $vm_id)..."
        
        # 停止虚拟机
        qm stop $vm_id 2>/dev/null || true
        sleep 5
        
        # 启动虚拟机
        qm start $vm_id
        log_success "  $vm_name 重启完成"
        
        # 等待启动
        sleep 30
    done
}

# 显示帮助信息
show_help() {
    echo "SSH连接诊断工具"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -s, --status     检查虚拟机状态"
    echo "  -n, --network    检查网络连接"
    echo "  -c, --console    检查虚拟机控制台"
    echo "  -r, --restart    重启所有虚拟机"
    echo "  -a, --all        执行所有检查"
    echo "  -h, --help       显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 --status       # 检查虚拟机状态"
    echo "  $0 --network      # 检查网络连接"
    echo "  $0 --all          # 执行所有检查"
}

# 主函数
main() {
    echo "=========================================="
    echo "🔍 SSH连接诊断工具"
    echo "=========================================="
    echo ""
    
    # 检查参数
    if [ $# -eq 0 ]; then
        show_help
        exit 1
    fi
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--status)
                check_vm_status
                shift
                ;;
            -n|--network)
                check_network_connectivity
                shift
                ;;
            -c|--console)
                check_vm_console
                shift
                ;;
            -r|--restart)
                restart_vms
                shift
                ;;
            -a|--all)
                check_vm_status
                echo ""
                check_network_connectivity
                echo ""
                check_vm_console
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    echo "=========================================="
    echo "✅ 诊断完成！"
    echo "=========================================="
    echo ""
    echo "如果SSH连接有问题，可以尝试："
    echo "1. 重启虚拟机: $0 --restart"
    echo "2. 检查控制台: qm terminal <VMID>"
    echo "3. 手动SSH连接: ssh root@<VM_IP>"
    echo "4. 查看虚拟机日志: qm monitor <VMID>"
}

# 执行主函数
main "$@" 