#!/bin/bash

# 修复Debian虚拟机串口终端提示问题
# 这个脚本会修改虚拟机配置，禁用串口控制台以避免启动时的串口终端提示

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
VM_BASE_ID=101
VM_COUNT=3

# 虚拟机配置数组
VM_CONFIGS=(
    "k8s-master"
    "k8s-worker1"
    "k8s-worker2"
)

# 修复单个虚拟机的串口配置
fix_vm_serial_config() {
    local vm_id=$1
    local vm_name=$2
    
    log_info "修复虚拟机 $vm_name (ID: $vm_id) 的串口配置..."
    
    # 检查虚拟机是否存在
    if ! qm list | grep -q "$vm_id"; then
        log_error "虚拟机 $vm_name (ID: $vm_id) 不存在"
        return 1
    fi
    
    # 停止虚拟机（如果正在运行）
    if qm list | grep "$vm_id" | grep -q "running"; then
        log_info "停止虚拟机 $vm_name..."
        qm stop $vm_id
        sleep 10
    fi
    
    # 删除串口配置
    log_info "删除串口配置..."
    qm set $vm_id --delete serial0 2>/dev/null || true
    
    # 设置VGA为默认值（不使用串口）
    log_info "设置VGA为默认配置..."
    qm set $vm_id --vga std
    
    # 确保启动配置正确
    log_info "确保启动配置正确..."
    qm set $vm_id --boot c --bootdisk scsi0
    
    # 验证配置
    log_info "验证配置..."
    if qm config $vm_id | grep -q "serial0"; then
        log_error "串口配置仍然存在，尝试强制删除..."
        qm set $vm_id --delete serial0
    else
        log_success "串口配置已成功删除"
    fi
    
    # 显示修改后的配置
    log_info "虚拟机 $vm_name 的当前配置："
    qm config $vm_id | grep -E "(vga|serial|boot)"
    
    return 0
}

# 修复所有虚拟机的串口配置
fix_all_vm_serial_config() {
    log_step "修复所有虚拟机的串口配置..."
    
    local success_count=0
    local total_count=$VM_COUNT
    
    for i in "${!VM_CONFIGS[@]}"; do
        vm_name="${VM_CONFIGS[$i]}"
        vm_id=$((VM_BASE_ID + i))
        
        echo ""
        if fix_vm_serial_config $vm_id $vm_name; then
            success_count=$((success_count + 1))
        fi
    done
    
    echo ""
    log_info "修复结果: ${success_count}/${total_count} 个虚拟机配置成功"
    
    if [ $success_count -eq $total_count ]; then
        log_success "所有虚拟机串口配置修复完成！"
        return 0
    else
        log_warn "部分虚拟机配置修复失败"
        return 1
    fi
}

# 启动虚拟机并验证
start_and_verify_vms() {
    log_step "启动虚拟机并验证..."
    
    for i in "${!VM_CONFIGS[@]}"; do
        vm_name="${VM_CONFIGS[$i]}"
        vm_id=$((VM_BASE_ID + i))
        
        log_info "启动虚拟机 $vm_name..."
        qm start $vm_id
        
        # 等待虚拟机启动
        sleep 30
        
        # 检查虚拟机状态
        if qm list | grep "$vm_id" | grep -q "running"; then
            log_success "虚拟机 $vm_name 启动成功"
        else
            log_error "虚拟机 $vm_name 启动失败"
        fi
    done
}

# 显示虚拟机状态
show_vm_status() {
    log_step "虚拟机状态:"
    qm list | grep -E "(VMID|k8s)"
}

# 主函数
main() {
    log_info "开始修复Debian虚拟机串口终端提示问题..."
    echo ""
    
    # 检查PVE环境
    if ! command -v qm &> /dev/null; then
        log_error "此脚本需要在PVE环境中运行"
        exit 1
    fi
    
    # 修复所有虚拟机的串口配置
    fix_all_vm_serial_config
    
    # 启动虚拟机并验证
    start_and_verify_vms
    
    # 显示虚拟机状态
    show_vm_status
    
    echo ""
    echo "=========================================="
    echo "🎉 串口终端提示问题修复完成！"
    echo "=========================================="
    echo ""
    echo "📋 修复内容："
    echo "   ✓ 删除了所有虚拟机的串口配置"
    echo "   ✓ 设置VGA为标准模式"
    echo "   ✓ 确保启动配置正确"
    echo ""
    echo "🔧 现在启动虚拟机时应该不会再看到串口终端提示"
    echo "=========================================="
}

# 执行主函数
main "$@" 