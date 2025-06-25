#!/bin/bash

# PVE KubeSphere 一键部署脚本 (完整版)
# 包含所有最新的修复和改进
# 作者：AI Assistant
# 日期：$(date +%Y-%m-%d)

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
GITHUB_REPO="WinsPan/pve-kubesphere"
BRANCH="main"
INSTALL_DIR="pve-kubesphere-$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="pve-kubesphere-backup-$(date +%Y%m%d-%H%M%S)"

# 需要下载的文件列表
REQUIRED_FILES=(
    "01-pve-prepare.sh"
    "02-k8s-install.sh"
    "03-kubesphere-install.sh"
    "04-cleanup.sh"
    "deploy-all.sh"
    "quick-deploy.sh"
    "quick-fix.sh"
    "test-network.sh"
    "diagnose-ssh.sh"
    "fix-serial-terminal.sh"
    "quick-fix-serial.sh"
    "README-KubeSphere.md"
    "QUICK-START.md"
    "CONFIG-SUMMARY.md"
    "CHECK-REPORT.md"
    "RESOURCE-REQUIREMENTS.md"
    "TROUBLESHOOTING.md"
    "FIX-SUMMARY.md"
    "SERIAL-TERMINAL-FIX.md"
    ".gitignore"
)

# 检查系统要求
check_system_requirements() {
    log_step "检查系统要求..."
    
    # 检查操作系统
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        log_info "操作系统: Linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        log_info "操作系统: macOS"
    else
        log_error "不支持的操作系统: $OSTYPE"
        exit 1
    fi
    
    # 检查必要工具
    local required_tools=("curl" "wget" "git" "bash")
    for tool in "${required_tools[@]}"; do
        if ! command -v $tool &> /dev/null; then
            log_error "缺少必要工具: $tool"
            exit 1
        fi
    done
    
    log_success "系统要求检查通过"
}

# 备份现有安装
backup_existing() {
    if [ -d "pve-kubesphere" ]; then
        log_step "备份现有安装..."
        mv "pve-kubesphere" "$BACKUP_DIR"
        log_info "现有安装已备份到: $BACKUP_DIR"
    fi
}

