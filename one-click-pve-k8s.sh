#!/bin/bash

# ==========================================
# PVE K8S+KubeSphere 智能部署工具 v5.0
# ==========================================
#
# 描述: 这是一个功能强大的PVE虚拟化环境下的Kubernetes集群自动化部署工具
#       支持一键部署、智能修复、性能监控、自动化运维等高级功能
#
# 作者: WinsPan
# 版本: 5.0 (重构版)
# 日期: 2025-01-03
#
# 主要功能:
#   🚀 一键全自动部署 K8S + KubeSphere
#   🔧 智能故障诊断和修复
#   📊 实时性能监控和健康检查
#   💾 自动备份和恢复
#   🤖 定时任务和自动化运维
#   🔍 详细的日志记录和审计
#   ⚙️ 高度可配置和可扩展
#
# 系统要求:
#   - Proxmox VE 7.0+
#   - Debian 12 (Bookworm)
#   - 最少 16GB 内存，100GB 存储
#   - 网络连接正常
#
# 使用方法:
#   ./one-click-pve-k8s.sh          # 交互模式
#   ./one-click-pve-k8s.sh 1        # 直接执行一键部署
#   ./one-click-pve-k8s.sh --help   # 显示帮助
#
# 环境变量:
#   DEBUG=true                      # 启用调试模式
#   LOG_LEVEL=DEBUG                 # 设置日志级别
#   K8S_VERSION=v1.29.0            # 指定K8S版本
#   DOCKER_VERSION=24.0.8          # 指定Docker版本
#
# 许可证: MIT License
# 仓库: https://github.com/winspan/pve-k8s-deploy
#
# ==========================================

set -u

# ==========================================
# 全局配置中心
# ==========================================

# 脚本信息
readonly SCRIPT_VERSION="5.0"
readonly SCRIPT_NAME="PVE K8S+KubeSphere 部署工具"
readonly SCRIPT_AUTHOR="WinsPan"
readonly SCRIPT_DESCRIPTION="模块化设计，高可靠性，智能化部署"

# 颜色定义
readonly GREEN='\e[0;32m'
readonly YELLOW='\e[1;33m'
readonly RED='\e[0;31m'
readonly BLUE='\e[0;34m'
readonly CYAN='\e[0;36m'
readonly PURPLE='\e[0;35m'
readonly BOLD='\e[1m'
readonly NC='\e[0m'

# 环境配置
readonly DEFAULT_SSH_USER="${SSH_USER:-root}"
readonly DEFAULT_SSH_PORT="${SSH_PORT:-22}"
readonly DEFAULT_SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
readonly DEFAULT_TIMEOUT="${TIMEOUT:-600}"
readonly LOG_LEVEL="${LOG_LEVEL:-INFO}"
readonly DEBUG_MODE="${DEBUG:-false}"

# 网络配置
readonly NETWORK_BRIDGE="${BRIDGE:-vmbr0}"
readonly NETWORK_GATEWAY="${GATEWAY:-10.0.0.1}"
readonly NETWORK_DNS="${DNS:-119.29.29.29,8.8.8.8,10.0.0.1}"
readonly NETWORK_DOMAIN="${DOMAIN:-local}"

# 软件版本配置（支持环境变量覆盖）
readonly DOCKER_VERSION="${DOCKER_VERSION:-24.0.7}"
readonly CONTAINERD_VERSION="${CONTAINERD_VERSION:-1.7.8}"
readonly RUNC_VERSION="${RUNC_VERSION:-1.1.9}"
readonly K8S_VERSION="${K8S_VERSION:-v1.28.2}"
readonly KUBESPHERE_VERSION="${KUBESPHERE_VERSION:-v3.4.1}"

# 镜像源配置
readonly GITHUB_MIRRORS=(
    "https://github.com"
    "https://ghproxy.com/https://github.com"
    "https://mirror.ghproxy.com/https://github.com"
    "https://gh.api.99988866.xyz/https://github.com"
    "https://gitclone.com/github.com"
)

readonly K8S_MIRRORS=(
    "https://dl.k8s.io"
    "https://storage.googleapis.com/kubernetes-release"
    "https://mirror.ghproxy.com/https://storage.googleapis.com/kubernetes-release"
)

readonly DEBIAN_MIRRORS=(
    "https://mirrors.ustc.edu.cn/debian"
    "https://mirrors.tuna.tsinghua.edu.cn/debian"
    "https://mirrors.aliyun.com/debian"
    "https://deb.debian.org/debian"
)

readonly DOCKER_REGISTRY_MIRRORS=(
    "https://docker.mirrors.ustc.edu.cn"
    "https://hub-mirror.c.163.com"
    "https://mirror.baidubce.com"
)

# 云镜像配置
readonly CLOUD_IMAGE_URLS=(
    "https://mirrors.ustc.edu.cn/debian-cloud-images/bookworm/latest/debian-12-generic-amd64.qcow2"
    "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
)
readonly CLOUD_IMAGE_FILE="debian-12-generic-amd64.qcow2"
readonly CLOUD_IMAGE_PATH="/var/lib/vz/template/qcow/$CLOUD_IMAGE_FILE"

# 虚拟机配置模板
if [[ "${BASH_VERSION%%.*}" -ge 4 ]]; then
    declare -A VM_CONFIGS=(
        # Master节点
        ["100"]="k8s-master|10.0.0.10|8|16384|300"
        # Worker节点
        ["101"]="k8s-worker1|10.0.0.11|8|16384|300"
        ["102"]="k8s-worker2|10.0.0.12|8|16384|300"
    )
else
    # 兼容旧版本bash的虚拟机配置
    VM_CONFIG_100="k8s-master|10.0.0.10|8|16384|300"
    VM_CONFIG_101="k8s-worker1|10.0.0.11|8|16384|300"
    VM_CONFIG_102="k8s-worker2|10.0.0.12|8|16384|300"
fi

# 路径配置（自适应权限）
if [[ $EUID -eq 0 ]]; then
    # root用户使用系统目录
    readonly WORK_DIR="/tmp/pve-k8s-deploy"
    readonly LOG_DIR="/var/log/pve-k8s-deploy"
    readonly BACKUP_DIR="/var/backups/pve-k8s"
    readonly CONFIG_DIR="/etc/pve-k8s"
else
    # 普通用户使用用户目录
    readonly WORK_DIR="$HOME/.pve-k8s-deploy"
    readonly LOG_DIR="$HOME/.pve-k8s-deploy/logs"
    readonly BACKUP_DIR="$HOME/.pve-k8s-deploy/backups"
    readonly CONFIG_DIR="$HOME/.pve-k8s-deploy/config"
fi

# 文件配置
readonly LOG_FILE="$LOG_DIR/deploy-$(date '+%Y%m%d-%H%M%S').log"
readonly ERROR_LOG="$LOG_DIR/error.log"
readonly PERFORMANCE_LOG="$LOG_DIR/performance.log"
readonly AUDIT_LOG="$LOG_DIR/audit.log"

# 性能配置
readonly MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-4}"
readonly DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-300}"
readonly SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-30}"
readonly VM_BOOT_TIMEOUT="${VM_BOOT_TIMEOUT:-900}"

# 安全配置
readonly ENABLE_FIREWALL="${ENABLE_FIREWALL:-false}"
readonly ENABLE_SELINUX="${ENABLE_SELINUX:-false}"
readonly SECURE_MODE="${SECURE_MODE:-false}"

# 功能开关
readonly ENABLE_MONITORING="${ENABLE_MONITORING:-true}"
readonly ENABLE_BACKUP="${ENABLE_BACKUP:-true}"
readonly ENABLE_AUTO_CLEANUP="${ENABLE_AUTO_CLEANUP:-true}"
readonly ENABLE_HEALTH_CHECK="${ENABLE_HEALTH_CHECK:-true}"

# ==========================================
# 网络下载和文件管理
# ==========================================

##
# 增强的下载函数 - 支持进度显示、重试机制、文件验证
#
# 功能描述:
#   - 支持curl和wget双重下载
#   - 显示下载进度和速度
#   - 自动重试机制（指数退避）
#   - 文件完整性验证
#   - 性能监控和日志记录
#
# 参数:
#   $1 - 下载URL
#   $2 - 输出文件路径
#   $3 - 描述信息
#   $4 - 最大重试次数（可选，默认3）
#
# 返回值: 0=成功, 1=失败
# 依赖: curl或wget, log_*, measure_performance
##
download_with_progress() {
    local url="$1"
    local output="$2"
    local description="$3"
    local max_retries="${4:-3}"
    local retry_count=0
    
    log_info "开始下载: $description"
    log_debug "URL: $url"
    log_debug "输出文件: $output"
    
    # 检查输出目录
    local output_dir=$(dirname "$output")
    [[ ! -d "$output_dir" ]] && mkdir -p "$output_dir"
    
    # 记录下载开始时间
    local start_time=$(date +%s)
    
    while [ $retry_count -lt $max_retries ]; do
        if [ $retry_count -gt 0 ]; then
            log_warn "重试下载 ($retry_count/$max_retries): $description"
            sleep $((retry_count * 2))
        fi
        
        # 尝试使用curl下载
        if command -v curl >/dev/null 2>&1; then
            log_debug "使用curl下载: $description"
            if curl --progress-bar \
                   --connect-timeout "$SSH_CONNECT_TIMEOUT" \
                   --max-time "$DOWNLOAD_TIMEOUT" \
                   --retry 2 \
                   --retry-delay 1 \
                   --location \
                   --fail \
                   --silent \
                   --show-error \
                   "$url" -o "$output"; then
                local end_time=$(date +%s)
                local duration=$((end_time - start_time))
                log_success "✅ $description 下载成功 (${duration}s)"
                
                # 验证文件
                if [[ -f "$output" && -s "$output" ]]; then
                    local file_size=$(stat -c%s "$output" 2>/dev/null || echo "0")
                    log_debug "文件大小: $file_size bytes"
                    return 0
                else
                    log_error "下载的文件无效: $output"
                    rm -f "$output"
                fi
            fi
        fi
        
        # 如果curl失败，尝试wget
        if command -v wget >/dev/null 2>&1; then
            log_debug "使用wget下载: $description"
            if wget --progress=bar:force \
                   --timeout="$SSH_CONNECT_TIMEOUT" \
                   --tries=2 \
                   --waitretry=1 \
                   --no-check-certificate \
                   "$url" -O "$output"; then
                local end_time=$(date +%s)
                local duration=$((end_time - start_time))
                log_success "✅ $description 下载成功 (${duration}s)"
                
                # 验证文件
                if [[ -f "$output" && -s "$output" ]]; then
                    local file_size=$(stat -c%s "$output" 2>/dev/null || echo "0")
                    log_debug "文件大小: $file_size bytes"
                    return 0
                else
                    log_error "下载的文件无效: $output"
                    rm -f "$output"
                fi
            fi
        fi
        
        ((retry_count++))
        log_warn "下载失败，准备重试: $description"
        rm -f "$output" 2>/dev/null || true
    done
    
    log_error "❌ $description 下载失败，已重试 $max_retries 次"
    return 1
}

# 智能GitHub文件下载函数
download_github_file() {
    local github_path="$1"  # 例如: /docker/docker/releases/download/v24.0.7/docker-24.0.7.tgz
    local output="$2"
    local description="$3"
    local max_retries="${4:-3}"
    
    log_info "开始GitHub下载: $description"
    log_debug "GitHub路径: $github_path"
    
    # 检查网络连接
    if ! ping -c 1 -W 5 github.com >/dev/null 2>&1; then
        log_warn "无法连接到GitHub，可能需要使用镜像源"
    fi
    
    # 遍历所有GitHub镜像源
    for mirror in "${GITHUB_MIRRORS[@]}"; do
        local full_url="${mirror}${github_path}"
        log_debug "尝试镜像源: $mirror"
        
        if measure_performance "download_github_${mirror##*/}" download_with_progress "$full_url" "$output" "$description" "$max_retries"; then
            log_success "GitHub下载成功: $description (镜像源: $mirror)"
            return 0
        fi
        
        log_warn "镜像源失败，尝试下一个: $mirror"
        rm -f "$output" 2>/dev/null || true
        
        # 短暂延迟避免过于频繁的请求
        sleep 1
    done
    
    log_error "❌ 所有GitHub镜像源都失败了: $description"
    return 1
}

# 通用软件下载函数
download_software() {
    local software_name="$1"
    local version="$2"
    local github_repo="$3"
    local filename="$4"
    local output="$5"
    
    local github_path="/${github_repo}/releases/download/${version}/${filename}"
    download_github_file "$github_path" "$output" "${software_name} ${version}"
}

# ==========================================
# 核心工具函数库
# ==========================================

# ==========================================
# 系统初始化和环境配置
# ==========================================

##
# 初始化系统环境
# 
# 功能描述:
#   - 创建必要的工作目录
#   - 初始化日志系统
#   - 设置错误处理机制
#   - 配置性能监控
#
# 参数: 无
# 返回值: 0=成功, 非0=失败
# 全局变量: WORK_DIR, LOG_DIR, BACKUP_DIR, CONFIG_DIR
# 依赖函数: init_logging, handle_error
##
init_system() {
    # 创建必要的目录
    mkdir -p "$WORK_DIR" "$LOG_DIR" "$BACKUP_DIR" "$CONFIG_DIR"
    
    # 设置权限
    chmod 755 "$WORK_DIR" "$LOG_DIR" "$BACKUP_DIR" "$CONFIG_DIR"
    
    # 初始化日志系统
    init_logging
    
    # 设置错误处理（仅在非测试模式下）
    if [[ "${SCRIPT_TEST_MODE:-false}" != "true" ]]; then
        set -eE
        trap 'handle_error $? $LINENO' ERR
    fi
    
    # 性能优化
    optimize_memory_usage
    manage_disk_space
    
    # 系统预热
    if [[ "$ENABLE_MONITORING" == "true" ]] && [[ "${DEMO_MODE:-false}" != "true" ]]; then
        warm_up_system
    fi
    
    # 记录启动信息
    log_info "系统初始化完成"
    log_info "脚本版本: $SCRIPT_VERSION"
    log_info "工作目录: $WORK_DIR"
    log_info "日志目录: $LOG_DIR"
    log_info "性能优化: 已启用"
    log_info "监控功能: $ENABLE_MONITORING"
    log_info "备份功能: $ENABLE_BACKUP"
}

# 增强的日志系统
init_logging() {
    # 确保日志目录存在
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # 创建日志文件
    touch "$LOG_FILE" "$ERROR_LOG" "$PERFORMANCE_LOG" "$AUDIT_LOG"
    
    # 设置日志轮转
    if command -v logrotate >/dev/null 2>&1; then
        cat > "/etc/logrotate.d/pve-k8s-deploy" << EOF
$LOG_DIR/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
EOF
    fi
}

