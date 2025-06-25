#!/bin/bash

# 快速修复脚本
# 用于解决常见的部署问题

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

# 显示帮助信息
show_help() {
    echo "快速修复脚本 - 解决常见部署问题"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -n, --network     测试并修复网络连接问题"
    echo "  -d, --download    手动下载Debian模板"
    echo "  -c, --cleanup     清理环境并重新开始"
    echo "  -s, --storage     检查并修复存储问题"
    echo "  -a, --all         执行所有修复步骤"
    echo "  -h, --help        显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 --network       # 修复网络问题"
    echo "  $0 --download      # 手动下载模板"
    echo "  $0 --all           # 执行所有修复"
}

# 修复网络连接问题
fix_network() {
    log_step "修复网络连接问题..."
    
    # 运行网络诊断
    if [ -f "./test-network.sh" ]; then
        log_info "运行网络诊断..."
        ./test-network.sh
    else
        log_warn "网络诊断脚本不存在，跳过网络测试"
    fi
    
    # 检查并设置代理（如果需要）
    if [ -n "$http_proxy" ] || [ -n "$https_proxy" ]; then
        log_info "检测到代理设置，配置wget代理..."
        echo "use_proxy = on" >> ~/.wgetrc
        echo "http_proxy = $http_proxy" >> ~/.wgetrc
        echo "https_proxy = $https_proxy" >> ~/.wgetrc
        log_success "代理配置完成"
    fi
    
    log_success "网络修复完成"
}

# 手动下载Debian模板
fix_download() {
    log_step "手动下载Debian模板..."
    
    # 确保目录存在
    mkdir -p /var/lib/vz/template/cache
    cd /var/lib/vz/template/cache
    
    TEMPLATE_FILE="debian-12-standard_12.2-1_amd64.tar.zst"
    
    # 检查文件是否已存在
    if [ -f "$TEMPLATE_FILE" ]; then
        log_info "Debian模板已存在，跳过下载"
        return 0
    fi
    
    # 尝试从中国镜像源下载
    log_info "尝试从中国镜像源下载..."
    
    local urls=(
        "https://mirrors.ustc.edu.cn/proxmox/images/system/debian-12-standard_12.2-1_amd64.tar.zst"
        "https://mirrors.tuna.tsinghua.edu.cn/proxmox/images/system/debian-12-standard_12.2-1_amd64.tar.zst"
        "https://download.proxmox.com/images/system/debian-12-standard_12.2-1_amd64.tar.zst"
    )
    
    for url in "${urls[@]}"; do
        log_info "尝试从 $url 下载..."
        
        if wget -q --show-progress --timeout=30 --tries=3 "$url"; then
            log_success "下载成功"
            
            if [ -f "$TEMPLATE_FILE" ] && [ -s "$TEMPLATE_FILE" ]; then
                log_info "文件验证成功，大小: $(du -h "$TEMPLATE_FILE" | cut -f1)"
                return 0
            else
                log_warn "文件可能不完整，尝试下一个源"
                rm -f "$TEMPLATE_FILE"
                continue
            fi
        else
            log_warn "下载失败，尝试下一个源"
            continue
        fi
    done
    
    # 如果wget失败，尝试curl
    log_info "尝试使用curl下载..."
    for url in "${urls[@]}"; do
        log_info "使用curl从 $url 下载..."
        
        if curl -L -o "$TEMPLATE_FILE" --connect-timeout 30 --max-time 300 "$url"; then
            log_success "curl下载成功"
            
            if [ -f "$TEMPLATE_FILE" ] && [ -s "$TEMPLATE_FILE" ]; then
                log_info "文件验证成功，大小: $(du -h "$TEMPLATE_FILE" | cut -f1)"
                return 0
            else
                log_warn "curl下载的文件可能不完整"
                rm -f "$TEMPLATE_FILE"
                continue
            fi
        else
            log_warn "curl下载失败"
            continue
        fi
    done
    
    # 尝试PVE内置功能
    log_info "尝试使用PVE内置下载功能..."
    if pveam update && pveam download local debian-12-standard_12.2-1_amd64.tar.zst; then
        log_success "PVE内置下载成功"
        return 0
    fi
    
    log_error "所有下载方法都失败"
    log_info "请手动下载模板文件："
    log_info "cd /var/lib/vz/template/cache"
    log_info "wget https://mirrors.ustc.edu.cn/proxmox/images/system/debian-12-standard_12.2-1_amd64.tar.zst"
    return 1
}

# 清理环境
fix_cleanup() {
    log_step "清理环境..."
    
    if [ -f "./04-cleanup.sh" ]; then
        log_info "运行清理脚本..."
        ./04-cleanup.sh
        log_success "环境清理完成"
    else
        log_warn "清理脚本不存在，手动清理..."
        
        # 手动清理虚拟机
        for vm_id in 101 102 103; do
            if qm list | grep -q "$vm_id"; then
                log_info "删除虚拟机 $vm_id..."
                qm stop $vm_id 2>/dev/null || true
                qm destroy $vm_id 2>/dev/null || true
            fi
        done
        
        # 清理模板文件
        rm -f /var/lib/vz/template/cache/debian-12-standard_12.2-1_amd64.tar.zst
        
        log_success "手动清理完成"
    fi
}

# 修复存储问题
fix_storage() {
    log_step "检查并修复存储问题..."
    
    # 检查磁盘空间
    log_info "检查磁盘空间..."
    df -h
    
    # 检查存储状态
    if command -v pvesm > /dev/null 2>&1; then
        log_info "检查存储状态..."
        pvesm status
    fi
    
    # 清理临时文件
    log_info "清理临时文件..."
    rm -rf /var/lib/vz/template/cache/*.tmp 2>/dev/null || true
    rm -rf /tmp/*.tmp 2>/dev/null || true
    
    # 清理日志文件
    log_info "清理日志文件..."
    journalctl --vacuum-time=7d 2>/dev/null || true
    
    log_success "存储修复完成"
}

# 重新开始部署
restart_deployment() {
    log_step "重新开始部署..."
    
    # 清理环境
    fix_cleanup
    
    # 修复网络
    fix_network
    
    # 下载模板
    fix_download
    
    # 修复存储
    fix_storage
    
    log_success "环境准备完成，可以重新运行部署脚本"
    log_info "运行: ./01-pve-prepare.sh"
}

# 主函数
main() {
    echo "=========================================="
    echo "🔧 快速修复工具"
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
            -n|--network)
                fix_network
                shift
                ;;
            -d|--download)
                fix_download
                shift
                ;;
            -c|--cleanup)
                fix_cleanup
                shift
                ;;
            -s|--storage)
                fix_storage
                shift
                ;;
            -a|--all)
                restart_deployment
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
    
    echo ""
    echo "=========================================="
    echo "✅ 修复完成！"
    echo "=========================================="
}

# 执行主函数
main "$@" 