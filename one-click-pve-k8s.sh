#!/bin/bash

# ==========================================
# 一键PVE K8S+KubeSphere部署脚本 v3.0
# 作者: WinsPan
# 重构版本 - 精简高效
# ==========================================

set -euo pipefail

# ==========================================
# 全局配置
# ==========================================
readonly SCRIPT_VERSION="3.0"
readonly SCRIPT_NAME="PVE K8S+KubeSphere 部署工具"

# 颜色定义
readonly GREEN='\e[0;32m'
readonly YELLOW='\e[1;33m'
readonly RED='\e[0;31m'
readonly BLUE='\e[0;34m'
readonly CYAN='\e[0;36m'
readonly NC='\e[0m'

# 虚拟机配置
readonly STORAGE="local-lvm"
readonly BRIDGE="vmbr0"
readonly VM_IDS=(101 102 103)
readonly VM_NAMES=("k8s-master" "k8s-worker1" "k8s-worker2")
readonly VM_IPS=("10.0.0.10" "10.0.0.11" "10.0.0.12")
readonly VM_CORES=8
readonly VM_MEM=16384
readonly VM_DISK=300
readonly CLOUDINIT_USER="root"
readonly CLOUDINIT_PASS="kubesphere123"
readonly GATEWAY="10.0.0.1"
readonly DNS="10.0.0.1"

# 集群配置
readonly MASTER_IP="10.0.0.10"
readonly WORKER_IPS=("10.0.0.11" "10.0.0.12")

# 云镜像配置
readonly CLOUD_IMAGE_URLS=(
  "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
  "https://mirrors.ustc.edu.cn/debian-cloud-images/bookworm/latest/debian-12-generic-amd64.qcow2"
)
readonly CLOUD_IMAGE_FILE="debian-12-generic-amd64.qcow2"
readonly CLOUD_IMAGE_PATH="/var/lib/vz/template/qcow/$CLOUD_IMAGE_FILE"

# 日志配置
readonly LOG_DIR="/var/log/pve-k8s-deploy"
readonly LOG_FILE="$LOG_DIR/deploy_$(date +%Y%m%d_%H%M%S).log"

# ==========================================
# 通用工具函数
# ==========================================
log()     { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }
err()     { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }

# 初始化
init_logging() {
    mkdir -p "$LOG_DIR"
    log "脚本启动 - $SCRIPT_NAME v$SCRIPT_VERSION"
}

# 检查环境
check_environment() {
    log "检查运行环境..."
    
    if [[ $EUID -ne 0 ]]; then
        err "此脚本需要root权限运行"
        exit 1
    fi
    
    if ! command -v qm &>/dev/null; then
        err "未检测到PVE环境"
        exit 1
    fi
    
    local required_commands=("wget" "ssh" "sshpass" "nc")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            err "缺少必要命令: $cmd"
            exit 1
        fi
    done
    
    success "环境检查完成"
}

# 远程命令执行
run_remote_cmd() {
    local ip="$1"
    local cmd="$2"
    local retries="${3:-3}"
    
    for ((i=1; i<=retries; i++)); do
        if sshpass -p "$CLOUDINIT_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=10 \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "$CLOUDINIT_USER@$ip" "bash -c '$cmd'" 2>/dev/null; then
            return 0
        else
            if [[ $i -lt $retries ]]; then
                warn "远程命令执行失败，重试 $i/$retries..."
                sleep 5
            fi
        fi
    done
    
    return 1
}

# 等待SSH可用
wait_for_ssh() {
    local ip=$1
    local max_try=${2:-30}
    
    log "等待 $ip SSH服务启动..."
    for ((i=1; i<=max_try; i++)); do
        if nc -z "$ip" 22 &>/dev/null; then
            success "$ip SSH服务已启动"
            return 0
        fi
        sleep 10
    done
    
    err "$ip SSH服务启动超时"
    return 1
}