# 统一日志函数
log_debug() { 
    [[ "$LOG_LEVEL" == "DEBUG" ]] && echo -e "${BLUE}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

log_info() { 
    # 确保日志目录存在
    [[ ! -d "$(dirname "$LOG_FILE")" ]] && mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_warn() { 
    # 确保日志目录存在
    [[ ! -d "$(dirname "$LOG_FILE")" ]] && mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" "$ERROR_LOG" 2>/dev/null || echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_error() { 
    # 确保日志目录存在
    [[ ! -d "$(dirname "$LOG_FILE")" ]] && mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" "$ERROR_LOG" 2>/dev/null || echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_success() { 
    # 确保日志目录存在
    [[ ! -d "$(dirname "$LOG_FILE")" ]] && mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"
}

log_performance() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$PERFORMANCE_LOG"
}

log_audit() {
    # 确保日志目录存在
    [[ ! -d "$(dirname "$AUDIT_LOG")" ]] && mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') USER=$(whoami) ACTION=$*" >> "$AUDIT_LOG" 2>/dev/null || true
}

# 增强的错误处理
handle_error() {
    local exit_code=$1
    local line_number=$2
    local command="${BASH_COMMAND}"
    
    log_error "脚本执行失败"
    log_error "退出码: $exit_code"
    log_error "行号: $line_number"
    log_error "命令: $command"
    log_error "调用栈:"
    
    # 打印调用栈
    local frame=0
    while caller $frame; do
        ((frame++))
    done | while read line func file; do
        log_error "  at $func ($file:$line)"
    done
    
    # 生成错误报告
    generate_error_report "$exit_code" "$line_number" "$command"
    
    # 清理资源
    cleanup_on_error
    
    exit "$exit_code"
}

# 生成错误报告
generate_error_report() {
    local exit_code=$1
    local line_number=$2
    local command=$3
    local report_file="$LOG_DIR/error-report-$(date '+%Y%m%d-%H%M%S').txt"
    
    cat > "$report_file" << EOF
=== PVE K8S 部署错误报告 ===
时间: $(date)
脚本版本: $SCRIPT_VERSION
退出码: $exit_code
错误行号: $line_number
失败命令: $command

系统信息:
- 操作系统: $(uname -a)
- 用户: $(whoami)
- 工作目录: $(pwd)
- 环境变量: $(env | grep -E '^(PATH|HOME|USER)=')

最近的日志:
$(tail -20 "$LOG_FILE" 2>/dev/null || echo "无法读取日志文件")

错误日志:
$(tail -10 "$ERROR_LOG" 2>/dev/null || echo "无错误日志")
EOF
    
    log_error "错误报告已生成: $report_file"
}

# 错误清理函数
cleanup_on_error() {
    log_info "开始错误清理..."
    
    # 清理临时文件
    [[ -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"/*.tmp 2>/dev/null || true
    
    # 停止可能的后台进程
    jobs -p | xargs -r kill 2>/dev/null || true
    
    log_info "错误清理完成"
}

# 性能监控函数
measure_performance() {
    local operation="$1"
    local start_time=$(date +%s.%N)
    
    # 执行操作
    shift
    "$@"
    local exit_code=$?
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc -l)
    
    log_performance "OPERATION=$operation DURATION=${duration}s EXIT_CODE=$exit_code"
    
    return $exit_code
}

# 资源监控函数
monitor_resources() {
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    local memory_usage=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100.0}')
    local disk_usage=$(df / | tail -1 | awk '{print $5}' | cut -d'%' -f1)
    
    log_performance "RESOURCES CPU=${cpu_usage}% MEM=${memory_usage}% DISK=${disk_usage}%"
    
    # 资源告警
    if (( $(echo "$cpu_usage > 80" | bc -l) )); then
        log_warn "CPU使用率过高: ${cpu_usage}%"
    fi
    
    if (( $(echo "$memory_usage > 80" | bc -l) )); then
        log_warn "内存使用率过高: ${memory_usage}%"
    fi
    
    if (( disk_usage > 80 )); then
        log_warn "磁盘使用率过高: ${disk_usage}%"
    fi
}

# 智能K8S二进制文件下载函数
download_k8s_binary() {
    local binary_name="$1"  # kubectl, kubeadm, kubelet
    local version="$2"      # v1.28.2
    local install_path="${3:-/usr/local/bin}"
    
    log_info "开始下载K8S组件: $binary_name $version"
    
    # 检查是否已经安装
    if [[ -f "$install_path/$binary_name" ]]; then
        local current_version
        current_version=$($install_path/$binary_name version --client --short 2>/dev/null | grep -o 'v[0-9.]*' || echo "unknown")
        if [[ "$current_version" == "$version" ]]; then
            log_info "$binary_name $version 已安装，跳过下载"
            return 0
        else
            log_info "发现不同版本的 $binary_name ($current_version)，将更新到 $version"
        fi
    fi
    
    # 创建临时文件
    local temp_file="/tmp/${binary_name}-${version}"
    
    # 遍历所有K8S镜像源
    for mirror in "${K8S_MIRRORS[@]}"; do
        local full_url="${mirror}/release/${version}/bin/linux/amd64/${binary_name}"
        log_debug "尝试K8S镜像源: $mirror"
        
        if measure_performance "download_k8s_${binary_name}" download_with_progress "$full_url" "$temp_file" "${binary_name} ${version}"; then
            # 验证下载的文件
            if [[ -f "$temp_file" && -s "$temp_file" ]]; then
                # 设置执行权限
                chmod +x "$temp_file"
                
                # 验证二进制文件
                if "$temp_file" version --client >/dev/null 2>&1; then
                    # 移动到安装目录
                    mv "$temp_file" "$install_path/$binary_name"
                    log_success "✅ $binary_name $version 安装成功"
                    
                    # 验证安装
                    if "$install_path/$binary_name" version --client >/dev/null 2>&1; then
                        log_debug "$binary_name 安装验证成功"
                        return 0
                    else
                        log_error "$binary_name 安装验证失败"
                        rm -f "$install_path/$binary_name"
                    fi
                else
                    log_error "下载的 $binary_name 文件无效"
                    rm -f "$temp_file"
                fi
            else
                log_error "下载的 $binary_name 文件为空"
            fi
        fi
        
        log_warn "K8S镜像源失败，尝试下一个: $mirror"
        rm -f "$temp_file" 2>/dev/null || true
        sleep 1
    done
    
    log_error "❌ 所有K8S镜像源都失败了: $binary_name $version"
    return 1
}

# 统一安装Docker和containerd
install_docker_containerd() {
    echo -e "${CYAN}开始安装Docker和containerd...${NC}"
    
    # 创建临时目录
    local temp_dir="/tmp/docker-install"
    mkdir -p "$temp_dir"
    cd "$temp_dir"
    
    # 下载并安装Docker
    if download_software "Docker" "v$DOCKER_VERSION" "docker/docker" "docker-$DOCKER_VERSION.tgz" "docker.tgz"; then
        echo -e "${GREEN}Docker二进制文件下载成功${NC}"
        
        # 解压并安装
        tar -xzf docker.tgz
        cp docker/* /usr/local/bin/
        chmod +x /usr/local/bin/docker*
        
        # 创建docker用户组
        groupadd docker 2>/dev/null || true
        
        echo -e "${GREEN}Docker安装完成${NC}"
    else
        echo -e "${RED}Docker下载失败${NC}"
        return 1
    fi

    # 下载并安装containerd
    if download_software "containerd" "v$CONTAINERD_VERSION" "containerd/containerd" "containerd-$CONTAINERD_VERSION-linux-amd64.tar.gz" "containerd.tar.gz"; then
        echo -e "${GREEN}containerd下载成功${NC}"
        tar -xzf containerd.tar.gz -C /usr/local/
        echo -e "${GREEN}containerd安装完成${NC}"
    else
        echo -e "${RED}containerd下载失败${NC}"
        return 1
    fi
    
    # 下载并安装runc
    if download_software "runc" "v$RUNC_VERSION" "opencontainers/runc" "runc.amd64" "runc"; then
        echo -e "${GREEN}runc下载成功${NC}"
        chmod +x runc
        mv runc /usr/local/bin/
        echo -e "${GREEN}runc安装完成${NC}"
    else
        echo -e "${YELLOW}runc下载失败，使用系统包${NC}"
        apt-get install -y runc || true
    fi
    
    # 清理临时文件
    cd /
    rm -rf "$temp_dir"
    
    # 创建服务文件
    create_docker_services
    create_containerd_config
    
    # 启动服务
    systemctl daemon-reload
    systemctl enable docker containerd
    systemctl restart docker containerd
    
    # 验证安装
    if docker --version && containerd --version; then
        echo -e "${GREEN}✅ Docker和containerd安装成功${NC}"
        return 0
    else
        echo -e "${RED}❌ Docker或containerd启动失败${NC}"
        return 1
    fi
}

# 创建Docker服务文件
create_docker_services() {
    cat > /etc/systemd/system/docker.service << 'EOF'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target docker.socket firewalld.service containerd.service time-set.target
Wants=network-online.target containerd.service
Requires=docker.socket containerd.service

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutStartSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/docker.socket << 'EOF'
[Unit]
Description=Docker Socket for the API

[Socket]
ListenStream=/var/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF

    cat > /etc/systemd/system/containerd.service << 'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
}

# 创建containerd配置
create_containerd_config() {
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml
    sed -i "s|registry.k8s.io/pause:3.6|registry.aliyuncs.com/google_containers/pause:3.6|g" /etc/containerd/config.toml
    
    # 配置Docker镜像加速
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'EOF'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m"},
  "storage-driver": "overlay2",
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com",
    "https://mirror.baidubce.com"
  ]
}
EOF
}

# 统一安装K8S组件
install_k8s_components() {
    echo -e "${CYAN}开始安装K8S组件...${NC}"
    
    # 创建临时目录
    local temp_dir="/tmp/k8s-install"
    mkdir -p "$temp_dir"
    cd "$temp_dir"
    
    # 下载kubectl
    if download_k8s_binary "kubectl" "$K8S_VERSION"; then
        echo -e "${GREEN}kubectl安装成功${NC}"
    else
        echo -e "${RED}kubectl下载失败${NC}"
        return 1
    fi
    
    # 下载kubeadm
    if download_k8s_binary "kubeadm" "$K8S_VERSION"; then
        echo -e "${GREEN}kubeadm安装成功${NC}"
    else
        echo -e "${RED}kubeadm下载失败${NC}"
        return 1
    fi
    
    # 下载kubelet
    if download_k8s_binary "kubelet" "$K8S_VERSION"; then
        echo -e "${GREEN}kubelet安装成功${NC}"
    else
        echo -e "${RED}kubelet下载失败${NC}"
        return 1
    fi
    
    # 清理临时文件
    cd /
    rm -rf "$temp_dir"
    
    # 创建kubelet服务文件
    create_kubelet_service
    
    # 启动服务
    systemctl daemon-reload
    systemctl enable kubelet
    
    echo -e "${GREEN}✅ K8S组件安装成功${NC}"
    return 0
}

# 创建kubelet服务文件
create_kubelet_service() {
    cat > /etc/systemd/system/kubelet.service << 'EOF'
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/home/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # 创建kubelet配置目录
    mkdir -p /etc/systemd/system/kubelet.service.d
    cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf << 'EOF'
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
EOF
}

# ==========================================
# 性能优化和缓存机制
# ==========================================

##
# 并行执行函数 - 高效的任务并发处理
#
# 功能描述:
#   - 控制最大并发数
#   - 实时监控任务状态
#   - 收集所有任务结果
#   - 智能任务调度
#   - 错误统计和报告
#
# 参数:
#   $1 - 最大并发数（可选，默认使用MAX_PARALLEL_JOBS）
#   $2+ - 要执行的命令列表
#
# 返回值: 0=所有任务成功, 1=有任务失败
# 使用示例:
#   parallel_execute 4 "task1" "task2" "task3" "task4"
##
parallel_execute() {
    local max_jobs="${1:-$MAX_PARALLEL_JOBS}"
    shift
    local commands=("$@")
    local pids=()
    local results=()
    
    log_info "开始并行执行 ${#commands[@]} 个任务，最大并发数: $max_jobs"
    
    for i in "${!commands[@]}"; do
        # 控制并发数
        while (( ${#pids[@]} >= max_jobs )); do
            # 等待任意一个任务完成
            for j in "${!pids[@]}"; do
                if ! kill -0 "${pids[$j]}" 2>/dev/null; then
                    wait "${pids[$j]}"
                    results[$j]=$?
                    unset pids[$j]
                    break
                fi
            done
            sleep 0.1
        done
        
        # 启动新任务
        log_debug "启动并行任务 $((i+1)): ${commands[$i]}"
        eval "${commands[$i]}" &
        pids[$i]=$!
    done
    
    # 等待所有任务完成
    for i in "${!pids[@]}"; do
        wait "${pids[$i]}"
        results[$i]=$?
    done
    
    # 检查结果
    local failed_count=0
    for i in "${!results[@]}"; do
        if (( results[$i] != 0 )); then
            log_error "并行任务 $((i+1)) 失败: ${commands[$i]} (退出码: ${results[$i]})"
            ((failed_count++))
        fi
    done
    
    if (( failed_count > 0 )); then
        log_error "并行执行完成，$failed_count 个任务失败"
        return 1
    else
        log_success "并行执行完成，所有任务成功"
        return 0
    fi
}

# 缓存管理
cache_get() {
    local key="$1"
    local cache_file="$WORK_DIR/cache/$key"
    
    if [[ -f "$cache_file" ]]; then
        local cache_time=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
        local current_time=$(date +%s)
        local cache_ttl="${2:-3600}"  # 默认1小时过期
        
        if (( current_time - cache_time < cache_ttl )); then
            cat "$cache_file"
            return 0
        else
            rm -f "$cache_file"
        fi
    fi
    
    return 1
}

cache_set() {
    local key="$1"
    local value="$2"
    local cache_dir="$WORK_DIR/cache"
    local cache_file="$cache_dir/$key"
    
    mkdir -p "$cache_dir"
    echo "$value" > "$cache_file"
}

cache_clear() {
    local pattern="${1:-*}"
    local cache_dir="$WORK_DIR/cache"
    
    if [[ -d "$cache_dir" ]]; then
        rm -f "$cache_dir"/$pattern
        log_info "缓存已清理: $pattern"
    fi
}

# 智能重试机制
smart_retry() {
    local max_attempts="$1"
    local delay="$2"
    local operation="$3"
    shift 3
    
    local attempt=1
    local base_delay="$delay"
    
    while (( attempt <= max_attempts )); do
        log_debug "尝试执行操作 ($attempt/$max_attempts): $operation"
        
        if "$@"; then
            log_debug "操作成功: $operation"
            return 0
        fi
        
        if (( attempt == max_attempts )); then
            log_error "操作最终失败: $operation"
            return 1
        fi
        
        # 指数退避
        local wait_time=$((base_delay * (2 ** (attempt - 1))))
        log_warn "操作失败，等待 ${wait_time}s 后重试: $operation"
        sleep "$wait_time"
        
        ((attempt++))
    done
}

# 预热系统
warm_up_system() {
    log_info "开始系统预热..."
    
    # 预热DNS解析
    local dns_targets=("github.com" "dl.k8s.io" "docker.io")
    for target in "${dns_targets[@]}"; do
        nslookup "$target" >/dev/null 2>&1 &
    done
    
    # 预热网络连接
    for mirror in "${GITHUB_MIRRORS[@]:0:2}"; do
        curl -I "$mirror" --connect-timeout 5 >/dev/null 2>&1 &
    done
    
    # 预创建工作目录
    mkdir -p "$WORK_DIR"/{downloads,cache,pools,temp}
    
    # 预热系统命令
    which curl wget ssh scp qm >/dev/null 2>&1
    
    wait  # 等待所有预热任务完成
    log_info "系统预热完成"
}

# 内存使用优化
optimize_memory_usage() {
    # 清理不必要的变量
    unset BASH_COMPLETION_DEBUG 2>/dev/null || true
    
    # 设置bash选项优化内存
    set +h  # 禁用hash表
    
    # 限制历史记录大小
    export HISTSIZE=100
    export HISTFILESIZE=100
    
    # 清理环境变量
    unset MAIL MAILCHECK 2>/dev/null || true
}

# 磁盘空间管理
manage_disk_space() {
    local min_free_space_gb="${1:-5}"
    local work_dir_size=$(du -sg "$WORK_DIR" 2>/dev/null | cut -f1 || echo 0)
    local available_space=$(df "$WORK_DIR" | tail -1 | awk '{print int($4/1024/1024)}' 2>/dev/null || echo 100)
    
    if (( available_space < min_free_space_gb )); then
        # 清理缓存
        cache_clear
        
        # 清理临时文件
        find "$WORK_DIR" -name "*.tmp" -mtime +1 -delete 2>/dev/null || true
        
        # 清理旧日志
        find "$LOG_DIR" -name "*.log" -mtime +7 -delete 2>/dev/null || true
    fi
}

# ==========================================
# 系统配置和认证
# ==========================================

# 系统配置
readonly STORAGE="${STORAGE:-local-lvm}"
readonly BRIDGE="${BRIDGE:-vmbr0}"
readonly GATEWAY="${GATEWAY:-10.0.0.1}"
readonly DNS="${DNS:-119.29.29.29,8.8.8.8,10.0.0.1}"

# 认证配置
readonly CLOUDINIT_USER="${CLOUDINIT_USER:-root}"
readonly CLOUDINIT_PASS="${CLOUDINIT_PASS:-kubesphere123}"

# ==========================================
# 日志和工具函数
# ==========================================
init_logging() {
    mkdir -p "$LOG_DIR"
}

log()     { echo -e "${GREEN}[INFO]${NC} $(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE"; }

# 错误处理（仅在严重错误时退出）
handle_error() {
    local line_no=$1
    local exit_code=$?
    
    # 只有在严重错误时才退出（退出码大于1）
    if [[ $exit_code -gt 1 ]]; then
        error "脚本在第 $line_no 行遇到严重错误（退出码: $exit_code）"
        error "详细日志: $LOG_FILE"
        exit $exit_code
    fi
}

# 仅在严重错误时触发trap
trap 'handle_error ${LINENO}' ERR

# 解析虚拟机配置
parse_vm_config() {
    local vm_id="$1"
    local field="$2"
    local config=""
    
    # 兼容bash 3.x和4.x+
    if [[ "${BASH_VERSION%%.*}" -ge 4 ]]; then
        config="${VM_CONFIGS[$vm_id]}"
    else
        # bash 3.x 使用变量名拼接
        local var_name="VM_CONFIG_$vm_id"
        config="${!var_name}"
    fi
    
    IFS='|' read -r name ip cores memory disk <<< "$config"
    
    case "$field" in
        "name") echo "$name" ;;
        "ip") echo "$ip" ;;
        "cores") echo "$cores" ;;
        "memory") echo "$memory" ;;
        "disk") echo "$disk" ;;
        *) error "未知字段: $field"; return 1 ;;
    esac
}

# 获取所有VM ID（兼容bash 3.x和4.x+）
get_all_vm_ids() {
    local vm_ids=()
    
    if [[ "${BASH_VERSION%%.*}" -ge 4 ]]; then
        vm_ids=("${!VM_CONFIGS[@]}")
    else
        # bash 3.x 使用固定的VM ID列表
        local all_vm_ids=(100 101 102)
        for vm_id in "${all_vm_ids[@]}"; do
            local var_name="VM_CONFIG_$vm_id"
            if [[ -n "${!var_name}" ]]; then
                vm_ids+=("$vm_id")
            fi
        done
    fi
    
    echo "${vm_ids[@]}"
}

# 获取所有IP
get_all_ips() {
    local ips=()
    local vm_ids=($(get_all_vm_ids))
    
    for vm_id in "${vm_ids[@]}"; do
        ips+=($(parse_vm_config "$vm_id" "ip"))
    done
    
    echo "${ips[@]}"
}

# 获取master IP
get_master_ip() {
    parse_vm_config "100" "ip"
}

# 根据IP获取VM名称
get_vm_name_by_ip() {
    local target_ip="$1"
    local vm_ids=($(get_all_vm_ids))
    for vm_id in "${vm_ids[@]}"; do
        local ip=$(parse_vm_config "$vm_id" "ip")
        if [[ "$ip" == "$target_ip" ]]; then
            echo $(parse_vm_config "$vm_id" "name")
            return
        fi
    done
    echo "unknown"
}

# 重试执行函数
retry_command() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local command=("$@")
    
    for ((i=1; i<=max_attempts; i++)); do
        if "${command[@]}"; then
            return 0
        else
            if [[ $i -lt $max_attempts ]]; then
                warn "命令执行失败，重试 $i/$max_attempts，等待 ${delay}s..."
                sleep "$delay"
            fi
        fi
    done
    
    error "命令执行最终失败: ${command[*]}"
    return 1
}

# ==========================================
# 环境检查
# ==========================================
check_environment() {
    log "检查运行环境..."
    
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        if [[ "${DEMO_MODE:-false}" == "true" ]]; then
            warn "当前非root用户，但DEMO_MODE已启用，继续运行"
        else
            error "此脚本需要root权限运行"
            exit 1
        fi
    fi
    
    # 检查PVE环境
    if ! command -v qm &>/dev/null; then
        if [[ "${DEMO_MODE:-false}" == "true" ]]; then
            warn "未检测到PVE环境，但DEMO_MODE已启用，继续运行"
        else
            error "未检测到PVE环境"
            error "如需在非PVE环境下测试菜单，请设置 DEMO_MODE=true"
            exit 1
        fi
    fi
    
    # 检查必要命令
    local required_commands=("wget" "ssh" "sshpass" "nc")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            warn "安装缺失命令: $cmd"
            apt-get update -qq && apt-get install -y "$cmd"
        fi
    done
    
    # 清理SSH环境
    log "清理SSH环境..."
    local all_ips=($(get_all_ips))
    for ip in "${all_ips[@]}"; do
        ssh-keygen -f "/root/.ssh/known_hosts" -R "$ip" 2>/dev/null || true
    done
    
    success "环境检查完成"
}

# ==========================================
# SSH连接管理
# ==========================================
execute_remote_command() {
    local ip="$1"
    local command="$2"
    local max_retries="${3:-3}"
    
    for ((i=1; i<=max_retries; i++)); do
        if sshpass -p "$CLOUDINIT_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=10 \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "$CLOUDINIT_USER@$ip" "bash -c '$command'" 2>/dev/null; then
            return 0
        else
            if [[ $i -lt $max_retries ]]; then
                warn "节点 $ip 命令执行失败，重试 $i/$max_retries..."
                # 清理可能的旧SSH密钥
                ssh-keygen -f "/root/.ssh/known_hosts" -R "$ip" 2>/dev/null || true
                sleep 5
            fi
        fi
    done
    
    error "节点 $ip 命令执行失败"
    return 1
}

test_ssh_connection() {
    local ip="$1"
    execute_remote_command "$ip" "echo 'SSH测试成功'" 1
}

wait_for_ssh() {
    local ip="$1"
    local max_wait="${2:-$SSH_TIMEOUT}"
    
    log "等待 $ip SSH服务..."
    
    for ((i=0; i<max_wait; i+=10)); do
        if nc -z "$ip" 22 &>/dev/null && test_ssh_connection "$ip"; then
            success "$ip SSH服务就绪"
            return 0
        fi
        
        if [[ $((i % 60)) -eq 0 ]] && [[ $i -gt 0 ]]; then
            log "$ip SSH等待中... (${i}s/${max_wait}s)"
        fi
        
        sleep 10
    done
    
    error "$ip SSH服务超时"
            return 1
}

# 检查网络连接
check_network_connectivity() {
    local ip="$1"
    log "检查 $ip 网络连接..."
    
    local network_check_script='
        # 检查DNS解析
        echo "检查DNS解析..."
        if ! nslookup debian.org >/dev/null 2>&1 && ! nslookup google.com >/dev/null 2>&1; then
            echo "DNS解析失败，配置备用DNS..."
            cat > /etc/resolv.conf << "EOF"
nameserver 119.29.29.29
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
        fi
        
        # 测试网络连接
        echo "测试网络连接..."
        if ! ping -c 2 119.29.29.29 >/dev/null 2>&1 && ! ping -c 2 8.8.8.8 >/dev/null 2>&1; then
            echo "网络连接失败"
            exit 1
        fi
        
        echo "网络连接正常"
    '
    
    execute_remote_command "$ip" "$network_check_script"
}

# 等待Cloud-init完成（增强版）
wait_for_cloudinit() {
    local ip="$1"
    local max_wait="${2:-$CLOUDINIT_TIMEOUT}"
    
    log "等待 $ip Cloud-init完成..."
    
    for ((i=0; i<max_wait; i+=30)); do
        local status=""
        if status=$(execute_remote_command "$ip" "cloud-init status" 1 2>/dev/null); then
            echo -n "."
            if [[ "$status" == *"done"* ]]; then
                success "$ip Cloud-init完成"
                return 0
            elif [[ "$status" == *"error"* ]]; then
                warn "$ip Cloud-init出现错误，但继续执行"
                return 0
        fi
    else
            echo -n "x"
        fi
        
        if [[ $((i % 120)) -eq 0 ]] && [[ $i -gt 0 ]]; then
            log "$ip Cloud-init等待中... (${i}s/${max_wait}s)"
        fi
        
        sleep 30
    done
    
    warn "$ip Cloud-init超时，但继续执行"
    return 0
}

# ==========================================
# SSH配置修复
# ==========================================
fix_ssh_config() {
    local ip="$1"
    log "修复 $ip SSH配置..."
    
    local fix_script='
        # 备份配置
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%s)
        
        # 清理重复SFTP定义
        find /etc/ssh/sshd_config.d/ -name "*.conf" -exec sed -i "/^[[:space:]]*Subsystem[[:space:]]*sftp/d" {} \; 2>/dev/null || true
        
        # 确保主配置正确
        if ! grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config; then
            # 删除冲突配置
            sed -i "/^PermitRootLogin/d; /^PasswordAuthentication/d; /^PubkeyAuthentication/d" /etc/ssh/sshd_config
            
            # 添加新配置
            cat >> /etc/ssh/sshd_config << "EOF"

# PVE K8S部署专用SSH配置
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
EOF
        fi
        
        # 确保SFTP子系统存在
        if ! grep -q "^Subsystem.*sftp" /etc/ssh/sshd_config; then
            echo "Subsystem sftp /usr/lib/openssh/sftp-server" >> /etc/ssh/sshd_config
        fi
        
        # 验证并重启
        if sshd -t; then
            systemctl restart ssh sshd
            echo "SSH配置修复成功"
        else
            echo "SSH配置验证失败"
            exit 1
        fi
    '
    
    if execute_remote_command "$ip" "$fix_script"; then
        success "$ip SSH配置修复完成"
    else
        error "$ip SSH配置修复失败"
        return 1
    fi
}

fix_all_ssh_configs() {
    log "批量修复SSH配置..."
    local all_ips=($(get_all_ips))
    
    for ip in "${all_ips[@]}"; do
        fix_ssh_config "$ip"
    done
    
    success "所有SSH配置修复完成"
}

# ==========================================
# 云镜像管理
# ==========================================
download_cloud_image() {
    if [[ -f "$CLOUD_IMAGE_PATH" ]]; then
        log "云镜像已存在: $CLOUD_IMAGE_PATH"
    return 0
    fi
    
    log "下载云镜像..."
    mkdir -p "$(dirname "$CLOUD_IMAGE_PATH")"
    
    for url in "${CLOUD_IMAGE_URLS[@]}"; do
        log "尝试从 $url 下载..."
        if download_with_progress "$url" "$CLOUD_IMAGE_PATH" "Debian 12 云镜像"; then
            success "云镜像下载完成"
            return 0
        else
            warn "下载失败，尝试下一个源..."
            rm -f "$CLOUD_IMAGE_PATH"
        fi
    done
    
    error "所有镜像源下载失败"
    return 1
}

# ==========================================
# Cloud-init配置
# ==========================================
create_cloudinit_config() {
    local vm_ip="$1"
    local vm_id="$2"
    local userdata_file="/var/lib/vz/snippets/user-data-k8s-${vm_id}.yml"
    
    log "创建虚拟机 $vm_id 的Cloud-init配置..."
    
    cat > "$userdata_file" << EOF
#cloud-config

chpasswd:
  expire: false
  users:
    - name: root
      password: $CLOUDINIT_PASS
      type: text

# 禁用cloud-init网络配置，使用手动配置
network:
  config: disabled

write_files:
  - path: /etc/ssh/sshd_config.d/00-root-login.conf
    content: |
      PermitRootLogin yes
      PasswordAuthentication yes
      PubkeyAuthentication yes
      AuthorizedKeysFile .ssh/authorized_keys
      ChallengeResponseAuthentication no
      UsePAM yes
      X11Forwarding yes
      PrintMotd no
      AcceptEnv LANG LC_*
    permissions: '0644'
    owner: root:root
  
  - path: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter
    permissions: '0644'
    owner: root:root
  
  - path: /etc/sysctl.d/99-k8s.conf
    content: |
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward = 1
    permissions: '0644'
    owner: root:root
  
  - path: /etc/network/interfaces.d/eth0
    content: |
      auto eth0
      iface eth0 inet static
        address ${vm_ip}
        netmask 255.255.255.0
        gateway $GATEWAY
        dns-nameservers 119.29.29.29 8.8.8.8 1.1.1.1
    permissions: '0644'
    owner: root:root

packages:
  - openssh-server
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - net-tools
  - ifupdown

runcmd:
  # 禁用可能冲突的网络服务
  - systemctl stop systemd-networkd systemd-networkd-wait-online 2>/dev/null || true
  - systemctl disable systemd-networkd systemd-networkd-wait-online 2>/dev/null || true
  - systemctl mask systemd-networkd-wait-online 2>/dev/null || true
  
  # 使用传统网络配置
  - systemctl enable networking
  - ip link set eth0 up
  - ifup eth0
  - sleep 3
  
  # 验证并手动配置（如果需要）
  - |
    echo "Configuring network interface..."
    if ! ip addr show eth0 | grep -q "inet ${vm_ip}"; then
      echo "ifupdown failed, using manual configuration"
      ip addr flush dev eth0 2>/dev/null || true
      ip addr add ${vm_ip}/24 dev eth0
      ip route add default via $GATEWAY dev eth0 2>/dev/null || true
    fi
    
    # 验证网络连接
    echo "Testing network connectivity..."
    if ping -c 3 $GATEWAY >/dev/null 2>&1; then
      echo "Network configuration successful - IP: ${vm_ip}"
    else
      echo "Network test failed, but continuing..."
    fi
  
  # DNS配置
  - |
    cat > /etc/resolv.conf << "EOF"
    nameserver 119.29.29.29
    nameserver 8.8.8.8
    nameserver 1.1.1.1
    EOF
  
  # 基础系统配置
  - apt-get update -y
  - systemctl enable ssh sshd
  - echo "root:$CLOUDINIT_PASS" | chpasswd
  - usermod -U root
  
  # SSH配置修复
  - systemctl stop ssh sshd
  - find /etc/ssh/sshd_config.d/ -name "*.conf" -exec sed -i '/^[[:space:]]*Subsystem[[:space:]]*sftp/d' {} \; 2>/dev/null || true
  - |
    if ! grep -q "^Subsystem.*sftp" /etc/ssh/sshd_config; then
      echo "Subsystem sftp /usr/lib/openssh/sftp-server" >> /etc/ssh/sshd_config
    fi
  - sshd -t && systemctl start ssh sshd || systemctl start ssh sshd
  
  # K8S环境准备
  - modprobe overlay br_netfilter
  - sysctl --system
  - swapoff -a
  - sed -i '/swap/d' /etc/fstab
  - timedatectl set-timezone Asia/Shanghai
  
  # 网络连接测试
  - ping -c 2 119.29.29.29 || ping -c 2 8.8.8.8 || echo "网络连接可能有问题"

final_message: "Cloud-init配置完成"
EOF
    
    success "虚拟机 $vm_id 的Cloud-init配置创建完成: $userdata_file"
    echo "$userdata_file"
}

# ==========================================
# 虚拟机管理
# ==========================================
create_vm() {
    local vm_id="$1"
    local vm_name=$(parse_vm_config "$vm_id" "name")
    local vm_ip=$(parse_vm_config "$vm_id" "ip")
    local vm_cores=$(parse_vm_config "$vm_id" "cores")
    local vm_memory=$(parse_vm_config "$vm_id" "memory")
    
    log "创建虚拟机: $vm_name (ID: $vm_id, IP: $vm_ip)"
    
    # 清理现有虚拟机
    qm stop "$vm_id" 2>/dev/null || true
    sleep 2
    qm destroy "$vm_id" 2>/dev/null || true
    
    # 创建虚拟机
    if qm create "$vm_id" \
        --name "$vm_name" \
        --memory "$vm_memory" \
        --cores "$vm_cores" \
        --net0 "virtio,bridge=$BRIDGE" \
            --scsihw virtio-scsi-pci \
        --ide2 "$STORAGE:cloudinit" \
            --serial0 socket \
        --vga std \
        --ipconfig0 "ip=$vm_ip/24,gw=$GATEWAY" \
        --nameserver "$DNS" \
        --ciuser "$CLOUDINIT_USER" \
        --cipassword "$CLOUDINIT_PASS" \
        --cicustom "user=local:snippets/user-data-k8s-${vm_id}.yml" \
        --agent enabled=1; then
        
        # 导入云镜像
        if qm importdisk "$vm_id" "$CLOUD_IMAGE_PATH" "$STORAGE" --format qcow2; then
            qm set "$vm_id" --scsi0 "$STORAGE:vm-$vm_id-disk-0"
            qm set "$vm_id" --boot c --bootdisk scsi0
            
            # 启动虚拟机
            if qm start "$vm_id"; then
                success "虚拟机 $vm_name 创建成功"
                return 0
            fi
        fi
    fi
    
    error "虚拟机 $vm_name 创建失败"
            return 1
}

create_all_vms() {
    log "创建所有虚拟机..."
    
    # 清理SSH known_hosts中的旧密钥
    log "清理SSH known_hosts中的旧密钥..."
    local all_ips=($(get_all_ips))
    for ip in "${all_ips[@]}"; do
        ssh-keygen -f "/root/.ssh/known_hosts" -R "$ip" 2>/dev/null || true
    done
    
    for vm_id in "${!VM_CONFIGS[@]}"; do
        local vm_ip=$(parse_vm_config "$vm_id" "ip")
        create_cloudinit_config "$vm_ip" "$vm_id"
        create_vm "$vm_id"
    done
    
    success "所有虚拟机创建完成"
}

wait_for_all_vms() {
    log "等待所有虚拟机启动..."
    
    local all_ips=($(get_all_ips))
    
    # 等待SSH连接
    for ip in "${all_ips[@]}"; do
        wait_for_ssh "$ip"
    done
    
    # 检查网络连接
    for ip in "${all_ips[@]}"; do
        check_network_connectivity "$ip" || warn "$ip 网络连接检查失败，但继续执行"
    done
    
    # 等待Cloud-init完成
    for ip in "${all_ips[@]}"; do
        wait_for_cloudinit "$ip"
    done
    
    success "所有虚拟机启动完成"
}

# ==========================================
# K8S部署
# ==========================================
# 验证Docker和K8S安装
verify_docker_k8s_installation() {
    local ip="$1"
    local verify_script='
        # 检查Docker
        if ! command -v docker &>/dev/null || ! systemctl is-active docker &>/dev/null; then
            echo "Docker验证失败"
            exit 1
        fi
        
        # 检查containerd
        if ! command -v containerd &>/dev/null || ! systemctl is-active containerd &>/dev/null; then
            echo "containerd验证失败"
            exit 1
        fi
        
        # 检查K8S组件
        if ! command -v kubectl &>/dev/null || ! command -v kubeadm &>/dev/null || ! command -v kubelet &>/dev/null; then
            echo "K8S组件验证失败"
            exit 1
        fi
        
        echo "Docker和K8S验证成功"
    '
    
    execute_remote_command "$ip" "$verify_script" 1
}

install_docker_k8s() {
    local ip="$1"
    log "在 $ip 安装Docker和K8S..."
    
    local install_script='
        set -e
        
        # 配置国内镜像源（仅基础仓库）
        echo "配置基础镜像源..."
        cat > /etc/apt/sources.list << "EOF"
deb https://mirrors.ustc.edu.cn/debian/ bookworm main contrib non-free non-free-firmware
deb https://mirrors.ustc.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware
deb https://mirrors.ustc.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware
deb https://mirrors.ustc.edu.cn/debian-security/ bookworm-security main contrib non-free non-free-firmware
EOF
        
        # 清理可能存在的旧仓库配置
        rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/kubernetes.list
        
        # 更新基础包列表并安装基础依赖
        apt-get update -y
        apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common
        
        # 创建keyrings目录
        mkdir -p /etc/apt/keyrings
        
        # 定义GitHub镜像源
        GITHUB_MIRRORS=(
            "https://github.com"
            "https://ghproxy.com/https://github.com"
            "https://mirror.ghproxy.com/https://github.com"
            "https://gh.api.99988866.xyz/https://github.com"
            "https://gitclone.com/github.com"
        )
        
        # K8S镜像源
        K8S_MIRRORS=(
            "https://dl.k8s.io"
            "https://storage.googleapis.com/kubernetes-release"
            "https://mirror.ghproxy.com/https://storage.googleapis.com/kubernetes-release"
        )
        
        # 软件版本
        DOCKER_VERSION="24.0.7"
        CONTAINERD_VERSION="1.7.8"
        RUNC_VERSION="1.1.9"
        K8S_VERSION="v1.28.2"
        
        # 下载函数
        download_with_progress() {
            local url="$1"
            local output="$2"
            local description="$3"
            local max_retries=3
            local retry_count=0
            
            echo "正在下载: $description"
            echo "URL: $url"
            
            while [ $retry_count -lt $max_retries ]; do
                if [ $retry_count -gt 0 ]; then
                    echo "重试 ($retry_count/$max_retries)..."
                    sleep 2
                fi
                
                if command -v curl >/dev/null 2>&1; then
                    echo "使用curl下载..."
                    if curl --progress-bar --connect-timeout 30 --max-time 300 -L "$url" -o "$output"; then
                        echo "✅ $description 下载成功"
                        return 0
                    fi
                fi
                
                if command -v wget >/dev/null 2>&1; then
                    echo "使用wget下载..."
                    if wget --progress=bar:force --timeout=30 --tries=3 "$url" -O "$output"; then
                        echo "✅ $description 下载成功"
                        return 0
                    fi
                fi
                
                ((retry_count++))
                echo "❌ 下载失败，准备重试..."
            done
            
            echo "❌ $description 下载失败，已重试 $max_retries 次"
            return 1
        }
        
        # GitHub文件下载函数
        download_github_file() {
            local github_path="$1"
            local output="$2"
            local description="$3"
            
            echo "正在下载: $description"
            
            for mirror in "${GITHUB_MIRRORS[@]}"; do
                local full_url="${mirror}${github_path}"
                echo "尝试镜像源: $mirror"
                
                if download_with_progress "$full_url" "$output" "$description"; then
                    return 0
                fi
                
                echo "当前镜像源失败，尝试下一个..."
                rm -f "$output" 2>/dev/null || true
            done
            
            echo "❌ 所有GitHub镜像源都失败了"
            return 1
        }
        
        # 软件下载函数
        download_software() {
            local software_name="$1"
            local version="$2"
            local github_repo="$3"
            local filename="$4"
            local output="$5"
            
            local github_path="/${github_repo}/releases/download/${version}/${filename}"
            download_github_file "$github_path" "$output" "${software_name} ${version}"
        }
        
        # K8S二进制文件下载函数
        download_k8s_binary() {
            local binary_name="$1"
            local version="$2"
            
            echo "正在下载: ${binary_name} ${version}"
            
            for mirror in "${K8S_MIRRORS[@]}"; do
                local full_url="${mirror}/release/${version}/bin/linux/amd64/${binary_name}"
                echo "尝试镜像源: $mirror"
                
                if download_with_progress "$full_url" "$binary_name" "${binary_name} ${version}"; then
                    chmod +x "$binary_name"
                    mv "$binary_name" /usr/local/bin/
                    echo "✅ ${binary_name} 安装成功"
                    return 0
                fi
                
                echo "当前镜像源失败，尝试下一个..."
                rm -f "$binary_name" 2>/dev/null || true
            done
            
            echo "❌ 所有K8S镜像源都失败了"
            return 1
        }
        
        # 安装Docker和containerd
        echo "开始安装Docker和containerd..."
        temp_dir="/tmp/docker-install"
        mkdir -p "$temp_dir"
        cd "$temp_dir"
        
        # 下载并安装Docker
        if download_software "Docker" "v$DOCKER_VERSION" "docker/docker" "docker-$DOCKER_VERSION.tgz" "docker.tgz"; then
            echo "Docker二进制文件下载成功"
            tar -xzf docker.tgz
            cp docker/* /usr/local/bin/
            chmod +x /usr/local/bin/docker*
            groupadd docker 2>/dev/null || true
            echo "Docker安装完成"
        else
            echo "Docker下载失败"
            exit 1
        fi
        
        # 下载并安装containerd
        if download_software "containerd" "v$CONTAINERD_VERSION" "containerd/containerd" "containerd-$CONTAINERD_VERSION-linux-amd64.tar.gz" "containerd.tar.gz"; then
            echo "containerd下载成功"
            tar -xzf containerd.tar.gz -C /usr/local/
            echo "containerd安装完成"
        else
            echo "containerd下载失败"
            exit 1
        fi
        
        # 下载并安装runc
        if download_software "runc" "v$RUNC_VERSION" "opencontainers/runc" "runc.amd64" "runc"; then
            echo "runc下载成功"
            chmod +x runc
            mv runc /usr/local/bin/
            echo "runc安装完成"
        else
            echo "runc下载失败，使用系统包"
            apt-get install -y runc || true
        fi
        
        cd /
        rm -rf "$temp_dir"
        
        # 创建Docker服务文件
        cat > /etc/systemd/system/docker.service << '"'"'EOF'"'"'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target docker.socket firewalld.service containerd.service time-set.target
Wants=network-online.target containerd.service
Requires=docker.socket containerd.service

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutStartSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

        cat > /etc/systemd/system/docker.socket << '"'"'EOF'"'"'
[Unit]
Description=Docker Socket for the API

[Socket]
ListenStream=/var/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF

        cat > /etc/systemd/system/containerd.service << '"'"'EOF'"'"'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
        
        # 创建containerd配置
        mkdir -p /etc/containerd
        containerd config default > /etc/containerd/config.toml
        sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml
        sed -i "s|registry.k8s.io/pause:3.6|registry.aliyuncs.com/google_containers/pause:3.6|g" /etc/containerd/config.toml
        
        # 配置Docker镜像加速
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json << '"'"'EOF'"'"'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m"},
  "storage-driver": "overlay2",
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com",
    "https://mirror.baidubce.com"
  ]
}
EOF
        
        # 启动服务
        systemctl daemon-reload
        systemctl enable docker containerd
        systemctl restart docker containerd
        
        # 验证安装
        if docker --version && containerd --version; then
            echo "✅ Docker和containerd安装成功"
        else
            echo "❌ Docker或containerd启动失败"
            exit 1
        fi
        
        # 安装K8S组件
        echo "开始安装K8S组件..."
        temp_dir="/tmp/k8s-install"
        mkdir -p "$temp_dir"
        cd "$temp_dir"
        
        # 下载K8S组件
        download_k8s_binary "kubectl" "$K8S_VERSION" || exit 1
        download_k8s_binary "kubeadm" "$K8S_VERSION" || exit 1
        download_k8s_binary "kubelet" "$K8S_VERSION" || exit 1
        
        cd /
        rm -rf "$temp_dir"
        
        # 创建kubelet服务文件
        cat > /etc/systemd/system/kubelet.service << '"'"'EOF'"'"'
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/home/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

        mkdir -p /etc/systemd/system/kubelet.service.d
        cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf << '"'"'EOF'"'"'
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
EOF
        
        systemctl daemon-reload
        systemctl enable kubelet
        
        echo "✅ K8S组件安装成功"
        
        apt-mark hold kubelet kubeadm kubectl
        systemctl enable kubelet
        
        # 验证K8S安装
        if ! kubectl version --client && ! kubeadm version; then
            echo "K8S组件验证失败"
            exit 1
        fi
        
        echo "Docker和K8S安装完成"
    '
    
    # 尝试安装，如果失败则重试
    if ! execute_remote_command "$ip" "$install_script"; then
        warn "$ip Docker/K8S安装失败，尝试修复..."
        
        # 修复安装
        local fix_script='
            echo "清理失败的安装..."
            apt-get remove --purge -y docker-ce docker-ce-cli containerd.io kubelet kubeadm kubectl 2>/dev/null || true
            apt-get autoremove -y
            rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/kubernetes.list
            rm -f /etc/apt/keyrings/docker.gpg /etc/apt/keyrings/kubernetes.gpg
            rm -f /etc/apt/keyrings/docker.gpg.tmp /etc/apt/keyrings/kubernetes.gpg.tmp
            
            echo "重新安装..."
        '
        
        execute_remote_command "$ip" "$fix_script"
        
        # 重新尝试安装
        if ! execute_remote_command "$ip" "$install_script"; then
            error "$ip Docker/K8S安装最终失败"
                return 1
            fi
    fi
    
    # 验证安装
    if verify_docker_k8s_installation "$ip"; then
        success "$ip Docker和K8S安装验证成功"
    else
        error "$ip Docker和K8S安装验证失败"
        return 1
    fi
}

init_k8s_master() {
    local master_ip=$(get_master_ip)
    log "初始化K8S主节点..."
    
    # 首先验证master节点的Docker和K8S安装
    if ! verify_docker_k8s_installation "$master_ip"; then
        error "Master节点Docker/K8S验证失败，重新安装..."
        install_docker_k8s "$master_ip"
    fi
    
    local init_script="
        set -e
        echo '开始初始化K8S主节点...'
        
        # 清理之前的配置
        kubeadm reset -f 2>/dev/null || true
        rm -rf /etc/kubernetes/manifests/* 2>/dev/null || true
        rm -rf /var/lib/etcd/* 2>/dev/null || true
        
        # 确保Docker和containerd运行
        systemctl restart docker containerd
            sleep 5
        
        # 使用国内镜像初始化
        if ! kubeadm init \
            --apiserver-advertise-address=$master_ip \
            --pod-network-cidr=$POD_SUBNET \
            --kubernetes-version=$K8S_VERSION \
            --image-repository=registry.aliyuncs.com/google_containers \
            --ignore-preflight-errors=all; then
            echo 'K8S初始化失败'
            exit 1
        fi
        
        # 配置kubectl
        mkdir -p /root/.kube
        cp /etc/kubernetes/admin.conf /root/.kube/config
        
        # 验证kubectl工作
        if ! kubectl get nodes; then
            echo 'kubectl配置失败'
            exit 1
        fi
        
        echo '下载Calico配置文件...'
        # 下载并修改Calico配置，使用多个备用方案
        if ! wget -O calico.yaml https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml; then
            if ! curl -o calico.yaml https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml; then
                echo 'GitHub下载失败，尝试国内镜像源...'
                # 尝试使用国内镜像源
                if ! wget -O calico.yaml https://gitee.com/mirrors/calico/raw/v3.26.1/manifests/calico.yaml; then
                    echo 'Gitee镜像源失败，使用官方备用方案...'
                    # 使用官方备用地址
                    if ! kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml; then
                        echo 'Calico网络插件安装失败，使用Flannel作为备用...'
                        # 使用Flannel作为最后的备用方案
                        kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml || \
                        kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml || \
                        exit 1
                    fi
                else
                    kubectl apply -f calico.yaml || exit 1
                fi
            else
                kubectl apply -f calico.yaml || exit 1
            fi
        else
            kubectl apply -f calico.yaml || exit 1
        fi
        
        echo 'K8S主节点初始化完成'
    "
    
    if execute_remote_command "$master_ip" "$init_script"; then
        success "K8S主节点初始化完成"
        
        # 验证主节点状态
        local verify_script="
            kubectl get nodes
            kubectl get pods --all-namespaces
        "
        execute_remote_command "$master_ip" "$verify_script" || warn "主节点状态检查有警告"
    else
        error "K8S主节点初始化失败"
        return 1
    fi
}

join_workers() {
    local master_ip=$(get_master_ip)
    
    # 获取加入命令
    local join_cmd=$(execute_remote_command "$master_ip" "kubeadm token create --print-join-command")
    
    if [[ -z "$join_cmd" ]]; then
        error "获取集群加入令牌失败"
        return 1
    fi
    
    # 加入worker节点
    for vm_id in "${!VM_CONFIGS[@]}"; do
        if [[ "$vm_id" != "100" ]]; then  # 跳过master节点
            local worker_ip=$(parse_vm_config "$vm_id" "ip")
            local worker_name=$(parse_vm_config "$vm_id" "name")
            
            log "将 $worker_name 加入集群..."
            
            # 首先验证worker节点的Docker和K8S安装
            if ! verify_docker_k8s_installation "$worker_ip"; then
                error "Worker节点 $worker_name Docker/K8S验证失败，重新安装..."
                install_docker_k8s "$worker_ip"
            fi
            
            local join_script="
                set -e
                echo '开始加入worker节点...'
                
                # 重置节点
                kubeadm reset -f 2>/dev/null || true
                
                # 确保Docker和containerd运行
                systemctl restart docker containerd
                sleep 5
                
                # 验证containerd socket
                if ! systemctl is-active containerd; then
                    echo 'containerd未运行，启动containerd...'
                    systemctl start containerd
                sleep 3
            fi
                
                # 验证Docker
                if ! docker ps &>/dev/null; then
                    echo 'Docker未正常工作'
                    exit 1
                fi
                
                # 加入集群
                if ! $join_cmd --ignore-preflight-errors=all; then
                    echo 'Worker节点加入失败'
                    exit 1
                fi
                
                echo 'Worker节点加入完成'
            "
            
            if execute_remote_command "$worker_ip" "$join_script"; then
                success "Worker节点 $worker_name 加入完成"
                
                # 验证节点状态
                local verify_script="
                    kubectl get nodes | grep $worker_name || kubectl get nodes
                "
                execute_remote_command "$master_ip" "$verify_script" || warn "Worker节点 $worker_name 状态检查有警告"
            else
                error "Worker节点 $worker_name 加入失败"
                
                # 尝试修复
                warn "尝试修复Worker节点 $worker_name..."
                local fix_script="
                    echo '修复Worker节点...'
                    
                    # 清理失败的状态
                    kubeadm reset -f
                    
                    # 重启服务
                    systemctl restart docker containerd kubelet
                    sleep 10
                    
                    # 重新加入
                    $join_cmd --ignore-preflight-errors=all
                "
                
                if execute_remote_command "$worker_ip" "$fix_script"; then
                    success "Worker节点 $worker_name 修复成功"
                else
                    error "Worker节点 $worker_name 修复失败，请手动检查"
                fi
            fi
        fi
    done
    
    # 最终验证集群状态
    log "验证集群状态..."
    local cluster_status=$(execute_remote_command "$master_ip" "kubectl get nodes -o wide" 1)
    echo "$cluster_status"
    
    success "所有worker节点加入完成"
}

deploy_k8s() {
    log "部署K8S集群..."
    
    # 安装Docker和K8S组件
    local all_ips=($(get_all_ips))
    for ip in "${all_ips[@]}"; do
        install_docker_k8s "$ip"
    done
    
    # 初始化主节点
    init_k8s_master
    
    # 加入worker节点
    join_workers
    
    # 等待集群就绪
    local master_ip=$(get_master_ip)
    execute_remote_command "$master_ip" "kubectl wait --for=condition=Ready nodes --all --timeout=300s"
    
    success "K8S集群部署完成"
}

# ==========================================
# KubeSphere部署
# ==========================================
deploy_kubesphere() {
    local master_ip=$(get_master_ip)
    log "部署KubeSphere..."
    
    local deploy_script='
        # 下载配置文件，使用多个备用方案
        echo "下载KubeSphere配置文件..."
        
        # 下载kubesphere-installer.yaml
        if ! download_with_progress "https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml" "kubesphere-installer.yaml" "KubeSphere Installer"; then
            echo "GitHub下载失败，尝试国内镜像源..."
            if ! download_with_progress "https://gitee.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml" "kubesphere-installer.yaml" "KubeSphere Installer (Gitee)"; then
                echo "所有源下载失败"
                exit 1
            fi
        fi
        
        # 下载cluster-configuration.yaml
        if ! download_with_progress "https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml" "cluster-configuration.yaml" "KubeSphere Cluster Configuration"; then
            echo "GitHub下载失败，尝试国内镜像源..."
            if ! download_with_progress "https://gitee.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml" "cluster-configuration.yaml" "KubeSphere Cluster Configuration (Gitee)"; then
                echo "所有源下载失败"
                exit 1
            fi
        fi
        
        # 部署KubeSphere
        kubectl apply -f kubesphere-installer.yaml
        kubectl apply -f cluster-configuration.yaml
    '
    
    execute_remote_command "$master_ip" "$deploy_script"
    
    log "KubeSphere部署启动，监控安装进度..."
    execute_remote_command "$master_ip" "kubectl logs -n kubesphere-system \$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath='{.items[0].metadata.name}') -f" 1 || true
    
    success "KubeSphere部署完成"
}

# ==========================================
# 修复功能
# ==========================================
fix_docker_k8s() {
    log "修复Docker和K8S安装..."
    
    local all_ips=($(get_all_ips))
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        log "修复 $vm_name ($ip) 的Docker和K8S..."
        
        # 检查当前状态
        local status_script='
            echo "=== 检查当前状态 ==="
            echo "Docker状态: $(systemctl is-active docker 2>/dev/null || echo "未安装")"
            echo "containerd状态: $(systemctl is-active containerd 2>/dev/null || echo "未安装")"
            echo "kubelet状态: $(systemctl is-active kubelet 2>/dev/null || echo "未安装")"
            echo "kubectl版本: $(kubectl version --client 2>/dev/null || echo "未安装")"
        '
        
        execute_remote_command "$ip" "$status_script"
        
        # 强制重新安装
        if ! verify_docker_k8s_installation "$ip"; then
            warn "$vm_name Docker/K8S验证失败，重新安装..."
            install_docker_k8s "$ip"
        else
            success "$vm_name Docker/K8S验证成功"
        fi
    done
}

fix_k8s_cluster() {
    log "修复K8S集群..."
    
    local master_ip=$(get_master_ip)
    
    # 检查master节点状态
    log "检查master节点状态..."
    local master_status=$(execute_remote_command "$master_ip" "kubectl get nodes 2>/dev/null || echo 'CLUSTER_NOT_READY'" 1)
    
    if [[ "$master_status" == "CLUSTER_NOT_READY" ]]; then
        warn "K8S集群未就绪，重新初始化master节点..."
        init_k8s_master
    else
        log "Master节点状态正常"
        echo "$master_status"
    fi
    
    # 检查worker节点
    log "检查worker节点状态..."
    for vm_id in "${!VM_CONFIGS[@]}"; do
        if [[ "$vm_id" != "100" ]]; then
            local worker_ip=$(parse_vm_config "$vm_id" "ip")
            local worker_name=$(parse_vm_config "$vm_id" "name")
            
            # 检查节点是否在集群中
            local node_in_cluster=$(execute_remote_command "$master_ip" "kubectl get nodes | grep $worker_name || echo 'NOT_FOUND'" 1)
            
            if [[ "$node_in_cluster" == "NOT_FOUND" ]]; then
                warn "Worker节点 $worker_name 不在集群中，重新加入..."
                
                # 获取加入命令
                local join_cmd=$(execute_remote_command "$master_ip" "kubeadm token create --print-join-command")
                
                if [[ -n "$join_cmd" ]]; then
                    local rejoin_script="
                        kubeadm reset -f
                        systemctl restart docker containerd kubelet
                        sleep 5
                        $join_cmd --ignore-preflight-errors=all
                    "
                    
                    if execute_remote_command "$worker_ip" "$rejoin_script"; then
                        success "Worker节点 $worker_name 重新加入成功"
                    else
                        error "Worker节点 $worker_name 重新加入失败"
        fi
    else
                    error "获取集群加入令牌失败"
                fi
            else
                log "Worker节点 $worker_name 状态: $node_in_cluster"
            fi
        fi
    done
}

fix_network_connectivity() {
    log "修复网络连接问题..."
    
    local all_ips=($(get_all_ips))
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        log "修复 $vm_name ($ip) 的网络连接..."
        
        local network_fix_script='
            echo "修复网络连接..."
            
            # 配置DNS
            echo "nameserver 119.29.29.29" > /etc/resolv.conf
            echo "nameserver 8.8.8.8" >> /etc/resolv.conf
            echo "nameserver 10.0.0.1" >> /etc/resolv.conf
            
            # 重启网络服务
            systemctl restart networking
            
            # 测试网络连接
            echo "测试网络连接..."
            ping -c 2 119.29.29.29 || echo "DNS连接失败"
            ping -c 2 baidu.com || echo "外网连接失败"
            
            # 测试镜像源
            # 测试多个镜像源的连通性
    echo "=== 镜像源连通性测试 ==="
    
    # 测试Debian镜像源
    echo -n "中科大Debian镜像源: "
    if curl -I --connect-timeout 10 --max-time 30 https://mirrors.ustc.edu.cn/debian/ &>/dev/null; then
        echo "✅ 可用"
    else
        echo "❌ 不可用"
    fi
    
    # 测试Docker镜像源
    echo -n "阿里云Docker镜像源: "
    if curl -I --connect-timeout 10 --max-time 30 https://mirrors.aliyun.com/docker-ce/linux/debian/ &>/dev/null; then
        echo "✅ 可用"
    else
        echo "❌ 不可用"
    fi
    
    # 测试K8S镜像源
    echo -n "阿里云K8S镜像源: "
    if curl -I --connect-timeout 10 --max-time 30 https://mirrors.aliyun.com/kubernetes/apt/ &>/dev/null; then
        echo "✅ 可用"
    else
        echo "❌ 不可用"
    fi
    
    # 测试容器镜像仓库
    echo -n "阿里云容器镜像仓库: "
    if curl -I --connect-timeout 10 --max-time 30 https://registry.aliyuncs.com/v2/ &>/dev/null; then
        echo "✅ 可用"
    else
        echo "❌ 不可用"
    fi
    
    # 测试GitHub
    echo -n "GitHub连接测试: "
    if curl -I --connect-timeout 10 --max-time 30 https://github.com/ &>/dev/null; then
        echo "✅ 可用"
    else
        echo "❌ 不可用"
    fi
    
    # 测试Gitee备用源
    echo -n "Gitee备用源: "
    if curl -I --connect-timeout 10 --max-time 30 https://gitee.com/ &>/dev/null; then
        echo "✅ 可用"
    else
        echo "❌ 不可用"
    fi
    
    # 测试K8S新官方仓库
    echo -n "K8S新官方仓库: "
    if curl -I --connect-timeout 10 --max-time 30 https://pkgs.k8s.io/core:/stable:/v1.28/deb/ &>/dev/null; then
        echo "✅ 可用"
    else
        echo "❌ 不可用"
    fi
    
    # 测试K8S旧官方仓库
    echo -n "K8S旧官方仓库: "
    if curl -I --connect-timeout 10 --max-time 30 https://packages.cloud.google.com/apt/ &>/dev/null; then
        echo "✅ 可用"
    else
        echo "❌ 不可用"
    fi
        '
        
        execute_remote_command "$ip" "$network_fix_script"
    done
}

# 自动诊断系统问题
diagnose_system() {
    log "开始系统诊断..."
    
    local issues_found=0
    local all_ips=($(get_all_ips))
    
    # 检查虚拟机状态
    log "检查虚拟机状态..."
    for vm_id in "${!VM_CONFIGS[@]}"; do
        local vm_name=$(parse_vm_config "$vm_id" "name")
        local vm_status=$(qm status "$vm_id" 2>/dev/null | grep -o "status: [^,]*" | cut -d' ' -f2)
        
        if [[ "$vm_status" != "running" ]]; then
            warn "虚拟机 $vm_name (ID: $vm_id) 状态异常: $vm_status"
            ((issues_found++))
        else
            log "虚拟机 $vm_name (ID: $vm_id) 状态正常"
        fi
    done
    
    # 检查SSH连接
    log "检查SSH连接..."
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        if ! test_ssh_connection "$ip"; then
            warn "SSH连接失败: $vm_name ($ip)"
            ((issues_found++))
        else
            log "SSH连接正常: $vm_name ($ip)"
        fi
    done
    
    # 检查Docker和K8S安装
    log "检查Docker和K8S安装..."
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        if ! verify_docker_k8s_installation "$ip"; then
            warn "Docker/K8S安装异常: $vm_name ($ip)"
            ((issues_found++))
        else
            log "Docker/K8S安装正常: $vm_name ($ip)"
        fi
    done
    
    # 检查K8S集群状态
    log "检查K8S集群状态..."
    local master_ip=$(get_master_ip)
    local cluster_status=$(execute_remote_command "$master_ip" "kubectl get nodes 2>/dev/null || echo 'CLUSTER_NOT_READY'" 1)
    
    if [[ "$cluster_status" == "CLUSTER_NOT_READY" ]]; then
        warn "K8S集群未就绪"
        ((issues_found++))
    else
        log "K8S集群状态:"
        echo "$cluster_status"
        
        # 检查节点状态
        local not_ready_nodes=$(echo "$cluster_status" | grep -c "NotReady" || echo "0")
        if [[ "$not_ready_nodes" -gt 0 ]]; then
            warn "发现 $not_ready_nodes 个NotReady节点"
            ((issues_found++))
        fi
    fi
    
    # 诊断结果
    if [[ $issues_found -eq 0 ]]; then
        success "系统诊断完成，未发现问题"
    else
        warn "系统诊断完成，发现 $issues_found 个问题"
    echo ""
        echo -e "${YELLOW}建议的修复步骤：${NC}"
        echo -e "  ${CYAN}1.${NC} 运行菜单选项 6 - 修复Docker和K8S安装"
        echo -e "  ${CYAN}2.${NC} 运行菜单选项 7 - 修复K8S集群"
        echo -e "  ${CYAN}3.${NC} 运行菜单选项 8 - 修复网络连接"
        echo -e "  ${CYAN}4.${NC} 运行菜单选项 9 - 修复SSH配置"
        echo -e "  ${CYAN}5.${NC} 或者运行菜单选项 12 - 一键修复所有问题"
    fi
    
    return $issues_found
}

# 一键修复所有问题
fix_all_issues() {
    log "开始一键修复所有问题..."
    
    # 先诊断问题
    if ! diagnose_system; then
        log "发现问题，开始修复..."
        
        # 修复网络连接
        log "第1步：修复网络连接..."
        fix_network_connectivity
        
        # 修复SSH配置
        log "第2步：修复SSH配置..."
        fix_all_ssh_configs
        
        # 修复Docker和K8S安装
        log "第3步：修复Docker和K8S安装..."
        fix_docker_k8s
        
        # 修复K8S集群
        log "第4步：修复K8S集群..."
        fix_k8s_cluster
        
        # 再次诊断
        log "修复完成，重新诊断..."
        if ! diagnose_system; then
            warn "部分问题可能仍然存在，请检查诊断结果"
        else
            success "所有问题已修复！"
        fi
    else
        success "系统状态正常，无需修复"
    fi
}

# 强制重建整个集群
rebuild_cluster() {
    log "开始强制重建K8S集群..."
    
    read -p "警告：这将删除现有集群并重新创建。确认继续？(y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log "操作已取消"
        return 0
    fi
    
    local all_ips=($(get_all_ips))
    
    # 清理所有节点
    log "清理所有节点..."
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        log "清理节点 $vm_name ($ip)..."
        
        local cleanup_script='
            # 停止K8S服务
            systemctl stop kubelet 2>/dev/null || true
            
            # 重置kubeadm
            kubeadm reset -f 2>/dev/null || true
            
            # 清理配置文件
            rm -rf /etc/kubernetes/
            rm -rf /var/lib/etcd/
            rm -rf /var/lib/kubelet/
            rm -rf /etc/cni/
            rm -rf /opt/cni/
            rm -rf /var/lib/cni/
            rm -rf /run/flannel/
            
            # 清理iptables规则
            iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
            
            # 重启Docker和containerd
            systemctl restart docker containerd
            
            echo "节点清理完成"
        '
        
        execute_remote_command "$ip" "$cleanup_script"
    done
    
    # 重新部署集群
    log "重新部署K8S集群..."
    deploy_k8s
    
    success "集群重建完成"
}

# 查看系统日志
view_logs() {
    log "查看系统日志..."
    
    echo -e "${YELLOW}请选择要查看的日志类型：${NC}"
    echo -e "  ${CYAN}1.${NC} 查看所有节点的系统日志"
    echo -e "  ${CYAN}2.${NC} 查看Docker日志"
    echo -e "  ${CYAN}3.${NC} 查看Kubelet日志"
    echo -e "  ${CYAN}4.${NC} 查看K8S Pod日志"
    echo -e "  ${CYAN}5.${NC} 查看Cloud-init日志"
    echo -e "  ${CYAN}0.${NC} 返回主菜单"
    
    read -p "请选择 [0-5]: " log_choice
    
    case $log_choice in
        1)
            local all_ips=($(get_all_ips))
            for ip in "${all_ips[@]}"; do
                local vm_name=$(get_vm_name_by_ip "$ip")
                echo -e "${CYAN}=== $vm_name ($ip) 系统日志 ===${NC}"
                execute_remote_command "$ip" "journalctl -n 50 --no-pager" || true
    echo ""
            done
            ;;
        2)
            local all_ips=($(get_all_ips))
            for ip in "${all_ips[@]}"; do
                local vm_name=$(get_vm_name_by_ip "$ip")
                echo -e "${CYAN}=== $vm_name ($ip) Docker日志 ===${NC}"
                execute_remote_command "$ip" "journalctl -u docker -n 20 --no-pager" || true
                echo ""
            done
            ;;
        3)
            local all_ips=($(get_all_ips))
            for ip in "${all_ips[@]}"; do
                local vm_name=$(get_vm_name_by_ip "$ip")
                echo -e "${CYAN}=== $vm_name ($ip) Kubelet日志 ===${NC}"
                execute_remote_command "$ip" "journalctl -u kubelet -n 20 --no-pager" || true
                echo ""
            done
            ;;
        4)
            local master_ip=$(get_master_ip)
            echo -e "${CYAN}=== K8S Pod日志 ===${NC}"
            execute_remote_command "$master_ip" "kubectl get pods --all-namespaces -o wide" || true
            echo ""
            echo -e "${CYAN}=== 问题Pod详情 ===${NC}"
            execute_remote_command "$master_ip" "kubectl get pods --all-namespaces | grep -E '(Error|CrashLoopBackOff|ImagePullBackOff|Pending)'" || true
            ;;
        5)
            local all_ips=($(get_all_ips))
            for ip in "${all_ips[@]}"; do
                local vm_name=$(get_vm_name_by_ip "$ip")
                echo -e "${CYAN}=== $vm_name ($ip) Cloud-init日志 ===${NC}"
                execute_remote_command "$ip" "tail -50 /var/log/cloud-init-output.log" || true
                echo ""
            done
            ;;
        0)
            return 0
            ;;
        *)
            warn "无效选择"
            ;;
    esac
}

# 生成故障报告
generate_troubleshooting_report() {
    log "生成故障排查报告..."
    
    local report_file="/tmp/k8s-troubleshooting-report-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "K8S集群故障排查报告"
        echo "生成时间: $(date)"
        echo "脚本版本: $SCRIPT_VERSION"
        echo "========================================"
    echo ""
        
        echo "虚拟机配置："
        for vm_id in "${!VM_CONFIGS[@]}"; do
            echo "  VM $vm_id: ${VM_CONFIGS[$vm_id]}"
        done
        echo ""
        
        echo "虚拟机状态："
        for vm_id in "${!VM_CONFIGS[@]}"; do
            local vm_name=$(parse_vm_config "$vm_id" "name")
            local vm_status=$(qm status "$vm_id" 2>/dev/null || echo "ERROR")
            echo "  $vm_name (ID: $vm_id): $vm_status"
        done
        echo ""
        
        echo "SSH连接测试："
        local all_ips=($(get_all_ips))
        for ip in "${all_ips[@]}"; do
            local vm_name=$(get_vm_name_by_ip "$ip")
            if test_ssh_connection "$ip"; then
                echo "  $vm_name ($ip): SSH连接正常"
            else
                echo "  $vm_name ($ip): SSH连接失败"
            fi
        done
        echo ""
        
        echo "Docker和K8S安装状态："
        for ip in "${all_ips[@]}"; do
            local vm_name=$(get_vm_name_by_ip "$ip")
            echo "  $vm_name ($ip):"
            
            local status_output=$(execute_remote_command "$ip" "
                echo '    Docker: '$(systemctl is-active docker 2>/dev/null || echo '未安装')
                echo '    containerd: '$(systemctl is-active containerd 2>/dev/null || echo '未安装')
                echo '    kubelet: '$(systemctl is-active kubelet 2>/dev/null || echo '未安装')
                echo '    kubectl: '$(kubectl version --client 2>/dev/null | head -1 || echo '未安装')
            " 1 2>/dev/null || echo "    无法获取状态信息")
            
            echo "$status_output"
        done
        echo ""
        
        echo "K8S集群状态："
        local master_ip=$(get_master_ip)
        local cluster_info=$(execute_remote_command "$master_ip" "kubectl get nodes -o wide 2>/dev/null || echo 'K8S集群未就绪'" 1)
        echo "$cluster_info"
    echo ""
    
        echo "Pod状态："
        local pod_info=$(execute_remote_command "$master_ip" "kubectl get pods --all-namespaces 2>/dev/null || echo 'K8S集群未就绪'" 1)
        echo "$pod_info"
    echo ""
        
        echo "========================================"
        echo "报告生成完成"
        
    } > "$report_file"
    
    success "故障排查报告已生成: $report_file"
    
    # 显示报告内容
    echo -e "${YELLOW}报告内容预览：${NC}"
    head -50 "$report_file"
    echo ""
    echo -e "${CYAN}完整报告路径: $report_file${NC}"
}

# 显示快速修复手册
show_quick_fix_guide() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                     快速修复手册                             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}常见问题及解决方法：${NC}"
    echo ""
    echo -e "${GREEN}1. 虚拟机无法SSH连接${NC}"
    echo -e "   - 检查虚拟机是否正在运行"
    echo -e "   - 运行菜单选项 9 修复SSH配置"
    echo -e "   - 检查网络配置是否正确"
    echo ""
    echo -e "${GREEN}2. Docker/K8S安装失败${NC}"
    echo -e "   - 运行菜单选项 8 修复网络连接"
    echo -e "   - 运行菜单选项 6 修复Docker和K8S安装"
    echo -e "   - 检查镜像源是否可访问"
    echo ""
    echo -e "${GREEN}3. K8S集群初始化失败${NC}"
    echo -e "   - 运行菜单选项 7 修复K8S集群"
    echo -e "   - 检查master节点的Docker服务状态"
    echo -e "   - 确认所有节点时间同步"
    echo ""
    echo -e "${GREEN}4. Worker节点无法加入集群${NC}"
    echo -e "   - 检查worker节点的containerd服务状态"
    echo -e "   - 运行菜单选项 7 修复K8S集群"
    echo -e "   - 确认网络连通性"
    echo ""
    echo -e "${GREEN}5. Pod状态异常${NC}"
    echo -e "   - 运行菜单选项 15 查看系统日志"
    echo -e "   - 检查镜像拉取是否正常"
    echo -e "   - 检查节点资源是否充足"
    echo ""
    echo -e "${GREEN}6. 一键解决所有问题${NC}"
    echo -e "   - 运行菜单选项 10 系统诊断"
    echo -e "   - 运行菜单选项 12 一键修复所有问题"
    echo -e "   - 如果问题严重，运行菜单选项 13 强制重建集群"
    echo ""
    echo -e "${YELLOW}调试技巧：${NC}"
    echo -e "   - 使用菜单选项 16 生成详细的故障报告"
    echo -e "   - 使用菜单选项 15 查看具体的系统日志"
    echo -e "   - 检查 /var/log/cloud-init-output.log 了解初始化过程"
    echo ""
    echo -e "${RED}紧急情况：${NC}"
    echo -e "   - 如果系统完全无响应，使用菜单选项 14 清理所有资源"
    echo -e "   - 然后重新运行菜单选项 1 一键全自动部署"
    echo ""
}

# 性能监控
monitor_cluster_performance() {
    log "监控集群性能..."
    
    local master_ip=$(get_master_ip)
    local all_ips=($(get_all_ips))
    
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                     集群性能监控                             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 节点资源使用情况
    echo -e "${YELLOW}节点资源使用情况：${NC}"
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        echo -e "${GREEN}=== $vm_name ($ip) ===${NC}"
        
        execute_remote_command "$ip" "
            echo 'CPU使用率:'
            top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\([0-9.]*\)%* id.*/\1/' | awk '{print 100 - \$1\"%\"}'
            echo 'Memory使用情况:'
            free -h | grep '^Mem'
            echo 'Disk使用情况:'
            df -h | grep -E '^/dev/'
            echo 'Load Average:'
            uptime
        " || warn "$vm_name 无法获取性能数据"
        echo ""
    done
    
    # K8S集群资源使用
    echo -e "${YELLOW}K8S集群资源使用：${NC}"
    execute_remote_command "$master_ip" "
        echo '=== 节点资源使用 ==='
        kubectl top nodes 2>/dev/null || echo 'metrics-server未安装'
        echo ''
        echo '=== Pod资源使用 ==='
        kubectl top pods --all-namespaces 2>/dev/null || echo 'metrics-server未安装'
        echo ''
        echo '=== 集群事件 ==='
        kubectl get events --sort-by=.metadata.creationTimestamp | tail -10
    " || warn "无法获取K8S集群性能数据"
    
    echo ""
    echo -e "${CYAN}提示：如需详细监控，建议安装 metrics-server 或 Prometheus${NC}"
}

# 备份集群配置
backup_cluster_config() {
    log "备份集群配置..."
    
    local backup_dir="/tmp/k8s-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    
    local master_ip=$(get_master_ip)
    
    # 备份K8S配置
    log "备份K8S配置文件..."
    execute_remote_command "$master_ip" "
        mkdir -p /tmp/k8s-config-backup
        cp -r /etc/kubernetes /tmp/k8s-config-backup/ 2>/dev/null || true
        kubectl get all --all-namespaces -o yaml > /tmp/k8s-config-backup/all-resources.yaml 2>/dev/null || true
        kubectl get nodes -o yaml > /tmp/k8s-config-backup/nodes.yaml 2>/dev/null || true
        kubectl get configmaps --all-namespaces -o yaml > /tmp/k8s-config-backup/configmaps.yaml 2>/dev/null || true
        kubectl get secrets --all-namespaces -o yaml > /tmp/k8s-config-backup/secrets.yaml 2>/dev/null || true
        tar -czf /tmp/k8s-config-backup.tar.gz -C /tmp k8s-config-backup
    "
    
    # 下载备份文件到本地
    log "下载备份文件到本地..."
    sshpass -p "$CLOUDINIT_PASS" scp -o StrictHostKeyChecking=no \
        "$CLOUDINIT_USER@$master_ip:/tmp/k8s-config-backup.tar.gz" \
        "$backup_dir/k8s-config-backup.tar.gz" 2>/dev/null || warn "备份文件下载失败"
    
    # 备份脚本配置
    log "备份脚本配置..."
    cat > "$backup_dir/vm-configs.txt" << EOF
# K8S集群虚拟机配置备份
# 生成时间: $(date)
# 脚本版本: $SCRIPT_VERSION

VM_CONFIGS:
EOF
    
    for vm_id in "${!VM_CONFIGS[@]}"; do
        echo "VM_$vm_id=${VM_CONFIGS[$vm_id]}" >> "$backup_dir/vm-configs.txt"
    done
    
    # 备份网络配置
    cat > "$backup_dir/network-config.txt" << EOF
# 网络配置备份
BRIDGE_NAME=$BRIDGE_NAME
NETWORK_CIDR=$NETWORK_CIDR
GATEWAY=$GATEWAY
DNS_SERVERS=$DNS_SERVERS
POD_SUBNET=$POD_SUBNET
SERVICE_SUBNET=$SERVICE_SUBNET
EOF
    
    success "集群配置备份完成: $backup_dir"
    echo -e "${CYAN}备份内容：${NC}"
    echo -e "  - K8S配置文件和资源定义"
    echo -e "  - 虚拟机配置信息"
    echo -e "  - 网络配置参数"
    echo -e "  - 备份路径: $backup_dir"
}

# 安装metrics-server
install_metrics_server() {
    log "安装metrics-server..."
    
    local master_ip=$(get_master_ip)
    
    local install_script='
        echo "下载metrics-server配置..."
        # 下载metrics-server配置文件，使用多个备用方案
        if ! wget -O metrics-server.yaml https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml; then
            echo "GitHub下载失败，尝试国内镜像源..."
            if ! wget -O metrics-server.yaml https://gitee.com/mirrors/metrics-server/raw/master/deploy/kubernetes/metrics-server-deployment.yaml; then
                echo "Gitee下载失败，使用curl重试..."
                curl -L -o metrics-server.yaml https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml || exit 1
            fi
        fi
        
        # 修改配置以支持不安全的TLS
        sed -i "/- --cert-dir=\/tmp/a\        - --kubelet-insecure-tls" metrics-server.yaml
        sed -i "/- --secure-port=4443/a\        - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname" metrics-server.yaml
        
        # 部署metrics-server
        kubectl apply -f metrics-server.yaml
        
        echo "等待metrics-server就绪..."
        kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=300s
        
        echo "验证metrics-server..."
        kubectl top nodes
    '
    
    if execute_remote_command "$master_ip" "$install_script"; then
        success "metrics-server安装成功"
    else
        error "metrics-server安装失败"
    fi
}

# 高级配置选项
advanced_config() {
    log "高级配置选项..."
    
    echo -e "${YELLOW}请选择高级配置选项：${NC}"
    echo -e "  ${CYAN}1.${NC} 安装metrics-server（性能监控）"
    echo -e "  ${CYAN}2.${NC} 配置Ingress控制器"
    echo -e "  ${CYAN}3.${NC} 安装存储类（StorageClass）"
    echo -e "  ${CYAN}4.${NC} 配置网络策略"
    echo -e "  ${CYAN}5.${NC} 安装Helm包管理器"
    echo -e "  ${CYAN}0.${NC} 返回主菜单"
    
    read -p "请选择 [0-5]: " config_choice
    
    case $config_choice in
        1)
            install_metrics_server
            ;;
        2)
            install_ingress_controller
            ;;
        3)
            install_storage_class
            ;;
        4)
            configure_network_policy
            ;;
        5)
            install_helm
            ;;
        0)
            return 0
            ;;
        *)
            warn "无效选择"
            ;;
    esac
}

