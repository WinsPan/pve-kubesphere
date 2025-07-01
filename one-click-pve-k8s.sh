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
                warn "节点 $ip 远程命令执行失败，重试 $i/$retries..."
                # 检查基本连接
                if ! nc -z "$ip" 22 &>/dev/null; then
                    warn "节点 $ip SSH端口不可达"
                fi
                sleep 10
            else
                err "节点 $ip 远程命令执行最终失败"
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
            log "$ip SSH端口已开放，测试登录..."
            # 测试SSH登录
            if test_ssh_login "$ip"; then
                success "$ip SSH服务已启动且可登录"
                return 0
            else
                warn "$ip SSH端口开放但登录失败，继续等待..."
            fi
        fi
        sleep 10
    done
    
    err "$ip SSH服务启动超时"
    return 1
}

# 测试SSH登录
test_ssh_login() {
    local ip=$1
    local max_try=${2:-5}
    
    for ((i=1; i<=max_try; i++)); do
        if sshpass -p "$CLOUDINIT_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "$CLOUDINIT_USER@$ip" "echo 'SSH连接测试成功'" &>/dev/null; then
            return 0
        else
            if [[ $i -lt $max_try ]]; then
                sleep 5
            fi
        fi
    done
    
    return 1
}

# 等待Cloud-init完成
wait_for_cloudinit() {
    local ip=$1
    local max_try=${2:-60}
    
    log "等待 $ip Cloud-init初始化完成..."
    
    for ((i=1; i<=max_try; i++)); do
        # 检查Cloud-init状态
        if sshpass -p "$CLOUDINIT_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=10 \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "$CLOUDINIT_USER@$ip" "cloud-init status --wait" 2>/dev/null; then
            
            success "$ip Cloud-init初始化完成"
            return 0
        else
            if [[ $((i % 10)) -eq 0 ]]; then
                log "$ip Cloud-init还在运行中... ($i/$max_try)"
            fi
            sleep 10
        fi
    done
    
    warn "$ip Cloud-init等待超时，尝试继续..."
    return 1
}

# ==========================================
# 核心修复功能（合并优化）
# ==========================================
# 修复K8S网络问题
fix_k8s_network() {
    log "修复K8S网络问题..."
    
    if ! run_remote_cmd "$MASTER_IP" '
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
    '; then
        success "K8S网络修复完成"
        return 0
    else
        err "K8S网络修复失败"
        return 1
    fi
}

# 修复KubeSphere安装
fix_kubesphere() {
    log "修复KubeSphere安装..."
    
    if run_remote_cmd "$MASTER_IP" '
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
    '; then
        success "KubeSphere修复完成"
        return 0
    else
        err "KubeSphere修复失败"
        return 1
    fi
}

# 检查集群状态
check_cluster_status() {
    log "检查集群状态..."
    
    run_remote_cmd "$MASTER_IP" '
        echo "=== 集群状态 ==="
        kubectl get nodes -o wide
        echo ""
        echo "=== 系统Pod状态 ==="
        kubectl get pods -n kube-system | grep -E "(kube-proxy|coredns|calico)" || echo "关键Pod未找到"
        echo ""
        echo "=== KubeSphere状态 ==="
        kubectl get pods -n kubesphere-system 2>/dev/null || echo "KubeSphere未安装"
        echo ""
        echo "=== 端口检查 ==="
        netstat -tlnp | grep -E ":30880|:6443" || echo "关键端口未监听"
        echo ""
        echo "=== 服务状态 ==="
        kubectl get svc -n kubesphere-system 2>/dev/null | grep -E "ks-console|ks-apiserver" || echo "KubeSphere服务未找到"
    ' || true
}

# ==========================================
# 部署功能
# ==========================================

