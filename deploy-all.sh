#!/bin/bash

# PVE KubeSphere 一键部署脚本
# 在PVE宿主机上直接执行，无需SSH连接

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
PVE_HOST="10.0.0.1"
MASTER_IP="10.0.0.10"
WORKER_IPS=("10.0.0.11" "10.0.0.12")
KUBESPHERE_VERSION="v4.1.3"

# 检查脚本文件
check_scripts() {
    log_step "检查脚本文件..."
    
    local required_scripts=(
        "01-pve-prepare.sh"
        "02-k8s-install.sh"
        "03-kubesphere-install.sh"
    )
    
    for script in "${required_scripts[@]}"; do
        if [ ! -f "$script" ]; then
            log_error "缺少必要脚本: $script"
            exit 1
        fi
        
        if [ ! -x "$script" ]; then
            log_info "为脚本 $script 添加执行权限"
            chmod +x "$script"
        fi
    done
    
    log_info "所有脚本文件检查完成"
}

# 检查PVE环境
check_pve_environment() {
    log_step "检查PVE环境..."
    
    # 检查是否在PVE环境中
    if ! command -v pveversion &> /dev/null; then
        log_error "此脚本需要在PVE环境中运行"
        exit 1
    fi
    
    # 检查PVE版本
    PVE_VERSION=$(pveversion -v | head -1)
    log_info "PVE版本: $PVE_VERSION"
    
    # 检查存储
    if ! pvesm status | grep -q "local-lvm"; then
        log_error "存储 local-lvm 不存在"
        exit 1
    fi
    
    # 检查网络桥接
    if ! ip link show | grep -q "vmbr0"; then
        log_error "网络桥接 vmbr0 不存在"
        exit 1
    fi
    
    log_info "PVE环境检查通过"
}

# 显示部署信息
show_deployment_info() {
    log_step "部署信息"
    echo "=========================================="
    echo "PVE主机: $PVE_HOST"
    echo "Master节点: $MASTER_IP"
    echo "Worker节点: ${WORKER_IPS[*]}"
    echo "KubeSphere版本: $KUBESPHERE_VERSION"
    echo "=========================================="
    echo ""
    
    log_warn "请确认以上配置信息是否正确"
    log_warn "如需修改，请编辑相应的脚本文件"
    echo ""
}