# 安装Ingress控制器
install_ingress_controller() {
    log "安装Ingress控制器..."
    
    local master_ip=$(get_master_ip)
    
    local install_script='
        echo "安装NGINX Ingress控制器..."
        kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml
        
        echo "等待Ingress控制器就绪..."
        kubectl wait --namespace ingress-nginx \
            --for=condition=ready pod \
            --selector=app.kubernetes.io/component=controller \
            --timeout=300s
        
        echo "验证Ingress控制器..."
        kubectl get pods -n ingress-nginx
    '
    
    if execute_remote_command "$master_ip" "$install_script"; then
        success "Ingress控制器安装成功"
    else
        error "Ingress控制器安装失败"
    fi
}

# 安装存储类
install_storage_class() {
    log "安装本地存储类..."
    
    local master_ip=$(get_master_ip)
    
    local install_script='
        echo "创建本地存储类..."
        cat > local-storage-class.yaml << "EOF"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF
        
        kubectl apply -f local-storage-class.yaml
        
        echo "验证存储类..."
        kubectl get storageclass
    '
    
    if execute_remote_command "$master_ip" "$install_script"; then
        success "存储类安装成功"
    else
        error "存储类安装失败"
    fi
}

# 配置网络策略
configure_network_policy() {
    log "配置网络策略..."
    
    local master_ip=$(get_master_ip)
    
    local install_script='
        echo "创建默认网络策略..."
        cat > default-network-policy.yaml << "EOF"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: default
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: default
EOF
        
        kubectl apply -f default-network-policy.yaml
        
        echo "验证网络策略..."
        kubectl get networkpolicy
    '
    
    if execute_remote_command "$master_ip" "$install_script"; then
        success "网络策略配置成功"
    else
        error "网络策略配置失败"
    fi
}

