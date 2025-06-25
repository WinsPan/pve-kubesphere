#!/bin/bash

# PVE KubeSphere 快速部署脚本
# 一键下载并部署KubeSphere到PVE环境

set -e

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}🚀 PVE KubeSphere 快速部署脚本${NC}"
echo "=================================="

# 配置变量（请修改为您的GitHub仓库）
REPO="WinsPan/pve-kubesphere"
BRANCH="main"

# 创建临时目录
TEMP_DIR="kubesphere-temp-$(date +%s)"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

echo -e "${YELLOW}📥 正在下载部署脚本...${NC}"

# 下载核心脚本
curl -fsSL "https://raw.githubusercontent.com/$REPO/$BRANCH/deploy-all.sh" -o deploy-all.sh
curl -fsSL "https://raw.githubusercontent.com/$REPO/$BRANCH/01-pve-prepare.sh" -o 01-pve-prepare.sh
curl -fsSL "https://raw.githubusercontent.com/$REPO/$BRANCH/02-k8s-install.sh" -o 02-k8s-install.sh
curl -fsSL "https://raw.githubusercontent.com/$REPO/$BRANCH/03-kubesphere-install.sh" -o 03-kubesphere-install.sh

# 添加执行权限
chmod +x *.sh

echo -e "${GREEN}✅ 下载完成！${NC}"
echo ""
echo -e "${YELLOW}⚠️  部署前请确认：${NC}"
echo "1. PVE主机已准备就绪"
echo "2. 网络配置正确"
echo "3. 有足够的资源（至少24核48GB内存）"
echo ""
read -p "是否开始部署？(输入 'yes' 确认): " confirm

if [ "$confirm" = "yes" ]; then
    echo -e "${GREEN}🚀 开始部署...${NC}"
    ./deploy-all.sh
else
    echo -e "${YELLOW}部署已取消${NC}"
    exit 0
fi

# 清理临时文件
cd ..
rm -rf "$TEMP_DIR"

echo -e "${GREEN}🎉 部署完成！${NC}"
echo "访问地址: http://10.0.0.10:30880"
echo "用户名: admin"
echo "密码: P@88w0rd" 