# ==========================================
# 核心修复功能（合并优化）
# ==========================================
# 修复K8S网络问题
fix_k8s_network() {
    log "修复K8S网络问题..."
    
    run_remote_cmd "$MASTER_IP" '
        echo "=== 修复K8S网络组件 ==="
        
        # 1. 创建必要的ServiceAccount
        kubectl create serviceaccount kube-proxy -n kube-system --dry-run=client -o yaml | kubectl apply -f -
        kubectl create clusterrolebinding kube-proxy --clusterrole=system:node-proxier --serviceaccount=kube-system:kube-proxy --dry-run=client -o yaml | kubectl apply -f -
        
        kubectl create serviceaccount coredns -n kube-system --dry-run=client -o yaml | kubectl apply -f -
        kubectl create clusterrolebinding system:coredns --clusterrole=system:coredns --serviceaccount=kube-system:coredns --dry-run=client -o yaml | kubectl apply -f -
        
        # 2. 重新创建kube-proxy
        kubectl delete daemonset -n kube-system kube-proxy --force --grace-period=0 2>/dev/null || true
        kubectl delete configmap -n kube-system kube-proxy --force --grace-period=0 2>/dev/null || true
        
        cat > /tmp/kube-proxy.yaml << "EOF"
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-proxy
  namespace: kube-system
data:
  config.conf: |
    apiVersion: kubeproxy.config.k8s.io/v1alpha1
    kind: KubeProxyConfiguration
    mode: "iptables"
    clusterCIDR: "10.244.0.0/16"
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  labels:
    k8s-app: kube-proxy
  name: kube-proxy
  namespace: kube-system
spec:
  selector:
    matchLabels:
      k8s-app: kube-proxy
  template:
    metadata:
      labels:
        k8s-app: kube-proxy
    spec:
      containers:
      - command:
        - /usr/local/bin/kube-proxy
        - --config=/var/lib/kube-proxy/config.conf
        - --hostname-override=$(NODE_NAME)
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        image: registry.k8s.io/kube-proxy:v1.28.2
        name: kube-proxy
        securityContext:
          privileged: true
        volumeMounts:
        - mountPath: /var/lib/kube-proxy
          name: kube-proxy
        - mountPath: /run/xtables.lock
          name: xtables-lock
        - mountPath: /lib/modules
          name: lib-modules
          readOnly: true
      hostNetwork: true
      serviceAccountName: kube-proxy
      tolerations:
      - operator: Exists
      volumes:
      - configMap:
          name: kube-proxy
        name: kube-proxy
      - hostPath:
          path: /run/xtables.lock
          type: FileOrCreate
        name: xtables-lock
      - hostPath:
          path: /lib/modules
        name: lib-modules
EOF
        kubectl apply -f /tmp/kube-proxy.yaml
        
        # 3. 重新创建coredns
        kubectl delete deployment -n kube-system coredns --force --grace-period=0 2>/dev/null || true
        kubectl delete configmap -n kube-system coredns --force --grace-period=0 2>/dev/null || true
        
        cat > /tmp/coredns.yaml << "EOF"
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
spec:
  replicas: 2
  selector:
    matchLabels:
      k8s-app: kube-dns
  template:
    metadata:
      labels:
        k8s-app: kube-dns
    spec:
      serviceAccountName: coredns
      tolerations:
      - key: "CriticalAddonsOnly"
        operator: "Equal"
        value: "true"
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      containers:
      - name: coredns
        image: registry.k8s.io/coredns/coredns:v1.10.1
        args: [ "-conf", "/etc/coredns/Corefile" ]
        volumeMounts:
        - name: config-volume
          mountPath: /etc/coredns
          readOnly: true
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        - containerPort: 9153
          name: metrics
          protocol: TCP
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 60
          timeoutSeconds: 5
        readinessProbe:
          httpGet:
            path: /ready
            port: 8181
      volumes:
      - name: config-volume
        configMap:
          name: coredns
          items:
          - key: Corefile
            path: Corefile
EOF
        kubectl apply -f /tmp/coredns.yaml
        
        # 4. 修复Calico网络
        kubectl delete pods -n kube-system -l k8s-app=calico-node --force --grace-period=0 2>/dev/null || true
        kubectl delete pods -n kube-system -l k8s-app=calico-kube-controllers --force --grace-period=0 2>/dev/null || true
        
        # 重新应用Calico
        kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml
        
        echo "网络修复完成"
    ' || warn "网络修复部分失败"
    
    success "K8S网络修复完成"
}

# 修复KubeSphere安装
fix_kubesphere() {
    log "修复KubeSphere安装..."
    
    run_remote_cmd "$MASTER_IP" '
        echo "=== 修复KubeSphere ==="
        
        # 清理现有安装
        kubectl delete -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml 2>/dev/null || true
        kubectl delete -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml 2>/dev/null || true
        kubectl delete ns kubesphere-system --force --grace-period=0 2>/dev/null || true
        kubectl delete ns kubesphere-controls-system --force --grace-period=0 2>/dev/null || true
        
        sleep 30
        
        # 重新安装
        kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml
        kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml
        
        echo "KubeSphere重新安装完成"
    ' || warn "KubeSphere修复部分失败"
    
    success "KubeSphere修复完成"
}