# 安装Helm
install_helm() {
    log "安装Helm包管理器..."
    
    local master_ip=$(get_master_ip)
    
    local install_script='
        echo "下载并安装Helm..."
        # 下载Helm安装脚本，使用多个备用方案
        if ! curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3; then
            echo "GitHub下载失败，尝试国内镜像源..."
            if ! curl -fsSL -o get_helm.sh https://gitee.com/mirrors/helm/raw/main/scripts/get-helm-3; then
                echo "Gitee下载失败，使用wget重试..."
                wget -O get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 || exit 1
            fi
        fi
        chmod 700 get_helm.sh
        ./get_helm.sh
        
        echo "验证Helm安装..."
        helm version
        
        echo "添加常用Helm仓库..."
        helm repo add stable https://charts.helm.sh/stable
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
        helm repo update
        
        echo "列出可用仓库..."
        helm repo list
    '
    
    if execute_remote_command "$master_ip" "$install_script"; then
        success "Helm安装成功"
    else
        error "Helm安装失败"
    fi
}

# 集群健康检查
cluster_health_check() {
    log "执行集群健康检查..."
    
    local master_ip=$(get_master_ip)
    local all_ips=($(get_all_ips))
    local health_score=0
    local max_score=100
    
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                     集群健康检查                             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 1. 虚拟机状态检查 (20分)
    echo -e "${YELLOW}1. 虚拟机状态检查...${NC}"
    local vm_healthy=0
    local vm_total=0
    for vm_id in "${!VM_CONFIGS[@]}"; do
        local vm_name=$(parse_vm_config "$vm_id" "name")
        local vm_status=$(qm status "$vm_id" 2>/dev/null | grep -o "status: [^,]*" | cut -d' ' -f2)
        ((vm_total++))
        
        if [[ "$vm_status" == "running" ]]; then
            echo -e "   ✓ $vm_name 运行正常"
            ((vm_healthy++))
        else
            echo -e "   ✗ $vm_name 状态异常: $vm_status"
        fi
    done
    
    local vm_score=$((vm_healthy * 20 / vm_total))
    health_score=$((health_score + vm_score))
    echo -e "   评分: $vm_score/20"
    echo ""
    
    # 2. SSH连接检查 (15分)
    echo -e "${YELLOW}2. SSH连接检查...${NC}"
    local ssh_healthy=0
    local ssh_total=0
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        ((ssh_total++))
        
        if test_ssh_connection "$ip"; then
            echo -e "   ✓ $vm_name ($ip) SSH连接正常"
            ((ssh_healthy++))
        else
            echo -e "   ✗ $vm_name ($ip) SSH连接失败"
        fi
    done
    
    local ssh_score=$((ssh_healthy * 15 / ssh_total))
    health_score=$((health_score + ssh_score))
    echo -e "   评分: $ssh_score/15"
    echo ""
    
    # 3. Docker和K8S服务检查 (25分)
    echo -e "${YELLOW}3. Docker和K8S服务检查...${NC}"
    local service_healthy=0
    local service_total=0
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        
        # 检查Docker
        ((service_total++))
        if execute_remote_command "$ip" "systemctl is-active docker" 1 >/dev/null 2>&1; then
            echo -e "   ✓ $vm_name Docker服务正常"
            ((service_healthy++))
        else
            echo -e "   ✗ $vm_name Docker服务异常"
        fi
        
        # 检查containerd
        ((service_total++))
        if execute_remote_command "$ip" "systemctl is-active containerd" 1 >/dev/null 2>&1; then
            echo -e "   ✓ $vm_name containerd服务正常"
            ((service_healthy++))
        else
            echo -e "   ✗ $vm_name containerd服务异常"
        fi
        
        # 检查kubelet
        ((service_total++))
        if execute_remote_command "$ip" "systemctl is-active kubelet" 1 >/dev/null 2>&1; then
            echo -e "   ✓ $vm_name kubelet服务正常"
            ((service_healthy++))
        else
            echo -e "   ✗ $vm_name kubelet服务异常"
        fi
    done
    
    local service_score=$((service_healthy * 25 / service_total))
    health_score=$((health_score + service_score))
    echo -e "   评分: $service_score/25"
    echo ""
    
    # 4. K8S集群状态检查 (25分)
    echo -e "${YELLOW}4. K8S集群状态检查...${NC}"
    local cluster_score=0
    
    # 检查集群连通性
    if execute_remote_command "$master_ip" "kubectl get nodes" 1 >/dev/null 2>&1; then
        echo -e "   ✓ K8S API服务器可访问"
        cluster_score=$((cluster_score + 10))
        
        # 检查节点状态
        local ready_nodes=$(execute_remote_command "$master_ip" "kubectl get nodes --no-headers | grep -c Ready" 1 2>/dev/null || echo "0")
        local total_nodes=$(execute_remote_command "$master_ip" "kubectl get nodes --no-headers | wc -l" 1 2>/dev/null || echo "0")
        
        if [[ "$ready_nodes" -eq "$total_nodes" ]] && [[ "$total_nodes" -gt 0 ]]; then
            echo -e "   ✓ 所有节点状态Ready ($ready_nodes/$total_nodes)"
            cluster_score=$((cluster_score + 15))
        else
            echo -e "   ✗ 部分节点状态异常 ($ready_nodes/$total_nodes Ready)"
            cluster_score=$((cluster_score + ready_nodes * 15 / total_nodes))
        fi
    else
        echo -e "   ✗ K8S API服务器不可访问"
    fi
    
    health_score=$((health_score + cluster_score))
    echo -e "   评分: $cluster_score/25"
    echo ""
    
    # 5. 系统资源检查 (15分)
    echo -e "${YELLOW}5. 系统资源检查...${NC}"
    local resource_score=0
    local resource_checks=0
    
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        
        # 检查内存使用率
        local mem_usage=$(execute_remote_command "$ip" "free | grep Mem | awk '{printf \"%.0f\", \$3/\$2 * 100}'" 1 2>/dev/null || echo "100")
        ((resource_checks++))
        
        if [[ "$mem_usage" -lt 80 ]]; then
            echo -e "   ✓ $vm_name 内存使用率正常 (${mem_usage}%)"
            ((resource_score += 3))
        else
            echo -e "   ⚠ $vm_name 内存使用率较高 (${mem_usage}%)"
            ((resource_score += 1))
        fi
        
        # 检查磁盘使用率
        local disk_usage=$(execute_remote_command "$ip" "df / | tail -1 | awk '{print \$5}' | sed 's/%//'" 1 2>/dev/null || echo "100")
        ((resource_checks++))
        
        if [[ "$disk_usage" -lt 80 ]]; then
            echo -e "   ✓ $vm_name 磁盘使用率正常 (${disk_usage}%)"
            ((resource_score += 2))
        else
            echo -e "   ⚠ $vm_name 磁盘使用率较高 (${disk_usage}%)"
            ((resource_score += 1))
        fi
    done
    
    # 标准化资源评分到15分
    resource_score=$((resource_score * 15 / (resource_checks * 5)))
    health_score=$((health_score + resource_score))
    echo -e "   评分: $resource_score/15"
    echo ""
    
    # 总体健康评估
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}集群健康评分: $health_score/$max_score${NC}"
    
    if [[ $health_score -ge 90 ]]; then
        echo -e "${GREEN}✓ 集群状态优秀！${NC}"
    elif [[ $health_score -ge 70 ]]; then
        echo -e "${YELLOW}⚠ 集群状态良好，但有改进空间${NC}"
    elif [[ $health_score -ge 50 ]]; then
        echo -e "${YELLOW}⚠ 集群状态一般，建议进行优化${NC}"
    else
        echo -e "${RED}✗ 集群状态较差，需要立即修复${NC}"
        echo -e "${CYAN}建议运行菜单选项 12 - 一键修复所有问题${NC}"
    fi
    
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
}

