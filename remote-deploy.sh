#!/bin/bash

# PVE KubeSphere 远程一键部署脚本
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

# 配置变量
GITHUB_REPO="WinsPan/pve-kubesphere"  # 请修改为您的GitHub仓库
BRANCH="main"
INSTALL_DIR="pve-kubesphere"
BACKUP_DIR="pve-kubesphere-backup-$(date +%Y%m%d-%H%M%S)"

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
    
    log_info "系统要求检查通过"
}

# 备份现有安装
backup_existing() {
    if [ -d "$INSTALL_DIR" ]; then
        log_step "备份现有安装..."
        mv "$INSTALL_DIR" "$BACKUP_DIR"
        log_info "现有安装已备份到: $BACKUP_DIR"
    fi
}

# 从GitHub下载
download_from_github() {
    log_step "从GitHub下载部署脚本..."
    
    # 创建安装目录
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # 下载脚本文件
    local files=(
        "01-pve-prepare.sh"
        "02-k8s-install.sh"
        "03-kubesphere-install.sh"
        "04-cleanup.sh"
        "deploy-all.sh"
        "README-KubeSphere.md"
        "QUICK-START.md"
        "CONFIG-SUMMARY.md"
        "CHECK-REPORT.md"
        "RESOURCE-REQUIREMENTS.md"
        ".gitignore"
    )
    
    for file in "${files[@]}"; do
        log_info "下载: $file"
        if ! curl -fsSL "https://raw.githubusercontent.com/$GITHUB_REPO/$BRANCH/$file" -o "$file"; then
            log_error "下载失败: $file"
            exit 1
        fi
    done
    
    # 添加执行权限
    chmod +x *.sh
    
    log_info "所有文件下载完成"
}

# 配置检查
check_configuration() {
    log_step "检查配置..."
    
    if [ ! -f "01-pve-prepare.sh" ]; then
        log_error "配置文件不存在"
        exit 1
    fi
    
    # 显示当前配置
    echo "=========================================="
    echo "当前配置信息："
    echo "=========================================="
    grep -E "PVE_HOST|MASTER_IP|WORKER_IPS|KUBESPHERE_VERSION" 01-pve-prepare.sh 02-k8s-install.sh 03-kubesphere-install.sh deploy-all.sh | head -10
    echo "=========================================="
    
    log_warn "请确认以上配置信息是否正确"
    log_warn "如需修改，请编辑相应的脚本文件"
    echo ""
}

# 确认部署
confirm_deployment() {
    log_warn "此部署过程将："
    log_warn "1. 在PVE上创建3个Debian虚拟机 (8核16GB 300GB)"
    log_warn "2. 安装Kubernetes v1.28.0集群"
    log_warn "3. 安装KubeSphere v4.1.3"
    log_warn "4. 配置存储和网络"
    log_warn ""
    log_warn "预计总时间：30-60分钟"
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
    
    # 检查脚本文件
    local scripts=(
        "01-pve-prepare.sh"
        "02-k8s-install.sh"
        "03-kubesphere-install.sh"
    )
    
    for script in "${scripts[@]}"; do
        if [ ! -f "$script" ]; then
            log_error "脚本文件不存在: $script"
            exit 1
        fi
        
        if [ ! -x "$script" ]; then
            log_info "为脚本 $script 添加执行权限"
            chmod +x "$script"
        fi
    done
    
    # 执行一键部署
    if ./deploy-all.sh; then
        log_info "部署完成！"
    else
        log_error "部署失败，请检查日志"
        exit 1
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
    echo "📚 文档："
    echo "   详细说明: README-KubeSphere.md"
    echo "   快速开始: QUICK-START.md"
    echo "   配置总结: CONFIG-SUMMARY.md"
    echo ""
    echo "⚠️  注意事项："
    echo "   1. 首次访问可能需要等待几分钟"
    echo "   2. 建议更改默认密码"
    echo "   3. 定期备份重要数据"
    echo "=========================================="
}

# 清理临时文件
cleanup_temp() {
    log_step "清理临时文件..."
    
    # 删除下载的临时文件（可选）
    read -p "是否删除下载的脚本文件？(输入 'yes' 确认): " cleanup_confirm
    
    if [ "$cleanup_confirm" = "yes" ]; then
        cd ..
        rm -rf "$INSTALL_DIR"
        log_info "临时文件已清理"
    else
        log_info "保留脚本文件在: $INSTALL_DIR"
    fi
}

# 错误处理
handle_error() {
    local error_code=$1
    log_error "部署失败，错误代码: $error_code"
    echo ""
    log_warn "故障排除建议："
    log_warn "1. 检查网络连接"
    log_warn "2. 查看相关日志文件"
    log_warn "3. 确认配置参数"
    log_warn "4. 检查PVE主机资源"
    echo ""
    log_info "清理命令: cd $INSTALL_DIR && ./04-cleanup.sh"
    log_info "重新部署: ./remote-deploy.sh"
    
    exit $error_code
}

# 信号处理
trap 'log_error "部署被中断"; exit 1' INT TERM

# 主函数
main() {
    local start_time=$(date +%s)
    
    log_info "开始PVE KubeSphere远程一键部署..."
    log_info "开始时间: $(date)"
    log_info "GitHub仓库: $GITHUB_REPO"
    log_info "分支: $BRANCH"
    echo ""
    
    # 检查系统要求
    check_system_requirements
    
    # 备份现有安装
    backup_existing
    
    # 从GitHub下载
    download_from_github
    
    # 配置检查
    check_configuration
    
    # 确认部署
    confirm_deployment
    
    # 执行部署
    execute_deployment
    
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
    
    log_info "远程部署完成！"
}

# 显示帮助信息
show_help() {
    echo "PVE KubeSphere 远程一键部署脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help     显示此帮助信息"
    echo "  -r, --repo     指定GitHub仓库 (默认: your-username/pve-kubesphere)"
    echo "  -b, --branch   指定分支 (默认: main)"
    echo ""
    echo "示例:"
    echo "  $0                                    # 使用默认配置"
    echo "  $0 -r username/repo -b develop        # 指定仓库和分支"
    echo ""
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -r|--repo)
            GITHUB_REPO="WinsPan/pve-kubesphere"
            shift 2
            ;;
        -b|--branch)
            BRANCH="$2"
            shift 2
            ;;
        *)
            log_error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

# 执行主函数
main "$@" 