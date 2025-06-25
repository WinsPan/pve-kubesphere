# GitHub 推送指南

本指南将帮助您将PVE KubeSphere部署脚本推送到GitHub，并设置远程一键部署。

## 📋 前置要求

1. **GitHub账户**: 确保您有一个GitHub账户
2. **Git配置**: 本地Git已正确配置
3. **SSH密钥**: 建议配置SSH密钥用于安全推送

## 🚀 推送步骤

### 1. 创建GitHub仓库

1. 登录GitHub
2. 点击右上角 "+" 按钮，选择 "New repository"
3. 填写仓库信息：
   - **Repository name**: `pve-kubesphere`
   - **Description**: `PVE KubeSphere 一键部署脚本`
   - **Visibility**: 选择 Public 或 Private
   - **不要**勾选 "Add a README file"（我们已经有了）
4. 点击 "Create repository"

### 2. 添加远程仓库

```bash
# 替换 YOUR_USERNAME 为您的GitHub用户名
git remote add origin https://github.com/YOUR_USERNAME/pve-kubesphere.git

# 或者使用SSH（推荐）
git remote add origin git@github.com:YOUR_USERNAME/pve-kubesphere.git
```

### 3. 推送代码

```bash
# 推送主分支
git push -u origin main

# 后续推送
git push
```

### 4. 验证推送

访问 `https://github.com/YOUR_USERNAME/pve-kubesphere` 确认代码已成功推送。

## 🔧 配置远程部署脚本

推送成功后，需要修改远程部署脚本中的仓库地址：

### 修改 remote-deploy.sh

```bash
# 编辑文件
vim remote-deploy.sh

# 找到这一行并修改
GITHUB_REPO="YOUR_USERNAME/pve-kubesphere"  # 修改为您的GitHub仓库
```

### 修改 quick-deploy.sh

```bash
# 编辑文件
vim quick-deploy.sh

# 找到这一行并修改
REPO="YOUR_USERNAME/pve-kubesphere"  # 修改为您的GitHub仓库
```

### 修改 README.md

```bash
# 编辑文件
vim README.md

# 修改所有GitHub链接
# 将 your-username 替换为您的GitHub用户名
```

## 📝 更新并推送修改

```bash
# 添加修改
git add .

# 提交修改
git commit -m "Update GitHub repository URLs"

# 推送到GitHub
git push
```

## 🌐 远程部署测试

推送完成后，可以测试远程部署功能：

### 完整版远程部署
```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/pve-kubesphere/main/remote-deploy.sh | bash
```

### 快速版远程部署
```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/pve-kubesphere/main/quick-deploy.sh | bash
```

## 🔒 安全建议

### 1. 使用SSH密钥

```bash
# 生成SSH密钥（如果还没有）
ssh-keygen -t ed25519 -C "your_email@example.com"

# 添加到SSH代理
ssh-add ~/.ssh/id_ed25519

# 复制公钥到GitHub
cat ~/.ssh/id_ed25519.pub
```

### 2. 配置Git用户信息

```bash
git config --global user.name "Your Name"
git config --global user.email "your_email@example.com"
```

### 3. 仓库安全设置

- 在GitHub仓库设置中启用 "Dependabot alerts"
- 定期更新依赖
- 使用GitHub Actions进行自动化测试

## 📊 仓库统计

推送成功后，您可以在GitHub上看到：

- **Stars**: 用户对项目的关注
- **Forks**: 其他用户的分支
- **Issues**: 问题反馈
- **Pull Requests**: 贡献代码

## 🤝 社区贡献

### 接受贡献

1. 在仓库设置中启用 "Issues"
2. 创建贡献指南 `CONTRIBUTING.md`
3. 设置代码审查流程

### 版本发布

```bash
# 创建标签
git tag -a v1.0.0 -m "Release version 1.0.0"

# 推送标签
git push origin v1.0.0
```

## 🔍 故障排除

### 常见问题

1. **推送被拒绝**
   ```bash
   # 强制推送（谨慎使用）
   git push -f origin main
   ```

2. **SSH连接失败**
   ```bash
   # 测试SSH连接
   ssh -T git@github.com
   ```

3. **权限问题**
   - 检查GitHub账户权限
   - 确认SSH密钥已添加到GitHub

### 获取帮助

- [GitHub帮助文档](https://help.github.com/)
- [Git官方文档](https://git-scm.com/doc)
- [GitHub CLI文档](https://cli.github.com/)

## 📈 后续维护

### 定期更新

```bash
# 拉取最新更改
git pull origin main

# 查看提交历史
git log --oneline
```

### 分支管理

```bash
# 创建功能分支
git checkout -b feature/new-feature

# 合并分支
git checkout main
git merge feature/new-feature
```

---

**注意**: 请确保在推送前仔细检查所有配置，特别是GitHub仓库地址。 