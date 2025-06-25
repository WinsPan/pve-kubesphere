#!/bin/bash

# 网络连接测试脚本
# 用于测试PVE主机的网络连接情况

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

# 测试基本网络连接
test_basic_connectivity() {
    log_step "测试基本网络连接..."
    
    # 测试ping
    if ping -c 3 8.8.8.8 > /dev/null 2>&1; then
        log_success "基本网络连接正常"
        return 0
    else
        log_error "基本网络连接失败"
        return 1
    fi
}

# 测试DNS解析
test_dns_resolution() {
    log_step "测试DNS解析..."
    
    # 测试DNS解析
    if nslookup download.proxmox.com > /dev/null 2>&1; then
        log_success "DNS解析正常"
        return 0
    else
        log_warn "DNS解析可能有问题"
        return 1
    fi
}

# 测试HTTPS连接
test_https_connectivity() {
    log_step "测试HTTPS连接..."
    
    # 测试多个HTTPS连接
    local urls=(
        "https://download.proxmox.com"
        "https://mirrors.ustc.edu.cn"
        "https://mirrors.tuna.tsinghua.edu.cn"
        "https://www.google.com"
    )
    
    local success_count=0
    for url in "${urls[@]}"; do
        log_info "测试连接: $url"
        if curl -s --connect-timeout 10 --max-time 30 "$url" > /dev/null 2>&1; then
            log_success "✓ $url 连接成功"
            ((success_count++))
        else
            log_warn "✗ $url 连接失败"
        fi
    done
    
    if [ $success_count -gt 0 ]; then
        log_success "HTTPS连接测试完成，$success_count/${#urls[@]} 个站点可访问"
        return 0
    else
        log_error "所有HTTPS连接都失败"
        return 1
    fi
}

# 测试下载功能
test_download() {
    log_step "测试下载功能..."
    
    # 测试小文件下载
    local test_urls=(
        "https://httpbin.org/bytes/1024"
        "https://www.google.com/favicon.ico"
    )
    
    local success_count=0
    for url in "${test_urls[@]}"; do
        log_info "测试下载: $url"
        if curl -s --connect-timeout 10 --max-time 30 -o /dev/null "$url"; then
            log_success "✓ $url 下载成功"
            ((success_count++))
        else
            log_warn "✗ $url 下载失败"
        fi
    done
    
    if [ $success_count -gt 0 ]; then
        log_success "下载测试完成，$success_count/${#test_urls[@]} 个文件可下载"
        return 0
    else
        log_error "所有下载测试都失败"
        return 1
    fi
}

# 检查代理设置
check_proxy_settings() {
    log_step "检查代理设置..."
    
    local proxy_vars=("http_proxy" "https_proxy" "HTTP_PROXY" "HTTPS_PROXY")
    local has_proxy=false
    
    for var in "${proxy_vars[@]}"; do
        if [ -n "${!var}" ]; then
            log_info "发现代理设置: $var=${!var}"
            has_proxy=true
        fi
    done
    
    if [ "$has_proxy" = true ]; then
        log_warn "检测到代理设置，可能影响网络连接"
        return 1
    else
        log_success "未检测到代理设置"
        return 0
    fi
}

# 检查防火墙设置
check_firewall() {
    log_step "检查防火墙状态..."
    
    # 检查iptables
    if command -v iptables > /dev/null 2>&1; then
        local rules_count=$(iptables -L | wc -l)
        log_info "iptables规则数量: $rules_count"
    fi
    
    # 检查ufw
    if command -v ufw > /dev/null 2>&1; then
        local ufw_status=$(ufw status 2>/dev/null | head -1)
        log_info "UFW状态: $ufw_status"
    fi
    
    log_info "防火墙检查完成"
}

# 生成网络诊断报告
generate_network_report() {
    log_step "生成网络诊断报告..."
    
    cat > network-report.txt << EOF
网络诊断报告
生成时间: $(date)

系统信息:
$(uname -a)

网络接口:
$(ip addr show)

路由表:
$(ip route show)

DNS配置:
$(cat /etc/resolv.conf 2>/dev/null || echo "无法读取DNS配置")

代理设置:
$(env | grep -i proxy || echo "未设置代理")

网络连接测试结果:
- 基本连接: $(test_basic_connectivity > /dev/null 2>&1 && echo "正常" || echo "失败")
- DNS解析: $(test_dns_resolution > /dev/null 2>&1 && echo "正常" || echo "失败")
- HTTPS连接: $(test_https_connectivity > /dev/null 2>&1 && echo "正常" || echo "失败")
- 下载功能: $(test_download > /dev/null 2>&1 && echo "正常" || echo "失败")

建议:
1. 如果基本连接失败，检查网络配置
2. 如果DNS解析失败，检查DNS服务器设置
3. 如果HTTPS连接失败，检查防火墙和代理设置
4. 如果下载功能失败，尝试使用不同的下载工具或镜像源
EOF
    
    log_success "网络诊断报告已生成: network-report.txt"
}

# 主函数
main() {
    echo "=========================================="
    echo "🌐 网络连接诊断工具"
    echo "=========================================="
    echo ""
    
    local overall_success=true
    
    # 执行各项测试
    test_basic_connectivity || overall_success=false
    echo ""
    
    test_dns_resolution || overall_success=false
    echo ""
    
    test_https_connectivity || overall_success=false
    echo ""
    
    test_download || overall_success=false
    echo ""
    
    check_proxy_settings
    echo ""
    
    check_firewall
    echo ""
    
    # 生成报告
    generate_network_report
    echo ""
    
    # 总结
    echo "=========================================="
    if [ "$overall_success" = true ]; then
        echo "✅ 网络连接测试完成，大部分功能正常"
        echo "建议：可以尝试运行PVE准备脚本"
    else
        echo "❌ 网络连接测试发现问题"
        echo "建议："
        echo "1. 检查网络配置和防火墙设置"
        echo "2. 尝试使用代理或VPN"
        echo "3. 手动下载Debian模板文件"
        echo "4. 查看 network-report.txt 获取详细信息"
    fi
    echo "=========================================="
}

# 执行主函数
main "$@" 