# 检查集群状态
check_cluster_status() {
    log "检查集群状态..."
    
    run_remote_cmd "$MASTER_IP" '
        echo "=== 集群状态 ==="
        kubectl get nodes
        echo ""
        echo "=== 系统Pod状态 ==="
        kubectl get pods -n kube-system | grep -E "(kube-proxy|coredns|calico)"
        echo ""
        echo "=== KubeSphere状态 ==="
        kubectl get pods -n kubesphere-system 2>/dev/null || echo "KubeSphere未安装"
        echo ""
        echo "=== 端口检查 ==="
        netstat -tlnp | grep -E ":30880|:6443" || echo "关键端口未监听"
    ' || true
}

# ==========================================
# 部署功能
# ==========================================
# 下载云镜像
download_cloud_image() {
    if [[ -f "$CLOUD_IMAGE_PATH" ]]; then
        log "云镜像已存在: $CLOUD_IMAGE_PATH"
        return 0
    fi
    
    log "下载云镜像..."
    mkdir -p "$(dirname "$CLOUD_IMAGE_PATH")"
    
    for url in "${CLOUD_IMAGE_URLS[@]}"; do
        log "尝试从 $url 下载..."
        if wget -O "$CLOUD_IMAGE_PATH" "$url"; then
            success "云镜像下载完成"
            return 0
        else
            warn "下载失败，尝试下一个源..."
        fi
    done
    
    err "所有镜像源下载失败"
    return 1
}

# 创建虚拟机
create_vms() {
    log "创建虚拟机..."
    
    for i in "${!VM_IDS[@]}"; do
        local vm_id="${VM_IDS[$i]}"
        local vm_name="${VM_NAMES[$i]}"
        local vm_ip="${VM_IPS[$i]}"
        
        log "创建虚拟机: $vm_name (ID: $vm_id, IP: $vm_ip)"
        
        # 删除现有虚拟机
        qm stop "$vm_id" 2>/dev/null || true
        qm destroy "$vm_id" 2>/dev/null || true
        sleep 2
        
        # 创建新虚拟机
        if qm create "$vm_id" \
            --name "$vm_name" \
            --memory "$VM_MEM" \
            --cores "$VM_CORES" \
            --net0 "virtio,bridge=$BRIDGE" \
            --scsihw virtio-scsi-pci \
            --ide2 "$STORAGE:cloudinit" \
            --serial0 socket \
            --vga serial0 \
            --ipconfig0 "ip=$vm_ip/24,gw=$GATEWAY" \
            --nameserver "$DNS" \
            --ciuser "$CLOUDINIT_USER" \
            --cipassword "$CLOUDINIT_PASS" \
            --agent enabled=1; then
            
            log "虚拟机 $vm_id 创建成功，导入云镜像..."
            
            # 导入云镜像并设置启动盘
            if qm importdisk "$vm_id" "$CLOUD_IMAGE_PATH" "$STORAGE" --format qcow2; then
                qm set "$vm_id" --scsi0 "$STORAGE:vm-$vm_id-disk-0"
                qm set "$vm_id" --boot c --bootdisk scsi0
                
                # 启动虚拟机
                if qm start "$vm_id"; then
                    success "虚拟机 $vm_name 创建并启动成功"
                else
                    err "虚拟机 $vm_name 启动失败"
                    return 1
                fi
            else
                err "虚拟机 $vm_name 云镜像导入失败"
                return 1
            fi
        else
            err "虚拟机 $vm_name 创建失败"
            return 1
        fi
    done
    
    success "所有虚拟机创建完成"
}

# 等待虚拟机启动
wait_for_vms() {
    log "等待虚拟机启动..."
    
    # 首先检查虚拟机是否真的存在
    log "检查虚拟机状态..."
    for vm_id in "${VM_IDS[@]}"; do
        if qm status "$vm_id" &>/dev/null; then
            local status=$(qm status "$vm_id" | awk '{print $2}')
            log "虚拟机 $vm_id 状态: $status"
        else
            err "虚拟机 $vm_id 不存在！"
            return 1
        fi
    done
    
    # 等待SSH服务
    for ip in "${VM_IPS[@]}"; do
        wait_for_ssh "$ip"
    done
    
    success "所有虚拟机已启动"
}

