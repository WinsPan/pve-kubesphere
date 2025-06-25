#!/bin/bash

# PVE KubeSphere 部署脚本 - 第二部分：Kubernetes安装
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
MASTER_IP="10.0.0.10"
WORKER_IPS=("10.0.0.11" "10.0.0.12")
ALL_NODES=("$MASTER_IP" "${WORKER_IPS[@]}")
K8S_VERSION="1.29.7"
CONTAINERD_VERSION="1.7.11"
CNI_VERSION="1.4.0"
CALICO_VERSION="3.27.0"

# 集群配置
CLUSTER_NAME="kubesphere-cluster"
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"

# 检查节点连接
check_node_connection() {
    log_step "检查所有节点连接..."
    
    for node_ip in "${ALL_NODES[@]}"; do
        log_info "检查节点: $node_ip"
        
        if ! ping -c 1 $node_ip > /dev/null 2>&1; then
            log_error "无法连接到节点 $node_ip"
            exit 1
        fi
        
        if ! ssh -o ConnectTimeout=10 -o BatchMode=yes root@$node_ip "echo '连接成功'" > /dev/null 2>&1; then
            log_error "无法SSH连接到节点 $node_ip"
            exit 1
        fi
        
        log_info "节点 $node_ip 连接正常"
    done
}

# 在所有节点上执行命令
run_on_all_nodes() {
    local cmd="$1"
    local description="$2"
    
    log_step "$description"
    
    for node_ip in "${ALL_NODES[@]}"; do
        log_info "在节点 $node_ip 上执行: $description"
        ssh root@$node_ip "$cmd"
    done
}

