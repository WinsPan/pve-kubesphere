#!/bin/bash

# 快速修复Debian虚拟机串口终端提示问题
# 这个脚本会快速删除虚拟机的串口配置

echo "🔧 快速修复串口终端提示问题..."

# 检查PVE环境
if ! command -v qm &> /dev/null; then
    echo "❌ 此脚本需要在PVE环境中运行"
    exit 1
fi

# 修复虚拟机101-103的串口配置
for vm_id in 101 102 103; do
    vm_name=""
    case $vm_id in
        101) vm_name="k8s-master" ;;
        102) vm_name="k8s-worker1" ;;
        103) vm_name="k8s-worker2" ;;
    esac
    
    echo "📝 修复虚拟机 $vm_name (ID: $vm_id)..."
    
    # 检查虚拟机是否存在
    if ! qm list | grep -q "$vm_id"; then
        echo "⚠️  虚拟机 $vm_name 不存在，跳过"
        continue
    fi
    
    # 停止虚拟机（如果正在运行）
    if qm list | grep "$vm_id" | grep -q "running"; then
        echo "🛑 停止虚拟机 $vm_name..."
        qm stop $vm_id
        sleep 5
    fi
    
    # 删除串口配置
    echo "🗑️  删除串口配置..."
    qm set $vm_id --delete serial0 2>/dev/null || true
    
    # 设置VGA为标准模式
    echo "🖥️  设置VGA为标准模式..."
    qm set $vm_id --vga std
    
    # 确保启动配置正确
    echo "⚙️  确保启动配置正确..."
    qm set $vm_id --boot c --bootdisk scsi0
    
    echo "✅ 虚拟机 $vm_name 修复完成"
    echo ""
done

echo "🎉 所有虚拟机串口配置修复完成！"
echo ""
echo "📋 修复内容："
echo "   ✓ 删除了串口配置 (serial0)"
echo "   ✓ 设置VGA为标准模式"
echo "   ✓ 确保启动配置正确"
echo ""
echo "🔧 现在启动虚拟机时应该不会再看到串口终端提示"
echo ""
echo "💡 如果需要启动虚拟机，请运行："
echo "   qm start 101  # 启动master节点"
echo "   qm start 102  # 启动worker1节点"
echo "   qm start 103  # 启动worker2节点" 