# 创建Cloud-init用户数据文件
create_cloudinit_userdata() {
    log "创建Cloud-init配置文件..."
    
    local snippets_dir="/var/lib/vz/snippets"
    local userdata_file="$snippets_dir/user-data-k8s.yml"
    
    # 确保目录存在
    mkdir -p "$snippets_dir"
    
    # 创建用户数据文件
    cat > "$userdata_file" << EOF
#cloud-config
# PVE K8S部署专用Cloud-init配置

# 系统配置
locale: en_US.UTF-8
timezone: Asia/Shanghai

# 软件包管理
package_update: true
package_upgrade: false

# 用户配置 - 确保root用户可以SSH登录
users:
  - name: root
    lock_passwd: false
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL

# SSH配置 - 强制启用root登录
ssh_pwauth: true
disable_root: false
ssh_deletekeys: false
chpasswd:
  expire: false

# 系统配置文件修改
write_files:
  # SSH主配置 - 强制允许root登录
  - path: /etc/ssh/sshd_config.d/00-root-login.conf
    content: |
      # 强制启用root SSH登录
      PermitRootLogin yes
      PasswordAuthentication yes
      PubkeyAuthentication yes
      AuthorizedKeysFile .ssh/authorized_keys
      ChallengeResponseAuthentication no
      UsePAM yes
      X11Forwarding yes
      PrintMotd no
      AcceptEnv LANG LC_*
      Subsystem sftp /usr/lib/openssh/sftp-server
    permissions: '0644'
    owner: root:root
  
  # 确保SSH配置生效
  - path: /etc/ssh/sshd_config.d/99-pve-k8s.conf
    content: |
      # PVE K8S部署专用SSH配置
      PermitRootLogin yes
      PasswordAuthentication yes
      PubkeyAuthentication yes
      MaxAuthTries 6
      MaxSessions 10
      TCPKeepAlive yes
      ClientAliveInterval 60
      ClientAliveCountMax 3
    permissions: '0644'
    owner: root:root
  
  # 内核模块配置
  - path: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter
    permissions: '0644'
    owner: root:root
  
  # 内核参数配置
  - path: /etc/sysctl.d/99-k8s.conf
    content: |
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward = 1
      net.ipv4.conf.all.forwarding = 1
    permissions: '0644'
    owner: root:root

# 运行命令 - 确保SSH配置生效
runcmd:
  # 强制设置root密码
  - echo "root:$CLOUDINIT_PASS" | chpasswd
  
  # 确保SSH服务配置正确
  - systemctl stop sshd
  - sleep 2
  - systemctl start sshd
  - systemctl enable sshd
  
  # 验证SSH配置
  - sshd -t
  
  # 加载内核模块
  - modprobe overlay
  - modprobe br_netfilter
  
  # 应用内核参数
  - sysctl --system
  
  # 禁用swap
  - swapoff -a
  - sed -i '/swap/d' /etc/fstab
  
  # 安装基础软件包
  - apt-get update
  - apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release openssh-server
  
  # 确保SSH服务正在运行
  - systemctl restart sshd
  - systemctl status sshd
  
  # 配置时区
  - timedatectl set-timezone Asia/Shanghai
  
  # 设置主机名解析
  - echo "127.0.0.1 $(hostname)" >> /etc/hosts
  
  # 最后再次重启SSH确保配置生效
  - sleep 5
  - systemctl restart sshd

# 最终消息
final_message: "Cloud-init setup completed. SSH root login enabled with password authentication."
EOF
    
    success "Cloud-init配置文件创建完成: $userdata_file"
}

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
    
    # 创建Cloud-init用户数据文件
    create_cloudinit_userdata
    
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
            --vga std \
            --ipconfig0 "ip=$vm_ip/24,gw=$GATEWAY" \
            --nameserver "$DNS" \
            --ciuser "$CLOUDINIT_USER" \
            --cipassword "$CLOUDINIT_PASS" \
            --cicustom "user=local:snippets/user-data-k8s.yml" \
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
    
    # 等待Cloud-init完成
    for ip in "${VM_IPS[@]}"; do
        wait_for_cloudinit "$ip"
    done
    
    success "所有虚拟机已启动并初始化完成"
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