# 系统准备
prepare_system() {
    log_step "在所有节点上准备系统环境..."
    
    local prepare_cmd="
        # 更新系统
        apt update && apt upgrade -y
        
        # 安装必要软件包
        apt install -y curl wget gnupg2 software-properties-common apt-transport-https ca-certificates netcat git
        
        # 禁用swap
        swapoff -a
        sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
        
        # 加载必要的内核模块
        cat > /etc/modules-load.d/containerd.conf << 'EOF'
overlay
br_netfilter
EOF
        
        modprobe overlay
        modprobe br_netfilter
        
        # 设置内核参数
        cat > /etc/sysctl.d/99-kubernetes-cri.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
        
        sysctl --system
        
        # 设置主机名
        if [[ \"\$HOSTNAME\" == \"k8s-master\" ]]; then
            echo \"k8s-master\" > /etc/hostname
        elif [[ \"\$HOSTNAME\" == \"k8s-worker1\" ]]; then
            echo \"k8s-worker1\" > /etc/hostname
        elif [[ \"\$HOSTNAME\" == \"k8s-worker2\" ]]; then
            echo \"k8s-worker2\" > /etc/hostname
        fi
        
        # 配置hosts文件
        cat >> /etc/hosts << 'EOF'
10.0.0.10 k8s-master
10.0.0.11 k8s-worker1
10.0.0.12 k8s-worker2
EOF
    "
    
    run_on_all_nodes "$prepare_cmd" "系统准备"
}

# 安装containerd
install_containerd() {
    log_step "在所有节点上安装containerd..."
    
    local containerd_cmd="
        # 添加Docker GPG密钥
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        
        # 添加Docker仓库
        echo \"deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \$(lsb_release -cs) stable\" > /etc/apt/sources.list.d/docker.list
        
        # 更新包索引
        apt update
        
        # 安装containerd
        apt install -y containerd.io
        
        # 配置containerd
        mkdir -p /etc/containerd
        containerd config default > /etc/containerd/config.toml
        
        # 修改containerd配置以使用systemd cgroup驱动
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        
        # 重启containerd
        systemctl daemon-reload
        systemctl enable containerd
        systemctl restart containerd
        
        # 验证安装
        ctr version
    "
    
    run_on_all_nodes "$containerd_cmd" "安装containerd"
}

# 安装Kubernetes组件
install_kubernetes() {
    log_step "在所有节点上安装Kubernetes组件..."
    
    local k8s_cmd="
        # 添加Kubernetes GPG密钥
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        
        # 添加Kubernetes仓库
        echo \"deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /\" > /etc/apt/sources.list.d/kubernetes.list
        
        # 更新包索引
        apt update
        
        # 安装Kubernetes组件
        apt install -y kubelet=$K8S_VERSION-1.1 kubeadm=$K8S_VERSION-1.1 kubectl=$K8S_VERSION-1.1
        
        # 锁定版本
        apt-mark hold kubelet kubeadm kubectl
        
        # 启用kubelet
        systemctl enable kubelet
    "
    
    run_on_all_nodes "$k8s_cmd" "安装Kubernetes组件"
}

# 初始化主节点
init_master() {
    log_step "初始化Kubernetes主节点..."
    
    local init_cmd="
        # 初始化Kubernetes集群
        kubeadm init \\
            --pod-network-cidr=$POD_CIDR \\
            --service-cidr=$SERVICE_CIDR \\
            --apiserver-advertise-address=$MASTER_IP \\
            --kubernetes-version=v$K8S_VERSION \\
            --ignore-preflight-errors=all
        
        # 创建kubeconfig目录
        mkdir -p \$HOME/.kube
        
        # 复制kubeconfig文件
        cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config
        
        # 设置权限
        chown \$(id -u):\$(id -g) \$HOME/.kube/config
    "
    
    log_info "在主节点 $MASTER_IP 上初始化集群..."
    ssh root@$MASTER_IP "$init_cmd"
    
    # 获取join命令
    log_info "获取worker节点加入命令..."
    JOIN_CMD=$(ssh root@$MASTER_IP "kubeadm token create --print-join-command")
    log_info "Join命令: $JOIN_CMD"
    
    # 保存join命令到文件
    echo "$JOIN_CMD" > join-command.txt
}

# 安装Calico网络插件
install_calico() {
    log_step "安装Calico网络插件..."
    
    local calico_cmd="
        # 下载Calico清单
        wget https://raw.githubusercontent.com/projectcalico/calico/v$CALICO_VERSION/manifests/tigera-operator.yaml
        
        # 安装Calico
        kubectl apply -f tigera-operator.yaml
        
        # 下载Calico自定义资源
        wget https://raw.githubusercontent.com/projectcalico/calico/v$CALICO_VERSION/manifests/custom-resources.yaml
        
        # 修改POD_CIDR
        sed -i 's|cidr: 192.168.0.0/16|cidr: $POD_CIDR|g' custom-resources.yaml
        
        # 应用Calico配置
        kubectl apply -f custom-resources.yaml
        
        # 等待Calico就绪
        kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=300s
    "
    
    log_info "在主节点上安装Calico..."
    ssh root@$MASTER_IP "$calico_cmd"
}

# 加入worker节点
join_workers() {
    log_step "将worker节点加入集群..."
    
    if [ ! -f join-command.txt ]; then
        log_error "join-command.txt文件不存在，请先运行主节点初始化"
        exit 1
    fi
    
    JOIN_CMD=$(cat join-command.txt)
    
    for worker_ip in "${WORKER_IPS[@]}"; do
        log_info "将worker节点 $worker_ip 加入集群..."
        ssh root@$worker_ip "$JOIN_CMD"
    done
}

# 验证集群状态
verify_cluster() {
    log_step "验证集群状态..."
    
    local verify_cmd="
        # 检查节点状态
        kubectl get nodes
        
        # 检查pod状态
        kubectl get pods --all-namespaces
        
        # 检查集群信息
        kubectl cluster-info
        
        # 检查组件状态
        kubectl get componentstatuses
    "
    
    log_info "在主节点上验证集群状态..."
    ssh root@$MASTER_IP "$verify_cmd"
}

# 配置kubectl别名和自动补全
configure_kubectl() {
    log_step "配置kubectl..."
    
    local kubectl_cmd="
        # 安装bash-completion
        apt install -y bash-completion
        
        # 配置kubectl自动补全
        echo 'source <(kubectl completion bash)' >> ~/.bashrc
        echo 'alias k=kubectl' >> ~/.bashrc
        echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc
        
        # 重新加载bashrc
        source ~/.bashrc
    "
    
    run_on_all_nodes "$kubectl_cmd" "配置kubectl"
}

# 生成集群信息文件
generate_cluster_info() {
    log_step "生成集群信息文件..."
    
    cat > cluster-info.txt << EOF
# KubeSphere集群信息
# 生成时间: $(date)

## 集群配置
- 集群名称: $CLUSTER_NAME
- Kubernetes版本: v$K8S_VERSION
- Pod CIDR: $POD_CIDR
- Service CIDR: $SERVICE_CIDR

## 节点信息
- Master节点: $MASTER_IP
- Worker节点: ${WORKER_IPS[*]}

## 访问信息
- 主节点SSH: ssh root@$MASTER_IP
- 默认密码: kubesphere123

## 常用命令
- 查看节点: kubectl get nodes
- 查看pods: kubectl get pods --all-namespaces
- 查看服务: kubectl get services --all-namespaces
- 集群信息: kubectl cluster-info

## 下一步
运行 03-kubesphere-install.sh 安装KubeSphere
EOF
    
    log_info "集群信息文件已生成: cluster-info.txt"
}

# 主函数
main() {
    log_info "开始Kubernetes安装..."
    
    check_node_connection
    prepare_system
    install_containerd
    install_kubernetes
    init_master
    install_calico
    join_workers
    verify_cluster
    configure_kubectl
    generate_cluster_info
    
    log_info "Kubernetes安装完成！"
    log_info "集群信息："
    log_info "- Master节点: $MASTER_IP"
    log_info "- Worker节点: ${WORKER_IPS[*]}"
    log_info "- Kubernetes版本: v$K8S_VERSION"
    log_info ""
    log_info "下一步：运行 03-kubesphere-install.sh 安装KubeSphere"
}

# 执行主函数
main "$@" 