# 自动化运维
fix_k8s_repository() {
    log "修复K8S仓库问题..."
    
    local all_ips=($(get_all_ips))
    
    for ip in "${all_ips[@]}"; do
        local vm_name=$(get_vm_name_by_ip "$ip")
        log "修复 $vm_name ($ip) 的K8S仓库..."
        
        local fix_script='
            echo "=== 修复K8S仓库配置 ==="
            
            # 清理现有配置
            echo "清理现有K8S仓库配置..."
            rm -f /etc/apt/sources.list.d/kubernetes.list
            rm -f /etc/apt/keyrings/kubernetes.gpg*
            
            # 清理旧的apt-key配置
            apt-key del 7F92E05B31093BEF5A3C2D38FEEA9169307EA071 2>/dev/null || true
            apt-key del A362B822F6DEDC652817EA46B53DC80D13EDEF05 2>/dev/null || true
            
            # 创建keyrings目录
            mkdir -p /etc/apt/keyrings
            
            # 测试多个K8S仓库源
            echo "测试K8S仓库源..."
            
            # 1. 尝试阿里云镜像源
            echo "尝试阿里云K8S镜像源..."
            if curl -fsSL https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg; then
                echo "阿里云GPG密钥安装成功"
                chmod a+r /etc/apt/keyrings/kubernetes.gpg
                echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
                
                echo "测试阿里云仓库更新..."
                if apt-get update -y; then
                    echo "✅ 阿里云K8S仓库配置成功"
                    exit 0
                else
                    echo "❌ 阿里云K8S仓库更新失败"
                    rm -f /etc/apt/sources.list.d/kubernetes.list /etc/apt/keyrings/kubernetes.gpg
                fi
            fi
            
            # 2. 尝试新的K8S官方仓库
            echo "尝试新的K8S官方仓库..."
            if curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg; then
                echo "新官方GPG密钥安装成功"
                chmod a+r /etc/apt/keyrings/kubernetes.gpg
                echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
                
                echo "测试新官方仓库更新..."
                if apt-get update -y; then
                    echo "✅ 新官方K8S仓库配置成功"
                    exit 0
                else
                    echo "❌ 新官方K8S仓库更新失败"
                    rm -f /etc/apt/sources.list.d/kubernetes.list /etc/apt/keyrings/kubernetes.gpg
                fi
            fi
            
            # 3. 尝试旧的K8S官方仓库
            echo "尝试旧的K8S官方仓库..."
            if curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg; then
                echo "旧官方GPG密钥安装成功"
                chmod a+r /etc/apt/keyrings/kubernetes.gpg
                echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://packages.cloud.google.com/apt/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
                
                echo "测试旧官方仓库更新..."
                if apt-get update -y; then
                    echo "✅ 旧官方K8S仓库配置成功"
                    exit 0
                else
                    echo "❌ 旧官方K8S仓库更新失败"
                    rm -f /etc/apt/sources.list.d/kubernetes.list /etc/apt/keyrings/kubernetes.gpg
                fi
            fi
            
            # 4. 使用系统默认包
            echo "所有外部仓库都失败，使用系统默认包..."
            apt-get update -y
            
            # 检查系统默认包是否可用
            if apt-cache search kubelet | grep -q kubelet; then
                echo "✅ 系统默认K8S包可用"
            else
                echo "❌ 系统默认K8S包不可用"
                exit 1
            fi
        '
        
        if execute_remote_command "$ip" "$fix_script"; then
            success "$vm_name K8S仓库修复成功"
        else
            error "$vm_name K8S仓库修复失败"
        fi
    done
    
    success "所有节点K8S仓库修复完成"
}