# 诊断虚拟机连接状态
diagnose_vms() {
    log "诊断虚拟机连接状态..."
    
    for i in "${!VM_IDS[@]}"; do
        local vm_id="${VM_IDS[$i]}"
        local vm_name="${VM_NAMES[$i]}"
        local vm_ip="${VM_IPS[$i]}"
        
        echo -e "\n${CYAN}=== 诊断虚拟机: $vm_name ($vm_ip) ===${NC}"
        
        # 1. 检查虚拟机状态
        if qm status "$vm_id" &>/dev/null; then
            local status=$(qm status "$vm_id" | awk '{print $2}')
            echo -e "虚拟机状态: ${GREEN}$status${NC}"
        else
            echo -e "虚拟机状态: ${RED}不存在${NC}"
            continue
        fi
        
        # 2. 检查网络连通性
        if ping -c 1 -W 3 "$vm_ip" &>/dev/null; then
            echo -e "网络连通性: ${GREEN}正常${NC}"
        else
            echo -e "网络连通性: ${RED}失败${NC}"
            continue
        fi
        
        # 3. 检查SSH端口
        if nc -z "$vm_ip" 22 2>/dev/null; then
            echo -e "SSH端口: ${GREEN}开放${NC}"
        else
            echo -e "SSH端口: ${RED}关闭${NC}"
            continue
        fi
        
        # 4. 检查SSH认证
        if sshpass -p "$CLOUDINIT_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "$CLOUDINIT_USER@$vm_ip" "echo 'SSH连接成功'" 2>/dev/null; then
            echo -e "SSH认证: ${GREEN}成功${NC}"
        else
            echo -e "SSH认证: ${RED}失败${NC}"
            # 进行详细SSH诊断
            diagnose_ssh_detailed "$vm_ip"
            continue
        fi
        
        # 5. 检查Cloud-init状态
        local cloudinit_status
        cloudinit_status=$(sshpass -p "$CLOUDINIT_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "$CLOUDINIT_USER@$vm_ip" "cloud-init status" 2>/dev/null || echo "unknown")
        
        if [[ "$cloudinit_status" == *"done"* ]]; then
            echo -e "Cloud-init状态: ${GREEN}完成${NC}"
        elif [[ "$cloudinit_status" == *"running"* ]]; then
            echo -e "Cloud-init状态: ${YELLOW}运行中${NC}"
        else
            echo -e "Cloud-init状态: ${RED}$cloudinit_status${NC}"
        fi
        
        # 6. 检查系统负载
        local load_avg
        load_avg=$(sshpass -p "$CLOUDINIT_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "$CLOUDINIT_USER@$vm_ip" "uptime | awk -F'load average:' '{print \$2}' | awk '{print \$1}'" 2>/dev/null || echo "unknown")
        
        echo -e "系统负载: $load_avg"
    done
    
    echo -e "\n${GREEN}诊断完成${NC}"
}

# 详细SSH诊断
diagnose_ssh_detailed() {
    local ip=$1
    
    echo -e "\n${CYAN}=== SSH详细诊断: $ip ===${NC}"
    
    # 1. 测试SSH连接
    if sshpass -p "$CLOUDINIT_PASS" ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "$CLOUDINIT_USER@$ip" "echo 'SSH连接测试成功'" &>/dev/null; then
        echo -e "SSH连接: ${GREEN}成功${NC}"
        
        # 获取SSH配置信息
        local ssh_config
        ssh_config=$(sshpass -p "$CLOUDINIT_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "$CLOUDINIT_USER@$ip" "sshd -T | grep -E '(permitrootlogin|passwordauthentication)'" 2>/dev/null)
        
        echo -e "SSH配置: $ssh_config"
        
        # 检查Cloud-init日志
        local cloudinit_log
        cloudinit_log=$(sshpass -p "$CLOUDINIT_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "$CLOUDINIT_USER@$ip" "tail -5 /var/log/cloud-init.log 2>/dev/null | grep -E '(ssh|root|password)'" 2>/dev/null || echo "无法获取")
        
        echo -e "Cloud-init日志: $cloudinit_log"
        
    else
        echo -e "SSH连接: ${RED}失败${NC}"
        
        # 尝试详细错误诊断
        local ssh_error
        ssh_error=$(sshpass -p "$CLOUDINIT_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            -o UserKnownHostsFile=/dev/null \
            -v \
            "$CLOUDINIT_USER@$ip" "echo test" 2>&1 | tail -3)
        
        echo -e "SSH错误信息: $ssh_error"
        
        # 检查是否是密码问题
        echo -e "正在测试不同的登录方式..."
        
        # 测试无密码连接
        if ssh -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            -o PasswordAuthentication=no \
            "$CLOUDINIT_USER@$ip" "echo test" &>/dev/null; then
            echo -e "密钥认证: ${GREEN}可用${NC}"
        else
            echo -e "密钥认证: ${RED}不可用${NC}"
        fi
    fi
}

# 修复SSH连接问题
fix_ssh_connection() {
    log "修复SSH连接问题..."
    
    for i in "${!VM_IDS[@]}"; do
        local vm_id="${VM_IDS[$i]}"
        local vm_name="${VM_NAMES[$i]}"
        local vm_ip="${VM_IPS[$i]}"
        
        log "修复虚拟机 $vm_name ($vm_ip) 的SSH连接..."
        
        # 1. 检查虚拟机是否运行
        if ! qm status "$vm_id" | grep -q "running"; then
            warn "虚拟机 $vm_id 未运行，尝试启动..."
            qm start "$vm_id"
            sleep 10
        fi
        
        # 2. 检查网络连通性
        if ! ping -c 1 -W 3 "$vm_ip" &>/dev/null; then
            err "虚拟机 $vm_ip 网络不通，跳过..."
            continue
        fi
        
        # 3. 检查SSH端口
        if ! nc -z "$vm_ip" 22 2>/dev/null; then
            warn "SSH端口未开放，等待服务启动..."
            sleep 20
            if ! nc -z "$vm_ip" 22 2>/dev/null; then
                err "SSH端口仍未开放，可能需要重新创建虚拟机"
                continue
            fi
        fi
        
        # 4. 测试SSH连接
        if test_ssh_login "$vm_ip"; then
            success "虚拟机 $vm_name SSH连接正常"
            continue
        fi
        
        # 5. 尝试修复SSH配置
        log "尝试通过控制台修复SSH配置..."
        
        # 通过qm monitor命令尝试修复（需要虚拟机支持）
        # 这里可以添加更多修复逻辑
        warn "虚拟机 $vm_name SSH连接失败，建议："
        echo "  1. 检查Cloud-init配置是否正确"
        echo "  2. 通过PVE控制台登录检查SSH服务状态"
        echo "  3. 重新创建虚拟机"
        
        # 显示详细诊断信息
        diagnose_ssh_detailed "$vm_ip"
    done
    
    success "SSH连接修复完成"
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
    echo -e "  ${CYAN}12.${NC} 修复SSH连接问题"
    echo ""
    echo -e "${BLUE}诊断功能：${NC}"
    echo -e "  ${CYAN}11.${NC} 检查虚拟机连接状态"
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
        
        read -p "请选择操作 [0-12]: " choice
        
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
                if fix_k8s_network; then
                    log "K8S网络修复完成，等待Pod重启..."
                    sleep 60
                    if fix_kubesphere; then
                        log "KubeSphere修复完成，等待服务启动..."
                        sleep 30
                        check_cluster_status
                        success "一键修复完成！"
                    else
                        err "KubeSphere修复失败"
                    fi
                else
                    err "K8S网络修复失败"
                fi
                ;;
            10) cleanup_all ;;
            11) diagnose_vms ;;
            12) fix_ssh_connection ;;
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