# 确认部署
confirm_deployment() {
    log_warn "此部署过程将："
    log_warn "1. 在PVE上创建3个Debian虚拟机 (8核16GB 300GB)"
    log_warn "2. 安装Kubernetes v1.29.7集群"
    log_warn "3. 安装KubeSphere $KUBESPHERE_VERSION"
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

# 执行第一步：PVE环境准备
execute_step1() {
    log_step "第一步：PVE环境准备"
    log_info "此步骤将创建3个Debian虚拟机..."
    
    if ./01-pve-prepare.sh; then
        log_info "第一步完成：PVE环境准备成功"
        return 0
    else
        log_error "第一步失败：PVE环境准备失败"
        return 1
    fi
}

# 执行第二步：Kubernetes安装
execute_step2() {
    log_step "第二步：Kubernetes安装"
    log_info "此步骤将安装Kubernetes集群..."
    
    if ./02-k8s-install.sh; then
        log_info "第二步完成：Kubernetes安装成功"
        return 0
    else
        log_error "第二步失败：Kubernetes安装失败"
        return 1
    fi
}

# 执行第三步：KubeSphere安装
execute_step3() {
    log_step "第三步：KubeSphere安装"
    log_info "此步骤将安装KubeSphere..."
    
    if ./03-kubesphere-install.sh; then
        log_info "第三步完成：KubeSphere安装成功"
        return 0
    else
        log_error "第三步失败：KubeSphere安装失败"
        return 1
    fi
}

# 验证部署结果
verify_deployment() {
    log_step "验证部署结果..."
    
    # 检查节点连接
    log_info "检查节点连接..."
    for node_ip in "$MASTER_IP" "${WORKER_IPS[@]}"; do
        if ping -c 1 $node_ip > /dev/null 2>&1; then
            log_info "节点 $node_ip 连接正常"
        else
            log_error "节点 $node_ip 连接失败"
            return 1
        fi
    done
    
    # 检查Kubernetes集群
    log_info "检查Kubernetes集群..."
    if ssh -o ConnectTimeout=10 root@$MASTER_IP "kubectl get nodes" > /dev/null 2>&1; then
        log_info "Kubernetes集群运行正常"
    else
        log_error "Kubernetes集群检查失败"
        return 1
    fi
    
    # 检查KubeSphere
    log_info "检查KubeSphere..."
    if ssh -o ConnectTimeout=10 root@$MASTER_IP "kubectl get pods -n kubesphere-system" > /dev/null 2>&1; then
        log_info "KubeSphere安装正常"
    else
        log_error "KubeSphere检查失败"
        return 1
    fi
    
    return 0
}

# 显示最终结果
show_final_result() {
    log_step "部署完成！"
    echo "=========================================="
    echo "🎉 KubeSphere部署成功！"
    echo "=========================================="
    echo ""
    echo "📋 访问信息："
    echo "   KubeSphere控制台: http://$MASTER_IP:30880"
    echo "   用户名: admin"
    echo "   密码: P@88w0rd"
    echo ""
    echo "🔧 管理命令："
    echo "   SSH到主节点: ssh root@$MASTER_IP"
    echo "   查看集群状态: kubectl get nodes"
    echo "   查看pods: kubectl get pods --all-namespaces"
    echo ""
    echo "📚 文档："
    echo "   详细说明: README-KubeSphere.md"
    echo "   故障排除: 查看各脚本的日志输出"
    echo ""
    echo "⚠️  注意事项："
    echo "   1. 首次访问可能需要等待几分钟"
    echo "   2. 建议更改默认密码"
    echo "   3. 定期备份重要数据"
    echo "=========================================="
}

# 错误处理
handle_error() {
    local step=$1
    local error_code=$2
    
    log_error "部署在第 $step 步失败，错误代码: $error_code"
    echo ""
    log_warn "故障排除建议："
    log_warn "1. 检查网络连接"
    log_warn "2. 查看相关日志文件"
    log_warn "3. 确认配置参数"
    log_warn "4. 运行清理脚本后重新部署"
    echo ""
    log_info "清理命令: ./04-cleanup.sh"
    log_info "重新部署: ./deploy-all.sh"
    
    exit $error_code
}

# 创建部署日志
create_deployment_log() {
    local log_file="deployment-$(date +%Y%m%d-%H%M%S).log"
    
    # 重定向所有输出到日志文件
    exec > >(tee -a "$log_file")
    exec 2>&1
    
    log_info "部署日志将保存到: $log_file"
}

# 主函数
main() {
    local start_time=$(date +%s)
    
    log_info "开始PVE KubeSphere一键部署..."
    log_info "开始时间: $(date)"
    
    # 创建部署日志
    create_deployment_log
    
    # 检查脚本文件
    check_scripts
    
    # 检查PVE环境
    check_pve_environment
    
    # 显示部署信息
    show_deployment_info
    
    # 确认部署
    confirm_deployment
    
    # 执行部署步骤
    log_info "开始执行部署步骤..."
    
    # 第一步：PVE环境准备
    if ! execute_step1; then
        handle_error 1 $?
    fi
    
    # 第二步：Kubernetes安装
    if ! execute_step2; then
        handle_error 2 $?
    fi
    
    # 第三步：KubeSphere安装
    if ! execute_step3; then
        handle_error 3 $?
    fi
    
    # 验证部署结果
    if ! verify_deployment; then
        log_error "部署验证失败"
        handle_error 4 $?
    fi
    
    # 计算部署时间
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    log_info "部署总耗时: ${minutes}分${seconds}秒"
    
    # 显示最终结果
    show_final_result
    
    log_info "部署完成！"
}

# 执行主函数
main "$@" 