automation_ops() {
    log "自动化运维功能..."
    
    echo -e "${YELLOW}请选择自动化运维选项：${NC}"
    echo -e "  ${CYAN}1.${NC} 设置定时健康检查"
    echo -e "  ${CYAN}2.${NC} 设置定时备份"
    echo -e "  ${CYAN}3.${NC} 设置资源监控报警"
    echo -e "  ${CYAN}4.${NC} 查看定时任务状态"
    echo -e "  ${CYAN}5.${NC} 清理定时任务"
    echo -e "  ${CYAN}0.${NC} 返回主菜单"
    
    read -p "请选择 [0-5]: " auto_choice
    
    case $auto_choice in
        1)
            setup_health_check_cron
            ;;
        2)
            setup_backup_cron
            ;;
        3)
            setup_monitoring_alerts
            ;;
        4)
            show_cron_status
            ;;
        5)
            cleanup_cron_jobs
            ;;
        0)
    return 0
            ;;
        *)
            warn "无效选择"
            ;;
    esac
}

# 设置定时健康检查
setup_health_check_cron() {
    log "设置定时健康检查..."
    
    echo -e "${YELLOW}选择健康检查频率：${NC}"
    echo -e "  ${CYAN}1.${NC} 每小时检查一次"
    echo -e "  ${CYAN}2.${NC} 每4小时检查一次"
    echo -e "  ${CYAN}3.${NC} 每天检查一次"
    echo -e "  ${CYAN}4.${NC} 自定义频率"
    
    read -p "请选择 [1-4]: " freq_choice
    
    local cron_schedule=""
    case $freq_choice in
        1)
            cron_schedule="0 * * * *"
            ;;
        2)
            cron_schedule="0 */4 * * *"
            ;;
        3)
            cron_schedule="0 2 * * *"
            ;;
        4)
            read -p "请输入cron表达式（例如：0 */6 * * *）: " cron_schedule
            ;;
        *)
            warn "无效选择"
        return 1
            ;;
    esac
    
    # 创建健康检查脚本
    local health_script="/usr/local/bin/k8s-health-check.sh"
    cat > "$health_script" << 'EOF'
