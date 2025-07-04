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
readonly SCRIPT_VERSION="3.1"
readonly SCRIPT_NAME="PVE K8S+KubeSphere 部署工具 (GitHub源码版)"

# 版本配置（GitHub源码安装）
readonly CONTAINERD_VERSION="1.7.12"
readonly RUNC_VERSION="v1.1.10"
readonly CNI_VERSION="v1.4.0"
readonly K8S_VERSION="v1.29.0"

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
readonly DNS="10.0.0.2 119.29.29.29"

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
    
    local required_commands=("wget" "ssh" "sshpass" "nc" "expect")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            warn "缺少必要命令: $cmd，尝试安装..."
            if [[ "$cmd" == "expect" ]]; then
                apt-get update && apt-get install -y expect
            elif [[ "$cmd" == "sshpass" ]]; then
                apt-get update && apt-get install -y sshpass
            else
                err "缺少必要命令: $cmd，请手动安装"
                exit 1
            fi
        fi
    done
    
    success "环境检查完成"
}

# 远程命令执行（智能用户发现）
run_remote_cmd() {
    local ip="$1"
    local cmd="$2"
    local retries="${3:-3}"
    
    # 尝试发现可用的用户和密码
    local working_user=""
    local working_pass=""
    
    # 如果还没有发现工作用户，尝试发现
    if [[ -z "$working_user" ]]; then
        local users=("$CLOUDINIT_USER" "root" "debian" "ubuntu")
        local passwords=("$CLOUDINIT_PASS" "debian" "ubuntu")
        
        for user in "${users[@]}"; do
            for pass in "${passwords[@]}"; do
                if sshpass -p "$pass" ssh \
                    -o StrictHostKeyChecking=no \
                    -o ConnectTimeout=5 \
                    -o UserKnownHostsFile=/dev/null \
                    -o LogLevel=ERROR \
                    "$user@$ip" "echo 'test'" &>/dev/null; then
                    working_user="$user"
                    working_pass="$pass"
                    break 2
                fi
            done
        done
    fi
    
    # 如果没有发现工作用户，使用默认配置
    if [[ -z "$working_user" ]]; then
        working_user="$CLOUDINIT_USER"
        working_pass="$CLOUDINIT_PASS"
    fi
    
    for ((i=1; i<=retries; i++)); do
        # 先测试SSH连接
        if ! nc -z "$ip" 22 &>/dev/null; then
            warn "$ip SSH端口不可达，等待5秒后重试..."
            sleep 5
            continue
        fi
        
        # 执行远程命令
        local ssh_output
        local ssh_exit_code
        
        ssh_output=$(sshpass -p "$working_pass" ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=10 \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "$working_user@$ip" "bash -c '$cmd'" 2>&1)
        ssh_exit_code=$?
        
        if [[ $ssh_exit_code -eq 0 ]]; then
            # 成功时输出结果（如果有）
            if [[ -n "$ssh_output" ]]; then
                echo "$ssh_output"
            fi
            return 0
        else
            if [[ $i -lt $retries ]]; then
                warn "远程命令执行失败 (用户: $working_user, 退出码: $ssh_exit_code)，重试 $i/$retries..."
                if [[ -n "$ssh_output" ]]; then
                    warn "错误输出: $ssh_output"
                fi
                sleep 5
            else
                err "远程命令执行最终失败 (用户: $working_user, 退出码: $ssh_exit_code)"
                if [[ -n "$ssh_output" ]]; then
                    err "错误输出: $ssh_output"
                fi
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

# 测试和修复SSH连接
test_and_fix_ssh() {
    local ip=$1
    local vm_id=$2
    
    log "测试SSH连接到 $ip..."
    
    # 1. 首先测试基本连接
    if sshpass -p "$CLOUDINIT_PASS" ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "$CLOUDINIT_USER@$ip" "echo 'SSH连接正常'" 2>/dev/null; then
        success "$ip SSH连接测试成功"
        return 0
    fi
    
    warn "$ip SSH连接失败，尝试修复..."
    
    # 2. 检查虚拟机状态
    local vm_status
    vm_status=$(qm status "$vm_id" | awk '{print $2}')
    if [[ "$vm_status" != "running" ]]; then
        warn "虚拟机 $vm_id 状态异常: $vm_status，重启中..."
        qm stop "$vm_id" 2>/dev/null || true
        sleep 5
        qm start "$vm_id"
        sleep 30
    fi
    
    # 3. 通过VNC/串口重置SSH配置
    log "通过VNC重置 $ip 的SSH配置..."
    
    # 使用expect自动化VNC登录和配置
    expect << EOF
set timeout 30
spawn qm monitor $vm_id
expect "qm>"
send "info vnc\r"
expect "qm>"
send "quit\r"
expect eof
EOF
    
    # 4. 尝试多种修复方法
    log "尝试修复SSH连接..."
    
    # 方法1: 重新配置cloud-init（忽略agent错误）
    log "重新配置cloud-init用户..."
    qm set "$vm_id" --ciuser "$CLOUDINIT_USER" --cipassword "$CLOUDINIT_PASS" 2>/dev/null || true
    
    # 方法2: 尝试重新生成cloud-init配置
    log "重新生成cloud-init配置..."
    qm set "$vm_id" --ide2 "$STORAGE:cloudinit" 2>/dev/null || true
    
    # 方法3: 软重启虚拟机
    log "重启虚拟机..."
    qm reboot "$vm_id" 2>/dev/null || {
        warn "软重启失败，尝试硬重启..."
        qm stop "$vm_id" 2>/dev/null || true
        sleep 10
        qm start "$vm_id" 2>/dev/null || true
    }
    
    # 5. 等待重启完成
    log "等待虚拟机重启完成..."
    sleep 90
    wait_for_ssh "$ip" 30
    
    # 6. 再次测试连接
    if sshpass -p "$CLOUDINIT_PASS" ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "$CLOUDINIT_USER@$ip" "echo 'SSH修复成功'" 2>/dev/null; then
        success "$ip SSH连接修复成功"
        return 0
    fi
    
    # 7. 尝试不同的用户名和密码组合
    warn "$ip 常规SSH修复失败，尝试备用认证方案..."
    
    # 常见的用户名和密码组合
    local users=("root" "debian" "ubuntu" "admin")
    local passwords=("$CLOUDINIT_PASS" "debian" "ubuntu" "admin" "password" "123456")
    
    for user in "${users[@]}"; do
        for pass in "${passwords[@]}"; do
            if sshpass -p "$pass" ssh \
                -o StrictHostKeyChecking=no \
                -o ConnectTimeout=5 \
                -o UserKnownHostsFile=/dev/null \
                -o LogLevel=ERROR \
                "$user@$ip" "echo 'SSH连接成功 - 用户: $user'" 2>/dev/null; then
                warn "$ip 使用用户 $user (密码: $pass) 连接成功"
                
                # 如果不是预期的用户，尝试设置正确的用户
                if [[ "$user" != "$CLOUDINIT_USER" ]]; then
                    log "尝试创建正确的用户账户..."
                    sshpass -p "$pass" ssh \
                        -o StrictHostKeyChecking=no \
                        -o ConnectTimeout=5 \
                        -o UserKnownHostsFile=/dev/null \
                        -o LogLevel=ERROR \
                        "$user@$ip" "
                        useradd -m -s /bin/bash $CLOUDINIT_USER 2>/dev/null || true
                        echo '$CLOUDINIT_USER:$CLOUDINIT_PASS' | chpasswd
                        usermod -aG sudo $CLOUDINIT_USER 2>/dev/null || true
                        " 2>/dev/null || true
                fi
                
                success "$ip SSH连接修复完成（用户: $user）"
                return 0
            fi
        done
    done
    
    err "$ip SSH连接修复失败"
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
        
        # 创建基础虚拟机
        log "创建基础虚拟机配置..."
        if ! qm create "$vm_id" \
            --name "$vm_name" \
            --memory "$VM_MEM" \
            --cores "$VM_CORES" \
            --net0 "virtio,bridge=$BRIDGE" \
            --scsihw virtio-scsi-pci \
            --ide2 "$STORAGE:cloudinit" \
            --vga std \
            --ipconfig0 "ip=$vm_ip/24,gw=$GATEWAY" \
            --nameserver "$DNS" \
            --ciuser "$CLOUDINIT_USER" \
            --cipassword "$CLOUDINIT_PASS" \
            --agent enabled=1; then
            err "虚拟机 $vm_name 创建失败"
            continue
        fi
        
        # 导入云镜像并设置磁盘
        log "导入云镜像到存储..."
        
        # 方法1：尝试直接导入
        if qm importdisk "$vm_id" "$CLOUD_IMAGE_PATH" "$STORAGE" --format qcow2 >/dev/null 2>&1; then
            log "使用导入方式设置磁盘"
            qm set "$vm_id" --scsi0 "$STORAGE:vm-$vm_id-disk-0"
        else
            # 方法2：使用传统方式创建磁盘并复制镜像
            log "导入失败，使用传统方式创建磁盘"
            
            # 创建空磁盘
            qm set "$vm_id" --scsi0 "$STORAGE:$VM_DISK,format=qcow2"
            
            # 等待磁盘创建完成
            sleep 2
            
            # 获取磁盘路径
            local disk_path
            if [[ "$STORAGE" == "local-lvm" ]]; then
                disk_path="/dev/pve/vm-$vm_id-disk-0"
            else
                disk_path="/var/lib/vz/images/$vm_id/vm-$vm_id-disk-0.qcow2"
            fi
            
            # 复制镜像内容
            log "复制云镜像内容到VM磁盘..."
            if [[ "$STORAGE" == "local-lvm" ]]; then
                # LVM存储：转换并复制
                qemu-img convert -f qcow2 -O raw "$CLOUD_IMAGE_PATH" "$disk_path" || {
                    warn "直接复制失败，尝试使用dd"
                    dd if="$CLOUD_IMAGE_PATH" of="$disk_path" bs=1M status=progress 2>/dev/null || true
                }
            else
                # 文件存储：直接复制
                cp "$CLOUD_IMAGE_PATH" "$disk_path" || {
                    warn "直接复制失败，尝试使用qemu-img"
                    qemu-img convert -f qcow2 -O qcow2 "$CLOUD_IMAGE_PATH" "$disk_path" || true
                }
            fi
        fi
        
        # 设置启动配置
        qm set "$vm_id" --boot c --bootdisk scsi0
        
        # 验证VM配置
        if ! qm config "$vm_id" >/dev/null 2>&1; then
            err "虚拟机 $vm_name 配置验证失败"
            continue
        fi
        
        # 启动虚拟机
        log "启动虚拟机 $vm_name..."
        if qm start "$vm_id"; then
            success "虚拟机 $vm_name 创建并启动完成"
        else
            warn "虚拟机 $vm_name 启动失败，但已创建"
        fi
    done
}

# 等待虚拟机启动
wait_for_vms() {
    log "等待虚拟机启动..."
    
    for i in "${!VM_IPS[@]}"; do
        local ip="${VM_IPS[$i]}"
        local vm_id="${VM_IDS[$i]}"
        
        # 等待SSH服务启动
        wait_for_ssh "$ip"
        
        # 测试和修复SSH连接
        if ! test_and_fix_ssh "$ip" "$vm_id"; then
            err "虚拟机 $ip SSH连接修复失败"
            return 1
        fi
    done
    
    success "所有虚拟机已启动并SSH连接正常"
}

# 部署K8S集群
deploy_k8s() {
    log "部署K8S集群..."
    
    # 更新系统并安装依赖
    for ip in "${VM_IPS[@]}"; do
        log "配置节点: $ip"
        run_remote_cmd "$ip" '
            apt-get update -y
            apt-get install -y curl wget tar gzip
            
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
            
            # 从GitHub源码安装containerd
            echo "=== 安装containerd（从GitHub源码） ==="
            cd /tmp
            
            # 下载containerd
            echo "下载 containerd v'"$CONTAINERD_VERSION"'..."
            wget -q https://github.com/containerd/containerd/releases/download/v'"$CONTAINERD_VERSION"'/containerd-'"$CONTAINERD_VERSION"'-linux-amd64.tar.gz
            tar Cxzvf /usr/local containerd-'"$CONTAINERD_VERSION"'-linux-amd64.tar.gz
            
            # 下载runc
            echo "下载 runc '"$RUNC_VERSION"'..."
            wget -q https://github.com/opencontainers/runc/releases/download/'"$RUNC_VERSION"'/runc.amd64
            install -m 755 runc.amd64 /usr/local/sbin/runc
            
            # 下载CNI插件
            echo "下载 CNI 插件 '"$CNI_VERSION"'..."
            mkdir -p /opt/cni/bin
            wget -q https://github.com/containernetworking/plugins/releases/download/'"$CNI_VERSION"'/cni-plugins-linux-amd64-'"$CNI_VERSION"'.tgz
            tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-'"$CNI_VERSION"'.tgz
            
            # 创建containerd配置
            mkdir -p /etc/containerd
            cat > /etc/containerd/config.toml << "EOFCONTAINERD"
version = 2
[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    sandbox_image = "registry.k8s.io/pause:3.9"
    [plugins."io.containerd.grpc.v1.cri".containerd]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true
EOFCONTAINERD
            
            # 创建containerd systemd服务
            cat > /etc/systemd/system/containerd.service << "EOFSVC"
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
EOFSVC
            
            # 启动containerd
            systemctl daemon-reload
            systemctl enable containerd
            systemctl start containerd
            
            # 从GitHub源码安装K8S组件
            echo "=== 安装K8S组件（从GitHub源码） ==="
            cd /tmp
            
            # 下载K8S二进制文件
            echo "下载 Kubernetes '"$K8S_VERSION"'..."
            wget -q https://github.com/kubernetes/kubernetes/releases/download/'"$K8S_VERSION"'/kubernetes-server-linux-amd64.tar.gz
            tar -xzf kubernetes-server-linux-amd64.tar.gz
            
            # 安装kubelet, kubeadm, kubectl
            cp kubernetes/server/bin/kubelet /usr/local/bin/
            cp kubernetes/server/bin/kubeadm /usr/local/bin/
            cp kubernetes/server/bin/kubectl /usr/local/bin/
            chmod +x /usr/local/bin/kube*
            
            # 创建kubelet systemd服务
            cat > /etc/systemd/system/kubelet.service << "EOFKUBELET"
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
EOFKUBELET
            
            # 创建kubelet配置目录
            mkdir -p /etc/systemd/system/kubelet.service.d
            cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf << "EOFKUBELETCONF"
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
Environment="KUBELET_SYSTEM_PODS_ARGS=--pod-manifest-path=/etc/kubernetes/manifests"
Environment="KUBELET_NETWORK_ARGS=--network-plugin=cni --cni-conf-dir=/etc/cni/net.d --cni-bin-dir=/opt/cni/bin"
Environment="KUBELET_DNS_ARGS=--cluster-dns=10.96.0.10 --cluster-domain=cluster.local"
Environment="KUBELET_AUTHZ_ARGS=--authorization-mode=Webhook --client-ca-file=/etc/kubernetes/pki/ca.crt"
Environment="KUBELET_CADVISOR_ARGS=--cadvisor-port=0"
Environment="KUBELET_CGROUP_ARGS=--cgroup-driver=systemd"
Environment="KUBELET_CERTIFICATE_ARGS=--rotate-certificates=true --cert-dir=/var/lib/kubelet/pki"
Environment="KUBELET_EXTRA_ARGS=--container-runtime-endpoint=unix:///var/run/containerd/containerd.sock"
ExecStart=
ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_SYSTEM_PODS_ARGS $KUBELET_NETWORK_ARGS $KUBELET_DNS_ARGS $KUBELET_AUTHZ_ARGS $KUBELET_CADVISOR_ARGS $KUBELET_CGROUP_ARGS $KUBELET_CERTIFICATE_ARGS $KUBELET_EXTRA_ARGS
EOFKUBELETCONF
            
            # 启动kubelet
            systemctl daemon-reload
            systemctl enable kubelet
            
            echo "容器运行时和K8S组件安装完成"
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

# 测试所有SSH连接
test_all_ssh() {
    log "测试所有虚拟机SSH连接..."
    
    local all_success=true
    
    for i in "${!VM_IPS[@]}"; do
        local ip="${VM_IPS[$i]}"
        local vm_name="${VM_NAMES[$i]}"
        
        log "测试 $vm_name ($ip) SSH连接..."
        
        if sshpass -p "$CLOUDINIT_PASS" ssh \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR \
            "$CLOUDINIT_USER@$ip" "echo 'SSH连接正常 - $(hostname)'" 2>/dev/null; then
            success "$vm_name SSH连接正常"
        else
            err "$vm_name SSH连接失败"
            all_success=false
        fi
    done
    
    if [[ "$all_success" == true ]]; then
        success "所有SSH连接测试通过"
    else
        warn "部分SSH连接存在问题，建议运行修复功能"
    fi
}

# 修复所有SSH连接
fix_all_ssh() {
    log "修复所有虚拟机SSH连接..."
    
    for i in "${!VM_IPS[@]}"; do
        local ip="${VM_IPS[$i]}"
        local vm_id="${VM_IDS[$i]}"
        local vm_name="${VM_NAMES[$i]}"
        
        log "修复 $vm_name ($ip) SSH连接..."
        
        if ! test_and_fix_ssh "$ip" "$vm_id"; then
            err "$vm_name SSH连接修复失败"
        fi
    done
    
    success "SSH连接修复完成"
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
    echo "║           PVE K8S + KubeSphere 一键部署工具 v3.1            ║"
    echo "║                    GitHub源码安装版                          ║"
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
    echo -e "${BLUE}诊断功能：${NC}"
    echo -e "  ${CYAN}11.${NC} 测试SSH连接"
    echo -e "  ${CYAN}12.${NC} 修复SSH连接"
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
                fix_k8s_network
                sleep 60
                fix_kubesphere
                sleep 30
                check_cluster_status
                success "一键修复完成！"
                ;;
            10) cleanup_all ;;
            11) test_all_ssh ;;
            12) fix_all_ssh ;;
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