# 部署K8S集群
deploy_k8s() {
    log "部署K8S集群..."
    
    # 更新系统并安装依赖
    for ip in "${VM_IPS[@]}"; do
        log "配置节点: $ip"
        run_remote_cmd "$ip" '
            apt-get update -y
            apt-get install -y apt-transport-https ca-certificates curl
            
            # 安装Docker
            curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
            echo "deb [arch=amd64] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
            apt-get update -y
            apt-get install -y docker-ce docker-ce-cli containerd.io
            systemctl enable docker
            systemctl start docker
            
            # 安装kubeadm
            curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
            echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
            apt-get update -y
            apt-get install -y kubelet kubeadm kubectl
            apt-mark hold kubelet kubeadm kubectl
            
            # 配置系统
            swapoff -a
            sed -i "/swap/d" /etc/fstab
            
            modprobe br_netfilter
            echo "br_netfilter" >> /etc/modules-load.d/k8s.conf
            
            cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
            sysctl --system
            
            systemctl enable kubelet
        '
    done
    
    # 初始化主节点
    log "初始化K8S主节点..."
    run_remote_cmd "$MASTER_IP" '
        kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address='"$MASTER_IP"'
        
        mkdir -p /root/.kube
        cp -i /etc/kubernetes/admin.conf /root/.kube/config
        chown root:root /root/.kube/config
        
        # 安装Calico网络插件
        kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml
        
        # 生成加入命令
        kubeadm token create --print-join-command > /tmp/join-command
    '
    
    # 获取加入命令
    local join_cmd
    join_cmd=$(run_remote_cmd "$MASTER_IP" 'cat /tmp/join-command')
    
    # 工作节点加入集群
    for worker_ip in "${WORKER_IPS[@]}"; do
        log "工作节点 $worker_ip 加入集群..."
        run_remote_cmd "$worker_ip" "$join_cmd"
    done
    
    success "K8S集群部署完成"
}

# 部署KubeSphere
deploy_kubesphere() {
    log "部署KubeSphere..."
    
    run_remote_cmd "$MASTER_IP" '
        # 安装KubeSphere
        kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/kubesphere-installer.yaml
        kubectl apply -f https://github.com/kubesphere/ks-installer/releases/download/v3.4.1/cluster-configuration.yaml
        
        echo "KubeSphere安装启动，请等待安装完成..."
    '
    
    success "KubeSphere部署完成"
}

# 清理所有资源
cleanup_all() {
    log "清理所有资源..."
    
    for vm_id in "${VM_IDS[@]}"; do
        qm stop "$vm_id" 2>/dev/null || true
        qm destroy "$vm_id" 2>/dev/null || true
    done
    
    success "清理完成"
}

# ==========================================
# 界面显示
# ==========================================
show_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║           PVE K8S + KubeSphere 一键部署工具 v3.0            ║"
    echo "║                        重构精简版                            ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

show_menu() {
    echo -e "${YELLOW}═══════════════ 主菜单 ═══════════════${NC}"
    echo -e "${GREEN}部署功能：${NC}"
    echo -e "  ${CYAN}1.${NC} 一键全自动部署（推荐）"
    echo -e "  ${CYAN}2.${NC} 下载云镜像"
    echo -e "  ${CYAN}3.${NC} 创建虚拟机"
    echo -e "  ${CYAN}4.${NC} 部署K8S集群"
    echo -e "  ${CYAN}5.${NC} 部署KubeSphere"
    echo ""
    echo -e "${YELLOW}修复功能：${NC}"
    echo -e "  ${CYAN}6.${NC} 修复K8S网络问题"
    echo -e "  ${CYAN}7.${NC} 修复KubeSphere安装"
    echo -e "  ${CYAN}8.${NC} 检查集群状态"
    echo -e "  ${CYAN}9.${NC} 一键修复所有问题"
    echo ""
    echo -e "${RED}管理功能：${NC}"
    echo -e "  ${CYAN}10.${NC} 清理所有资源"
    echo -e "  ${CYAN}0.${NC} 退出"
    echo -e "${YELLOW}══════════════════════════════════════${NC}"
}

# ==========================================
# 主程序
# ==========================================
main() {
    init_logging
    check_environment
    
    while true; do
        clear
        show_banner
        show_menu
        
        read -p "请选择操作 [0-10]: " choice
        
        case $choice in
            1)
                log "开始一键全自动部署..."
                download_cloud_image && \
                create_vms && \
                wait_for_vms && \
                deploy_k8s && \
                deploy_kubesphere
                success "一键部署完成！"
                ;;
            2) download_cloud_image ;;
            3) create_vms ;;
            4) deploy_k8s ;;
            5) deploy_kubesphere ;;
            6) fix_k8s_network ;;
            7) fix_kubesphere ;;
            8) check_cluster_status ;;
            9)
                log "开始一键修复..."
                fix_k8s_network
                sleep 60
                fix_kubesphere
                sleep 30
                check_cluster_status
                success "一键修复完成！"
                ;;
            10) cleanup_all ;;
            0) 
                log "退出脚本"
                exit 0 
                ;;
            *)
                warn "无效选择，请重新输入"
                ;;
        esac
        
        echo ""
        read -p "按回车键继续..."
    done
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 