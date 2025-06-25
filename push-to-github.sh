#!/bin/bash

# PVE KubeSphere 一键推送到GitHub脚本

set -e

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}🚀 PVE KubeSphere 一键推送到GitHub${NC}"
echo "=========================================="

# 检查Git状态
check_git_status() {
    echo -e "${BLUE}[STEP] 检查Git状态...${NC}"
    
    if ! git status &> /dev/null; then
        echo -e "${RED}[ERROR] 当前目录不是Git仓库${NC}"
        exit 1
    fi
    
    # 检查是否有未提交的更改
    if [ -n "$(git status --porcelain)" ]; then
        echo -e "${YELLOW}[WARN] 发现未提交的更改${NC}"
        git status --short
        echo ""
        read -p "是否提交这些更改？(y/n): " commit_changes
        
        if [ "$commit_changes" = "y" ] || [ "$commit_changes" = "Y" ]; then
            read -p "请输入提交信息: " commit_message
            if [ -z "$commit_message" ]; then
                commit_message="Update files"
            fi
            git add .
            git commit -m "$commit_message"
            echo -e "${GREEN}[INFO] 更改已提交${NC}"
        else
            echo -e "${YELLOW}[WARN] 跳过未提交的更改${NC}"
        fi
    else
        echo -e "${GREEN}[INFO] 工作区干净${NC}"
    fi
}

# 获取GitHub仓库信息
get_github_info() {
    echo -e "${BLUE}[STEP] 配置GitHub仓库...${NC}"
    
    # 检查是否已有远程仓库
    if git remote get-url origin &> /dev/null; then
        current_remote=$(git remote get-url origin)
        echo -e "${GREEN}[INFO] 当前远程仓库: $current_remote${NC}"
        
        read -p "是否使用现有远程仓库？(y/n): " use_existing
        if [ "$use_existing" = "y" ] || [ "$use_existing" = "Y" ]; then
            return 0
        fi
    fi
    
    # 获取GitHub用户名
    read -p "请输入您的GitHub用户名: " github_username
    if [ -z "$github_username" ]; then
        echo -e "${RED}[ERROR] GitHub用户名不能为空${NC}"
        exit 1
    fi
    
    # 获取仓库名称
    read -p "请输入仓库名称 (默认: pve-kubesphere): " repo_name
    if [ -z "$repo_name" ]; then
        repo_name="pve-kubesphere"
    fi
    
    # 选择协议
    echo "选择Git协议:"
    echo "1) HTTPS (推荐新手)"
    echo "2) SSH (需要配置SSH密钥)"
    read -p "请选择 (1/2): " protocol_choice
    
    case $protocol_choice in
        1)
            remote_url="https://github.com/$github_username/$repo_name.git"
            ;;
        2)
            remote_url="git@github.com:$github_username/$repo_name.git"
            ;;
        *)
            echo -e "${RED}[ERROR] 无效选择${NC}"
            exit 1
            ;;
    esac
    
    # 添加或更新远程仓库
    if git remote get-url origin &> /dev/null; then
        git remote set-url origin "$remote_url"
        echo -e "${GREEN}[INFO] 远程仓库已更新${NC}"
    else
        git remote add origin "$remote_url"
        echo -e "${GREEN}[INFO] 远程仓库已添加${NC}"
    fi
    
    # 保存仓库信息用于更新脚本
    GITHUB_REPO="$github_username/$repo_name"
}

# 更新脚本中的GitHub仓库地址
update_scripts() {
    echo -e "${BLUE}[STEP] 更新脚本中的GitHub地址...${NC}"
    
    if [ -n "$GITHUB_REPO" ]; then
        # 更新remote-deploy.sh
        if [ -f "remote-deploy.sh" ]; then
            sed -i.bak "s|GITHUB_REPO=\"[^\"]*\"|GITHUB_REPO=\"$GITHUB_REPO\"|" remote-deploy.sh
            echo -e "${GREEN}[INFO] 已更新 remote-deploy.sh${NC}"
        fi
        
        # 更新quick-deploy.sh
        if [ -f "quick-deploy.sh" ]; then
            sed -i.bak "s|REPO=\"[^\"]*\"|REPO=\"$GITHUB_REPO\"|" quick-deploy.sh
            echo -e "${GREEN}[INFO] 已更新 quick-deploy.sh${NC}"
        fi
        
        # 更新README.md
        if [ -f "README.md" ]; then
            sed -i.bak "s|your-username|$github_username|g" README.md
            echo -e "${GREEN}[INFO] 已更新 README.md${NC}"
        fi
        
        # 清理备份文件
        rm -f *.bak
    fi
}