#!/bin/bash
# K8S集群健康检查脚本

LOGFILE="/var/log/k8s-health-check.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# 执行健康检查
log "开始集群健康检查..."
cd /root
./one-click-pve-k8s.sh 21 >> "$LOGFILE" 2>&1

# 检查结果并发送通知（如果配置了）
if [[ -f "/etc/k8s-alert-config" ]]; then
    source /etc/k8s-alert-config
    if [[ -n "$WEBHOOK_URL" ]]; then
        # 发送Webhook通知
        curl -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"K8S集群健康检查完成，详情请查看日志: $LOGFILE\"}" \
            2>/dev/null || true
    fi
fi

log "健康检查完成"
EOF
    
    chmod +x "$health_script"
    
    # 添加到crontab
    (crontab -l 2>/dev/null | grep -v "k8s-health-check"; echo "$cron_schedule $health_script") | crontab -
    
    success "定时健康检查设置完成"
    echo -e "${CYAN}检查频率: $cron_schedule${NC}"
    echo -e "${CYAN}日志文件: /var/log/k8s-health-check.log${NC}"
}

# 设置定时备份
setup_backup_cron() {
    log "设置定时备份..."
    
    echo -e "${YELLOW}选择备份频率：${NC}"
    echo -e "  ${CYAN}1.${NC} 每天备份一次"
    echo -e "  ${CYAN}2.${NC} 每周备份一次"
    echo -e "  ${CYAN}3.${NC} 每月备份一次"
    echo -e "  ${CYAN}4.${NC} 自定义频率"
    
    read -p "请选择 [1-4]: " backup_choice
    
    local cron_schedule=""
    case $backup_choice in
        1)
            cron_schedule="0 3 * * *"
            ;;
        2)
            cron_schedule="0 3 * * 0"
            ;;
        3)
            cron_schedule="0 3 1 * *"
            ;;
        4)
            read -p "请输入cron表达式: " cron_schedule
            ;;
        *)
            warn "无效选择"
        return 1
            ;;
    esac
    
    # 创建备份脚本
    local backup_script="/usr/local/bin/k8s-backup.sh"
    cat > "$backup_script" << 'EOF'
#!/bin/bash
# K8S集群备份脚本

LOGFILE="/var/log/k8s-backup.log"
BACKUP_DIR="/var/backups/k8s"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# 创建备份目录
mkdir -p "$BACKUP_DIR"

# 执行备份
log "开始集群备份..."
cd /root
./one-click-pve-k8s.sh 19 >> "$LOGFILE" 2>&1

# 清理旧备份（保留最近7个）
find "$BACKUP_DIR" -name "k8s-backup-*" -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null || true

log "备份完成"
EOF
    
    chmod +x "$backup_script"
    
    # 添加到crontab
    (crontab -l 2>/dev/null | grep -v "k8s-backup"; echo "$cron_schedule $backup_script") | crontab -
    
    success "定时备份设置完成"
    echo -e "${CYAN}备份频率: $cron_schedule${NC}"
    echo -e "${CYAN}备份目录: /var/backups/k8s${NC}"
    echo -e "${CYAN}日志文件: /var/log/k8s-backup.log${NC}"
}

# 设置监控报警
setup_monitoring_alerts() {
    log "设置监控报警..."
    
    read -p "请输入Webhook URL（用于发送报警通知）: " webhook_url
    read -p "请输入报警阈值 - CPU使用率(%) [默认: 80]: " cpu_threshold
    read -p "请输入报警阈值 - 内存使用率(%) [默认: 80]: " mem_threshold
    read -p "请输入报警阈值 - 磁盘使用率(%) [默认: 80]: " disk_threshold
    
    cpu_threshold=${cpu_threshold:-80}
    mem_threshold=${mem_threshold:-80}
    disk_threshold=${disk_threshold:-80}
    
    # 创建报警配置文件
    cat > "/etc/k8s-alert-config" << EOF
# K8S监控报警配置
WEBHOOK_URL="$webhook_url"
CPU_THRESHOLD=$cpu_threshold
MEM_THRESHOLD=$mem_threshold
DISK_THRESHOLD=$disk_threshold
EOF
    
    # 创建监控脚本
    local monitor_script="/usr/local/bin/k8s-monitor.sh"
    cat > "$monitor_script" << EOF
#!/bin/bash
# K8S集群监控脚本

source /etc/k8s-alert-config

LOGFILE="/var/log/k8s-monitor.log"
CLOUDINIT_PASS="$CLOUDINIT_PASS"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# 发送报警
send_alert() {
    local message="$1"
    log "发送报警: $message"
    
    if [[ -n "$WEBHOOK_URL" ]]; then
        curl -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"🚨 K8S集群报警: $message\"}" \
            2>/dev/null || log "报警发送失败"
    fi
}

# 检查资源使用率
check_resources() {
    local all_ips=(\$(get_all_ips))
    
    for ip in "${all_ips[@]}"; do
        # 检查CPU使用率
        local cpu_usage=$(sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no root@$ip \
            "top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\([0-9.]*\)%* id.*/\1/' | awk '{print 100 - \$1}'" 2>/dev/null | cut -d. -f1)
        
        if [[ -n "$cpu_usage" && "$cpu_usage" -gt "$CPU_THRESHOLD" ]]; then
            send_alert "节点 $ip CPU使用率过高: ${cpu_usage}%"
        fi
        
        # 检查内存使用率
        local mem_usage=$(sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no root@$ip \
            "free | grep Mem | awk '{printf \"%.0f\", \$3/\$2 * 100}'" 2>/dev/null)
        
        if [[ -n "$mem_usage" && "$mem_usage" -gt "$MEM_THRESHOLD" ]]; then
            send_alert "节点 $ip 内存使用率过高: ${mem_usage}%"
        fi
        
        # 检查磁盘使用率
        local disk_usage=$(sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no root@$ip \
            "df / | tail -1 | awk '{print \$5}' | sed 's/%//'" 2>/dev/null)
        
        if [[ -n "$disk_usage" && "$disk_usage" -gt "$DISK_THRESHOLD" ]]; then
            send_alert "节点 $ip 磁盘使用率过高: ${disk_usage}%"
        fi
    done
}

log "开始监控检查..."
check_resources
log "监控检查完成"
EOF
    
    chmod +x "$monitor_script"
    
    # 添加到crontab（每5分钟检查一次）
    (crontab -l 2>/dev/null | grep -v "k8s-monitor"; echo "*/5 * * * * $monitor_script") | crontab -
    
    success "监控报警设置完成"
    echo -e "${CYAN}检查频率: 每5分钟${NC}"
    echo -e "${CYAN}CPU阈值: ${cpu_threshold}%${NC}"
    echo -e "${CYAN}内存阈值: ${mem_threshold}%${NC}"
    echo -e "${CYAN}磁盘阈值: ${disk_threshold}%${NC}"
    echo -e "${CYAN}Webhook URL: $webhook_url${NC}"
}

# 查看定时任务状态
show_cron_status() {
    log "查看定时任务状态..."
    
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                     定时任务状态                             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${YELLOW}当前定时任务：${NC}"
    crontab -l 2>/dev/null | grep -E "(k8s-health-check|k8s-backup|k8s-monitor)" || echo "没有K8S相关的定时任务"
    echo ""
    
    echo -e "${YELLOW}脚本文件状态：${NC}"
    for script in "/usr/local/bin/k8s-health-check.sh" "/usr/local/bin/k8s-backup.sh" "/usr/local/bin/k8s-monitor.sh"; do
        if [[ -f "$script" ]]; then
            echo -e "  ✓ $script 存在"
        else
            echo -e "  ✗ $script 不存在"
        fi
    done
    echo ""
    
    echo -e "${YELLOW}配置文件状态：${NC}"
    if [[ -f "/etc/k8s-alert-config" ]]; then
        echo -e "  ✓ /etc/k8s-alert-config 存在"
        echo -e "  配置内容："
        cat /etc/k8s-alert-config | sed 's/^/    /'
    else
        echo -e "  ✗ /etc/k8s-alert-config 不存在"
    fi
    echo ""
    
    echo -e "${YELLOW}日志文件状态：${NC}"
    for logfile in "/var/log/k8s-health-check.log" "/var/log/k8s-backup.log" "/var/log/k8s-monitor.log"; do
        if [[ -f "$logfile" ]]; then
            local size=$(du -h "$logfile" | cut -f1)
            echo -e "  ✓ $logfile ($size)"
        else
            echo -e "  - $logfile 不存在"
        fi
    done
}

# 清理定时任务
cleanup_cron_jobs() {
    log "清理定时任务..."
    
    echo -e "${YELLOW}将清理以下内容：${NC}"
    echo -e "  - 所有K8S相关的定时任务"
    echo -e "  - 自动化脚本文件"
    echo -e "  - 配置文件"
    echo -e "  - 日志文件"
    echo ""
    
    read -p "确认清理？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # 清理定时任务
        crontab -l 2>/dev/null | grep -v -E "(k8s-health-check|k8s-backup|k8s-monitor)" | crontab -
        
        # 清理脚本文件
        rm -f /usr/local/bin/k8s-health-check.sh
        rm -f /usr/local/bin/k8s-backup.sh
        rm -f /usr/local/bin/k8s-monitor.sh
        
        # 清理配置文件
        rm -f /etc/k8s-alert-config
        
        # 清理日志文件
        rm -f /var/log/k8s-health-check.log
        rm -f /var/log/k8s-backup.log
        rm -f /var/log/k8s-monitor.log
        
        success "定时任务清理完成"
    else
        log "取消清理操作"
    fi
}

# ==========================================
# 状态检查
# ==========================================
check_status() {
    local master_ip=$(get_master_ip)
    log "检查集群状态..."
    
    execute_remote_command "$master_ip" '
        echo "=== 节点状态 ==="
        kubectl get nodes -o wide
        
        echo "=== Pod状态 ==="
        kubectl get pods --all-namespaces
        
        echo "=== KubeSphere状态 ==="
        kubectl get pods -n kubesphere-system
        
        echo "=== 集群信息 ==="
        kubectl cluster-info
    '
}

# ==========================================
# 清理资源
# ==========================================
cleanup_all() {
    log "清理所有资源..."
    
    for vm_id in "${!VM_CONFIGS[@]}"; do
        local vm_name=$(parse_vm_config "$vm_id" "name")
        log "删除虚拟机: $vm_name (ID: $vm_id)"
        qm stop "$vm_id" 2>/dev/null || true
        sleep 2
        qm destroy "$vm_id" 2>/dev/null || true
    done
    
    rm -f /var/lib/vz/snippets/user-data-k8s-*.yml
    success "资源清理完成"
}

# ==========================================
# 现代化用户界面
# ==========================================

# 显示系统状态
show_system_status() {
    # 兼容 macOS 和 Linux
    local cpu_usage="N/A"
    local memory_usage="N/A"
    local disk_usage="N/A"
    local load_avg="N/A"
    
    # CPU 使用率 (兼容不同系统)
    if command -v top >/dev/null 2>&1; then
        if [[ "$(uname)" == "Darwin" ]]; then
            # macOS
            cpu_usage=$(top -l 1 -n 0 | grep "CPU usage" | awk '{print $3}' | cut -d'%' -f1 2>/dev/null || echo "N/A")
        else
            # Linux
            cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo "N/A")
        fi
    fi
    
    # 内存使用率 (兼容不同系统)
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS
        memory_usage=$(vm_stat | awk '/Pages free:/ {free=$3} /Pages active:/ {active=$3} /Pages inactive:/ {inactive=$3} /Pages speculative:/ {spec=$3} /Pages wired down:/ {wired=$4} END {total=free+active+inactive+spec+wired; used=active+inactive+wired; printf "%.1f", used/total*100}' 2>/dev/null || echo "N/A")
    elif command -v free >/dev/null 2>&1; then
        # Linux
        memory_usage=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100.0}' 2>/dev/null || echo "N/A")
    fi
    
    # 磁盘使用率
    disk_usage=$(df / | tail -1 | awk '{print $5}' | cut -d'%' -f1 2>/dev/null || echo "N/A")
    
    # 负载平均值
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | cut -d',' -f1 | xargs 2>/dev/null || echo "N/A")
    
    echo -e "${BLUE}┌─ 系统状态 ─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│${NC} CPU: ${cpu_usage}%  内存: ${memory_usage}%  磁盘: ${disk_usage}%  负载: ${load_avg}      ${BLUE}│${NC}"
    echo -e "${BLUE}└────────────────────────────────────────────────────────────────────┘${NC}"
}

# 显示集群状态
show_cluster_status() {
    local master_ip=$(get_master_ip 2>/dev/null || echo "N/A")
    local cluster_status="未知"
    local node_count="N/A"
    local pod_count="N/A"
    
    if [[ "$master_ip" != "N/A" ]] && execute_remote_command "$master_ip" "kubectl get nodes >/dev/null 2>&1"; then
        cluster_status="运行中"
        node_count=$(execute_remote_command "$master_ip" "kubectl get nodes --no-headers | wc -l" 2>/dev/null || echo "N/A")
        pod_count=$(execute_remote_command "$master_ip" "kubectl get pods --all-namespaces --no-headers | wc -l" 2>/dev/null || echo "N/A")
    else
        cluster_status="未部署"
    fi
    
    echo -e "${GREEN}┌─ 集群状态 ─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}│${NC} 状态: ${cluster_status}  节点数: ${node_count}  Pod数: ${pod_count}  Master: ${master_ip}  ${GREEN}│${NC}"
    echo -e "${GREEN}└────────────────────────────────────────────────────────────────────┘${NC}"
}

# 现代化横幅
show_banner() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                      ║"
    echo "║    🚀 PVE K8S + KubeSphere 智能部署工具 v${SCRIPT_VERSION}                     ║"
    echo "║                                                                      ║"
    echo "║    📋 ${SCRIPT_DESCRIPTION}                          ║"
    echo "║    👨‍💻 作者: ${SCRIPT_AUTHOR}                                            ║"
    echo "║                                                                      ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    # 显示系统和集群状态
    show_system_status
    show_cluster_status
    echo ""
}

# 交互式菜单选择
show_interactive_menu() {
    local categories=(
        "🚀 部署功能"
        "🔧 修复功能"
        "🔍 诊断功能"
        "⚙️ 高级功能"
        "📊 管理功能"
        "❌ 退出"
    )
    
    echo -e "${BOLD}${YELLOW}┌─ 主菜单 ─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${YELLOW}│${NC} 请选择功能分类：                                                   ${BOLD}${YELLOW}│${NC}"
    echo -e "${BOLD}${YELLOW}└──────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    for i in "${!categories[@]}"; do
        echo -e "  ${CYAN}$((i+1)).${NC} ${categories[$i]}"
    done
    echo ""
    
    read -p "请选择分类 [1-6]: " category_choice
    
    case $category_choice in
        1) show_deploy_menu ;;
        2) show_fix_menu ;;
        3) show_diagnose_menu ;;
        4) show_advanced_menu ;;
        5) show_manage_menu ;;
        6) return 1 ;;
        *) 
            log_warn "无效选择，请重新输入"
            return 2
            ;;
    esac
}