# 从GitHub下载所有文件
download_from_github() {
    log_step "从GitHub下载部署脚本..."
    
    # 创建安装目录
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    local success_count=0
    local total_count=${#REQUIRED_FILES[@]}
    
    log_info "开始下载 $total_count 个文件..."
    
    for file in "${REQUIRED_FILES[@]}"; do
        log_info "下载: $file"
        
        # 尝试多个下载源
        local download_success=false
        
        # 方法1: 使用curl
        if curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPO/$BRANCH/$file" -o "$file" 2>/dev/null; then
            download_success=true
        # 方法2: 使用wget
        elif wget -q "https://raw.githubusercontent.com/$GITHUB_REPO/$BRANCH/$file" -O "$file" 2>/dev/null; then
            download_success=true
        fi
        
        if [ "$download_success" = true ]; then
            log_success "✓ $file 下载成功"
            ((success_count++))
        else
            log_error "✗ $file 下载失败"
        fi
    done
    
    # 添加执行权限
    chmod +x *.sh 2>/dev/null || true
    
    log_info "下载完成: $success_count/$total_count 个文件成功"
    
    if [ $success_count -eq $total_count ]; then
        log_success "所有文件下载成功"
        return 0
    else
        log_warn "部分文件下载失败，但继续执行"
        return 1
    fi
}

# 验证关键文件
verify_critical_files() {
    log_step "验证关键文件..."
    
    local critical_files=(
        "01-pve-prepare.sh"
        "02-k8s-install.sh"
        "03-kubesphere-install.sh"
        "deploy-all.sh"
    )
    
    for file in "${critical_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_error "关键文件缺失: $file"
            return 1
        fi
        
        if [ ! -x "$file" ]; then
            log_info "为 $file 添加执行权限"
            chmod +x "$file"
        fi
    done
    
    log_success "关键文件验证通过"
    return 0
}

# 显示部署信息
show_deployment_info() {
    log_step "部署信息..."
    echo "=========================================="
    echo "🎯 PVE KubeSphere 一键部署"
    echo "=========================================="
    echo ""
    echo "📋 部署内容："
    echo "   • 创建3个Debian虚拟机 (8核16GB 300GB)"
    echo "   • 安装Kubernetes v1.29.7集群"
    echo "   • 安装KubeSphere v4.1.3"
    echo "   • 配置存储和网络"
    echo "   • 自动修复常见问题"
    echo ""
    echo "🔧 虚拟机配置："
    echo "   • Master节点: 10.0.0.10"
    echo "   • Worker1节点: 10.0.0.11"
    echo "   • Worker2节点: 10.0.0.12"
    echo ""
    echo "⏱️  预计时间：30-60分钟"
    echo "=========================================="
    echo ""
}

# 确认部署
confirm_deployment() {
    log_warn "⚠️  重要提醒："
    log_warn "1. 此操作将在PVE主机上创建虚拟机"
    log_warn "2. 确保PVE主机有足够的资源 (至少24核48GB)"
    log_warn "3. 确保网络连接正常"
    log_warn "4. 建议在PVE主机上直接执行此脚本"
    log_warn ""
    
    read -p "是否开始部署？(输入 'yes' 确认): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_info "部署已取消"
        exit 0
    fi
    
    log_info "开始部署..."
}

# 执行部署
execute_deployment() {
    log_step "开始执行部署..."
    
    # 检查是否在PVE环境中
    if ! command -v qm &> /dev/null; then
        log_warn "未检测到PVE环境，但继续执行..."
        log_warn "建议在PVE主机上运行此脚本"
    fi
    
    # 执行一键部署
    if ./deploy-all.sh; then
        log_success "部署完成！"
        return 0
    else
        log_error "部署失败，错误代码: $?"
        return 1
    fi
}

# 显示部署结果
show_deployment_result() {
    log_step "部署完成！"
    echo "=========================================="
    echo "🎉 KubeSphere部署成功！"
    echo "=========================================="
    echo ""
    echo "📋 访问信息："
    echo "   KubeSphere控制台: http://10.0.0.10:30880"
    echo "   用户名: admin"
    echo "   密码: P@88w0rd"
    echo ""
    echo "🔧 管理命令："
    echo "   SSH到主节点: ssh root@10.0.0.10"
    echo "   查看集群状态: kubectl get nodes"
    echo "   查看pods: kubectl get pods --all-namespaces"
    echo ""
    echo "🛠️  故障排除工具："
    echo "   • 网络诊断: ./test-network.sh"
    echo "   • SSH诊断: ./diagnose-ssh.sh --all"
    echo "   • 快速修复: ./quick-fix.sh --all"
    echo "   • 串口修复: ./fix-serial-terminal.sh"
    echo ""
    echo "📚 文档："
    echo "   • 详细说明: README-KubeSphere.md"
    echo "   • 快速开始: QUICK-START.md"
    echo "   • 故障排除: TROUBLESHOOTING.md"
    echo "   • 串口修复: SERIAL-TERMINAL-FIX.md"
    echo ""
    echo "⚠️  注意事项："
    echo "   1. 首次访问可能需要等待几分钟"
    echo "   2. 建议更改默认密码"
    echo "   3. 定期备份重要数据"
    echo "   4. 如遇问题请查看故障排除文档"
    echo "=========================================="
}

# 清理临时文件
cleanup_temp() {
    log_step "清理临时文件..."
    
    read -p "是否删除下载的脚本文件？(输入 'yes' 确认): " cleanup_confirm
    
    if [ "$cleanup_confirm" = "yes" ]; then
        cd ..
        rm -rf "$INSTALL_DIR"
        log_info "临时文件已清理"
    else
        log_info "保留脚本文件在: $INSTALL_DIR"
        log_info "您可以继续使用这些脚本进行维护"
    fi
}

# 错误处理
handle_error() {
    local error_code=$1
    local error_step=$2
    
    log_error "部署在第 $error_step 步失败，错误代码: $error_code"
    echo ""
    log_warn "故障排除建议："
    log_warn "1. 检查网络连接"
    log_warn "2. 查看相关日志文件"
    log_warn "3. 确认配置参数"
    log_warn "4. 检查PVE主机资源"
    echo ""
    log_info "清理命令: cd $INSTALL_DIR && ./04-cleanup.sh"
    log_info "重新部署: ./one-click-deploy.sh"
    log_info "快速修复: cd $INSTALL_DIR && ./quick-fix.sh --all"
    
    exit $error_code
}

# 信号处理
trap 'log_error "部署被中断"; exit 1' INT TERM

# 显示帮助信息
show_help() {
    echo "PVE KubeSphere 一键部署脚本 (完整版)"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help     显示此帮助信息"
    echo "  -r, --repo     指定GitHub仓库 (默认: $GITHUB_REPO)"
    echo "  -b, --branch   指定分支 (默认: $BRANCH)"
    echo "  -y, --yes      自动确认部署（跳过确认步骤）"
    echo ""
    echo "示例:"
    echo "  $0                                    # 使用默认配置"
    echo "  $0 -r username/repo -b develop        # 指定仓库和分支"
    echo "  $0 -y                                 # 自动确认部署"
    echo ""
}

# 主函数
main() {
    local start_time=$(date +%s)
    local auto_confirm=false
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -r|--repo)
                GITHUB_REPO="$2"
                shift 2
                ;;
            -b|--branch)
                BRANCH="$2"
                shift 2
                ;;
            -y|--yes)
                auto_confirm=true
                shift
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    log_info "开始PVE KubeSphere一键部署..."
    log_info "开始时间: $(date)"
    log_info "GitHub仓库: $GITHUB_REPO"
    log_info "分支: $BRANCH"
    echo ""
    
    # 检查系统要求
    check_system_requirements || handle_error $? "系统要求检查"
    
    # 备份现有安装
    backup_existing
    
    # 从GitHub下载
    download_from_github || handle_error $? "文件下载"
    
    # 验证关键文件
    verify_critical_files || handle_error $? "文件验证"
    
    # 显示部署信息
    show_deployment_info
    
    # 确认部署（除非自动确认）
    if [ "$auto_confirm" != true ]; then
        confirm_deployment
    else
        log_info "自动确认模式，跳过确认步骤"
    fi
    
    # 执行部署
    execute_deployment || handle_error $? "部署执行"
    
    # 计算部署时间
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    log_info "部署总耗时: ${minutes}分${seconds}秒"
    
    # 显示部署结果
    show_deployment_result
    
    # 清理临时文件
    cleanup_temp
    
    log_success "一键部署完成！"
}

# 执行主函数
main "$@" 