# 推送到GitHub
push_to_github() {
    echo -e "${BLUE}[STEP] 推送到GitHub...${NC}"
    
    # 检查远程仓库连接
    echo -e "${YELLOW}[INFO] 测试远程仓库连接...${NC}"
    if ! git ls-remote origin &> /dev/null; then
        echo -e "${RED}[ERROR] 无法连接到远程仓库${NC}"
        echo -e "${YELLOW}[WARN] 请检查：${NC}"
        echo "  1. GitHub仓库是否存在"
        echo "  2. 网络连接是否正常"
        echo "  3. SSH密钥是否正确配置（如果使用SSH）"
        exit 1
    fi
    
    echo -e "${GREEN}[INFO] 远程仓库连接正常${NC}"
    
    # 推送代码
    echo -e "${YELLOW}[INFO] 正在推送代码...${NC}"
    if git push -u origin main; then
        echo -e "${GREEN}[SUCCESS] 代码推送成功！${NC}"
    else
        echo -e "${RED}[ERROR] 代码推送失败${NC}"
        exit 1
    fi
}

# 显示部署信息
show_deployment_info() {
    echo ""
    echo -e "${GREEN}🎉 推送完成！${NC}"
    echo "=========================================="
    echo ""
    echo "📋 仓库信息："
    echo "   GitHub地址: https://github.com/$GITHUB_REPO"
    echo "   分支: main"
    echo ""
    echo "🚀 远程部署命令："
    echo ""
    echo "完整版远程部署："
    echo "  curl -fsSL https://raw.githubusercontent.com/$GITHUB_REPO/main/remote-deploy.sh | bash"
    echo ""
    echo "快速版远程部署："
    echo "  curl -fsSL https://raw.githubusercontent.com/$GITHUB_REPO/main/quick-deploy.sh | bash"
    echo ""
    echo "📚 文档链接："
    echo "   README: https://github.com/$GITHUB_REPO/blob/main/README.md"
    echo "   快速开始: https://github.com/$GITHUB_REPO/blob/main/QUICK-START.md"
    echo ""
    echo "⚠️  注意事项："
    echo "   1. 确保GitHub仓库为公开仓库（如果希望他人使用）"
    echo "   2. 测试远程部署命令是否正常工作"
    echo "   3. 定期更新和维护代码"
    echo "=========================================="
}

# 测试远程部署
test_remote_deploy() {
    echo ""
    read -p "是否测试远程部署命令？(y/n): " test_deploy
    
    if [ "$test_deploy" = "y" ] || [ "$test_deploy" = "Y" ]; then
        echo -e "${BLUE}[STEP] 测试远程部署...${NC}"
        
        # 测试文件是否可访问
        test_url="https://raw.githubusercontent.com/$GITHUB_REPO/main/README.md"
        if curl -fsSL "$test_url" &> /dev/null; then
            echo -e "${GREEN}[SUCCESS] 远程文件访问正常${NC}"
        else
            echo -e "${YELLOW}[WARN] 远程文件暂时无法访问（可能需要等待几分钟）${NC}"
        fi
    fi
}

# 主函数
main() {
    echo -e "${GREEN}[INFO] 开始推送到GitHub...${NC}"
    echo ""
    
    # 检查Git状态
    check_git_status
    
    # 获取GitHub信息
    get_github_info
    
    # 更新脚本
    update_scripts
    
    # 提交更新（如果有）
    if [ -n "$(git status --porcelain)" ]; then
        git add .
        git commit -m "Update GitHub repository URLs"
        echo -e "${GREEN}[INFO] 配置更新已提交${NC}"
    fi
    
    # 推送到GitHub
    push_to_github
    
    # 显示部署信息
    show_deployment_info
    
    # 测试远程部署
    test_remote_deploy
    
    echo -e "${GREEN}[SUCCESS] 所有操作完成！${NC}"
}

# 显示帮助信息
show_help() {
    echo "PVE KubeSphere 一键推送到GitHub脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help     显示此帮助信息"
    echo ""
    echo "功能:"
    echo "  1. 检查Git状态"
    echo "  2. 配置GitHub仓库"
    echo "  3. 更新脚本中的GitHub地址"
    echo "  4. 推送代码到GitHub"
    echo "  5. 生成远程部署命令"
    echo ""
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR] 未知参数: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# 执行主函数
main "$@" 