# 部署功能菜单
show_deploy_menu() {
    echo -e "${BOLD}${GREEN}┌─ 🚀 部署功能 ─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${GREEN}│${NC} 选择部署操作：                                                     ${BOLD}${GREEN}│${NC}"
    echo -e "${BOLD}${GREEN}└──────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${CYAN}1.${NC} 🎯 一键全自动部署（推荐）"
    echo -e "  ${CYAN}2.${NC} 💿 下载云镜像"
    echo -e "  ${CYAN}3.${NC} 🖥️  创建虚拟机"
    echo -e "  ${CYAN}4.${NC} ☸️  部署K8S集群"
    echo -e "  ${CYAN}5.${NC} 🌐 部署KubeSphere"
    echo -e "  ${CYAN}0.${NC} 🔙 返回主菜单"
    echo ""
    
    read -p "请选择操作 [0-5]: " deploy_choice
    return $deploy_choice
}

# 修复功能菜单
show_fix_menu() {
    echo -e "${BOLD}${YELLOW}┌─ 🔧 修复功能 ─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${YELLOW}│${NC} 选择修复操作：                                                     ${BOLD}${YELLOW}│${NC}"
    echo -e "${BOLD}${YELLOW}└──────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${CYAN}1.${NC} 🐳 修复Docker和K8S安装"
    echo -e "  ${CYAN}2.${NC} ☸️  修复K8S集群"
    echo -e "  ${CYAN}3.${NC} 🌐 修复网络连接"
    echo -e "  ${CYAN}4.${NC} 🔑 修复SSH配置"
    echo -e "  ${CYAN}5.${NC} 🔧 修复K8S仓库问题"
    echo -e "  ${CYAN}9.${NC} 🛠️  一键修复所有问题"
    echo -e "  ${CYAN}0.${NC} 🔙 返回主菜单"
    echo ""
    
    read -p "请选择操作 [0-9]: " fix_choice
    return $fix_choice
}

# 诊断功能菜单
show_diagnose_menu() {
    echo -e "${BOLD}${BLUE}┌─ 🔍 诊断功能 ─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${BLUE}│${NC} 选择诊断操作：                                                     ${BOLD}${BLUE}│${NC}"
    echo -e "${BOLD}${BLUE}└──────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${CYAN}1.${NC} 🔍 系统诊断"
    echo -e "  ${CYAN}2.${NC} 📊 检查集群状态"
    echo -e "  ${CYAN}3.${NC} ❤️  集群健康检查"
    echo -e "  ${CYAN}4.${NC} 📋 查看系统日志"
    echo -e "  ${CYAN}5.${NC} 📄 生成故障报告"
    echo -e "  ${CYAN}6.${NC} 📖 快速修复手册"
    echo -e "  ${CYAN}0.${NC} 🔙 返回主菜单"
    echo ""
    
    read -p "请选择操作 [0-6]: " diagnose_choice
    return $diagnose_choice
}

# 高级功能菜单
show_advanced_menu() {
    echo -e "${BOLD}${PURPLE}┌─ ⚙️ 高级功能 ─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${PURPLE}│${NC} 选择高级操作：                                                     ${BOLD}${PURPLE}│${NC}"
    echo -e "${BOLD}${PURPLE}└──────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${CYAN}1.${NC} 📈 性能监控"
    echo -e "  ${CYAN}2.${NC} 💾 备份集群配置"
    echo -e "  ${CYAN}3.${NC} ⚙️  高级配置选项"
    echo -e "  ${CYAN}4.${NC} 🤖 自动化运维"
    echo -e "  ${CYAN}0.${NC} 🔙 返回主菜单"
    echo ""
    
    read -p "请选择操作 [0-4]: " advanced_choice
    return $advanced_choice
}

# 管理功能菜单
show_manage_menu() {
    echo -e "${BOLD}${RED}┌─ 📊 管理功能 ─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${RED}│${NC} 选择管理操作：                                                     ${BOLD}${RED}│${NC}"
    echo -e "${BOLD}${RED}└──────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${CYAN}1.${NC} 🔄 强制重建集群"
    echo -e "  ${CYAN}2.${NC} 🗑️  清理所有资源"
    echo -e "  ${CYAN}0.${NC} 🔙 返回主菜单"
    echo ""
    
    read -p "请选择操作 [0-2]: " manage_choice
    return $manage_choice
}

# 传统菜单（兼容模式）
show_menu() {
    echo -e "${BOLD}${YELLOW}┌─ 传统菜单模式 ───────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${YELLOW}│${NC} 直接输入功能编号：                                                 ${BOLD}${YELLOW}│${NC}"
    echo -e "${BOLD}${YELLOW}└──────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${GREEN}🚀 部署功能：${NC}"
    echo -e "  ${CYAN}1.${NC} 一键全自动部署（推荐）  ${CYAN}2.${NC} 下载云镜像      ${CYAN}3.${NC} 创建虚拟机"
    echo -e "  ${CYAN}4.${NC} 部署K8S集群            ${CYAN}5.${NC} 部署KubeSphere"
    echo ""
    echo -e "${YELLOW}🔧 修复功能：${NC}"
    echo -e "  ${CYAN}6.${NC} 修复Docker/K8S安装     ${CYAN}7.${NC} 修复K8S集群     ${CYAN}8.${NC} 修复网络连接"
    echo -e "  ${CYAN}9.${NC} 修复SSH配置           ${CYAN}12.${NC} 一键修复所有    ${CYAN}23.${NC} 修复K8S仓库"
    echo ""
    echo -e "${BLUE}🔍 诊断功能：${NC}"
    echo -e "  ${CYAN}10.${NC} 系统诊断              ${CYAN}11.${NC} 检查集群状态    ${CYAN}21.${NC} 集群健康检查"
    echo -e "  ${CYAN}15.${NC} 查看系统日志          ${CYAN}16.${NC} 生成故障报告    ${CYAN}17.${NC} 快速修复手册"
    echo ""
    echo -e "${PURPLE}⚙️ 高级功能：${NC}"
    echo -e "  ${CYAN}18.${NC} 性能监控              ${CYAN}19.${NC} 备份集群配置    ${CYAN}20.${NC} 高级配置选项"
    echo -e "  ${CYAN}22.${NC} 自动化运维"
    echo ""
    echo -e "${RED}📊 管理功能：${NC}"
    echo -e "  ${CYAN}13.${NC} 强制重建集群          ${CYAN}14.${NC} 清理所有资源    ${CYAN}0.${NC} 退出"
    echo ""
    echo -e "${BOLD}${CYAN}💡 提示：输入 'i' 进入交互模式，'h' 查看帮助${NC}"
    echo -e "${YELLOW}──────────────────────────────────────────────────────────────────────${NC}"
}

# ==========================================
# 智能主程序
# ==========================================

# 显示帮助信息
show_help() {
    echo -e "${BOLD}${CYAN}┌─ 帮助信息 ───────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${CYAN}│${NC} 使用方法：                                                         ${BOLD}${CYAN}│${NC}"
    echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${GREEN}命令行参数：${NC}"
    echo -e "  ${CYAN}./one-click-pve-k8s.sh${NC}           # 进入交互模式"
    echo -e "  ${CYAN}./one-click-pve-k8s.sh 1${NC}         # 直接执行一键部署"
    echo -e "  ${CYAN}./one-click-pve-k8s.sh --help${NC}    # 显示帮助信息"
    echo -e "  ${CYAN}./one-click-pve-k8s.sh --version${NC} # 显示版本信息"
    echo ""
    echo -e "${GREEN}环境变量：${NC}"
    echo -e "  ${CYAN}DEBUG=true${NC}                      # 启用调试模式"
    echo -e "  ${CYAN}LOG_LEVEL=DEBUG${NC}                 # 设置日志级别"
    echo -e "  ${CYAN}K8S_VERSION=v1.29.0${NC}             # 指定K8S版本"
    echo -e "  ${CYAN}DOCKER_VERSION=24.0.8${NC}           # 指定Docker版本"
    echo ""
    echo -e "${GREEN}快捷键：${NC}"
    echo -e "  ${CYAN}Ctrl+C${NC}                          # 安全退出"
    echo -e "  ${CYAN}i${NC}                               # 交互模式"
    echo -e "  ${CYAN}h${NC}                               # 显示帮助"
    echo ""
}

# 处理命令行参数
handle_arguments() {
    case "${1:-}" in
        --help|-h)
            show_help
            exit 0
            ;;
        --version|-v)
            echo -e "${BOLD}${SCRIPT_NAME} v${SCRIPT_VERSION}${NC}"
            echo -e "作者: ${SCRIPT_AUTHOR}"
            echo -e "描述: ${SCRIPT_DESCRIPTION}"
            exit 0
            ;;
        --debug|-d)
            export DEBUG=true
            export LOG_LEVEL=DEBUG
            log_info "调试模式已启用"
            ;;
        [1-9]|[1-2][0-9])
            # 直接执行指定功能
            execute_function "$1"
            exit $?
            ;;
        "")
            # 无参数，进入交互模式
            return 0
            ;;
        *)
            log_error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
}

# 执行指定功能
execute_function() {
    local func_id="$1"
    
    log_audit "EXECUTE_FUNCTION id=$func_id"
    
    case $func_id in
        1) measure_performance "full_deploy" full_auto_deploy ;;
        2) measure_performance "download_image" download_cloud_image ;;
        3) measure_performance "create_vms" create_all_vms && wait_for_all_vms ;;
        4) measure_performance "deploy_k8s" deploy_k8s ;;
        5) measure_performance "deploy_kubesphere" deploy_kubesphere ;;
        6) measure_performance "fix_docker_k8s" fix_docker_k8s ;;
        7) measure_performance "fix_k8s_cluster" fix_k8s_cluster ;;
        8) measure_performance "fix_network" fix_network_connectivity ;;
        9) measure_performance "fix_ssh" fix_all_ssh_configs ;;
        10) measure_performance "diagnose_system" diagnose_system ;;
        11) measure_performance "check_status" check_status ;;
        12) measure_performance "fix_all_issues" fix_all_issues ;;
        13) measure_performance "rebuild_cluster" rebuild_cluster ;;
        14) measure_performance "cleanup_all" cleanup_all ;;
        15) measure_performance "view_logs" view_logs ;;
        16) measure_performance "generate_report" generate_troubleshooting_report ;;
        17) measure_performance "show_guide" show_quick_fix_guide ;;
        18) measure_performance "monitor_performance" monitor_cluster_performance ;;
        19) measure_performance "backup_config" backup_cluster_config ;;
        20) measure_performance "advanced_config" advanced_config ;;
        21) measure_performance "health_check" cluster_health_check ;;
        22) measure_performance "automation_ops" automation_ops ;;
        23) measure_performance "fix_k8s_repository" fix_k8s_repository ;;
        *) 
            log_error "未知功能ID: $func_id"
            return 1
            ;;
    esac
}

# 一键全自动部署
full_auto_deploy() {
    log_info "开始一键全自动部署..."
    log_audit "START_FULL_DEPLOY"
    
    local steps=(
        "download_cloud_image:下载云镜像"
        "create_all_vms:创建虚拟机"
        "wait_for_all_vms:等待虚拟机启动"
        "deploy_k8s:部署K8S集群"
        "deploy_kubesphere:部署KubeSphere"
    )
    
    local total_steps=${#steps[@]}
    local current_step=0
    
    for step_info in "${steps[@]}"; do
        local step_func="${step_info%%:*}"
        local step_desc="${step_info##*:}"
        
        ((current_step++))
        
        log_info "[$current_step/$total_steps] $step_desc"
        
        if ! measure_performance "$step_func" "$step_func"; then
            log_error "步骤失败: $step_desc"
            log_audit "FULL_DEPLOY_FAILED step=$step_func"
            
            # 询问是否继续
            echo -e "${YELLOW}是否继续下一步？[y/N]: ${NC}"
            read -t 30 -n 1 continue_choice
            echo ""
            
            if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                log_info "用户选择停止部署"
                return 1
            fi
        fi
        
        # 显示进度
        local progress=$((current_step * 100 / total_steps))
        echo -e "${GREEN}进度: [$progress%] $step_desc 完成${NC}"
    done
    
    log_success "一键全自动部署完成！"
    log_audit "FULL_DEPLOY_SUCCESS"
    
    # 显示部署结果
    echo -e "${BOLD}${GREEN}┌─ 部署完成 ───────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${GREEN}│${NC} 🎉 恭喜！PVE K8S + KubeSphere 部署成功！                           ${BOLD}${GREEN}│${NC}"
    echo -e "${BOLD}${GREEN}└──────────────────────────────────────────────────────────────────────┘${NC}"
    
    # 显示访问信息
    show_access_info
}

# 显示访问信息
show_access_info() {
    local master_ip=$(get_master_ip 2>/dev/null || echo "N/A")
    
    if [[ "$master_ip" != "N/A" ]]; then
        echo -e "${CYAN}┌─ 访问信息 ───────────────────────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│${NC} KubeSphere 控制台: http://$master_ip:30880                          ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC} 默认用户名: admin                                                  ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC} 默认密码: P@88w0rd                                                 ${CYAN}│${NC}"
        echo -e "${CYAN}│${NC} SSH 连接: ssh root@$master_ip                                      ${CYAN}│${NC}"
        echo -e "${CYAN}└──────────────────────────────────────────────────────────────────────┘${NC}"
    fi
}

# 交互式主程序
interactive_main() {
    local use_interactive_menu=true
    
    while true; do
        show_banner
        
        if [[ "$use_interactive_menu" == "true" ]]; then
            if show_interactive_menu; then
                local menu_result=$?
                case $menu_result in
                    1) break ;; # 退出
                    2) continue ;; # 无效选择，重新显示
                esac
                
                # 处理子菜单选择
                handle_submenu_choice $?
            else
                break
            fi
        else
            show_menu
            
            read -p "请选择操作 [0-23] (或输入 'i' 进入交互模式, 'h' 查看帮助): " choice
            
            case "$choice" in
                i|I)
                    use_interactive_menu=true
                    continue
                    ;;
                h|H)
                    show_help
                    ;;
                0)
                    log_info "用户选择退出"
                    break
                    ;;
                [1-9]|[1-2][0-9])
                    execute_function "$choice"
                    ;;
                *)
                    log_warn "无效选择: $choice"
                    ;;
            esac
        fi
        
        # 显示操作结果提示
        echo ""
        echo -e "${YELLOW}按回车键继续，或输入 'q' 退出...${NC}"
        read -t 10 -n 1 continue_key
        echo ""
        
        if [[ "$continue_key" == "q" || "$continue_key" == "Q" ]]; then
            break
        fi
    done
}

# 处理子菜单选择
handle_submenu_choice() {
    local choice=$1
    
    case $choice in
        # 部署菜单
        1) execute_function 1 ;;  # 一键部署
        2) execute_function 2 ;;  # 下载云镜像
        3) execute_function 3 ;;  # 创建虚拟机
        4) execute_function 4 ;;  # 部署K8S
        5) execute_function 5 ;;  # 部署KubeSphere
        
        # 修复菜单
        6) execute_function 6 ;;  # 修复Docker/K8S
        7) execute_function 7 ;;  # 修复K8S集群
        8) execute_function 8 ;;  # 修复网络
        9) execute_function 9 ;;  # 修复SSH
        23) execute_function 23 ;; # 修复K8S仓库
        12) execute_function 12 ;; # 一键修复
        
        # 诊断菜单
        10) execute_function 10 ;; # 系统诊断
        11) execute_function 11 ;; # 检查状态
        21) execute_function 21 ;; # 健康检查
        15) execute_function 15 ;; # 查看日志
        16) execute_function 16 ;; # 生成报告
        17) execute_function 17 ;; # 修复手册
        
        # 高级菜单
        18) execute_function 18 ;; # 性能监控
        19) execute_function 19 ;; # 备份配置
        20) execute_function 20 ;; # 高级配置
        22) execute_function 22 ;; # 自动化运维
        
        # 管理菜单
        13) execute_function 13 ;; # 重建集群
        14) execute_function 14 ;; # 清理资源
        
        0) return 0 ;;  # 返回主菜单
        *) log_warn "无效选择: $choice" ;;
    esac
}

# 安全退出处理
cleanup_and_exit() {
    log_info "接收到退出信号，正在安全退出..."
    
    # 停止后台进程
    jobs -p | xargs -r kill 2>/dev/null || true
    
    # 清理临时文件
    [[ -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"/*.tmp 2>/dev/null || true
    
    # 保存审计日志
    log_audit "SCRIPT_EXIT"
    
    echo -e "${GREEN}感谢使用 ${SCRIPT_NAME:-PVE K8S部署工具}！${NC}"
    exit 0
}

# 主程序入口
main() {

    
    # 设置信号处理
    trap cleanup_and_exit SIGINT SIGTERM
    
    # 先处理命令行参数（帮助和版本信息不需要初始化系统）
    case "${1:-}" in
        --help|-h)
            show_help
            exit 0
            ;;
        --version|-v)
            echo -e "${BOLD}${SCRIPT_NAME} v${SCRIPT_VERSION}${NC}"
            echo -e "作者: ${SCRIPT_AUTHOR}"
            echo -e "描述: ${SCRIPT_DESCRIPTION}"
            exit 0
            ;;
    esac
    

    
    # 初始化系统
    init_system
    
    # 记录启动
    log_info "脚本启动 - $SCRIPT_NAME v$SCRIPT_VERSION"
    log_audit "SCRIPT_START version=$SCRIPT_VERSION user=$(whoami)"
    
    # 处理其他命令行参数
    handle_arguments "$@"
    
    # 检查环境
    if ! check_environment; then
        log_error "环境检查失败，脚本退出"
        exit 1
    fi
    
    # 进入交互模式
    interactive_main
    
    # 正常退出
    cleanup_and_exit
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
