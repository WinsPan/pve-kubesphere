#!/bin/bash

# 极简一键PVE K8S+KubeSphere全自动部署脚本（异常处理增强版）
# 功能：自动下载最新Debian ISO，创建3台KVM虚拟机（cloud-init无人值守），批量启动、检测、SSH初始化，自动K8S集群安装，自动KubeSphere部署
# 默认参数：local-lvm, vmbr0, 3台8核16G 300G, 最新Debian, root/kubesphere123

set -e

LOGFILE="deploy.log"
exec > >(tee -a "$LOGFILE") 2>&1

trap 'err "脚本被中断或发生致命错误。请检查deploy.log，必要时清理部分资源后重试。"; exit 1' INT TERM

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; }

# 自动获取最新Debian netinst ISO文件名
log "自动获取最新Debian ISO信息..."
LATEST_ISO=$(wget -qO- https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ | grep -oE 'debian-[0-9.]+-amd64-netinst\.iso' | head -n1)
if [ -z "$LATEST_ISO" ]; then
  err "无法自动获取最新Debian ISO文件名，请检查网络或手动指定。"
  echo -e "\n[解决方法] 请检查网络连接，或手动访问 https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/ 获取最新ISO文件名\n"
  exit 1
fi
log "检测到最新Debian ISO: $LATEST_ISO"

# 配置
ISO_URLS=(
  "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/$LATEST_ISO"
  "https://mirrors.ustc.edu.cn/debian-cd/current/amd64/iso-cd/$LATEST_ISO"
  "https://mirrors.tuna.tsinghua.edu.cn/debian-cd/current/amd64/iso-cd/$LATEST_ISO"
)
ISO_FILE="$LATEST_ISO"
ISO_PATH="/var/lib/vz/template/iso/$ISO_FILE"
STORAGE="local-lvm"
BRIDGE="vmbr0"
VM_IDS=(101 102 103)
VM_NAMES=("k8s-master" "k8s-worker1" "k8s-worker2")
VM_IPS=("10.0.0.10" "10.0.0.11" "10.0.0.12")
VM_CORES=8
VM_MEM=16384
VM_DISK=300
CLOUDINIT_USER="root"
CLOUDINIT_PASS="kubesphere123"
GATEWAY="10.0.0.1"
DNS="10.0.0.2 119.29.29.29"

MASTER_IP="10.0.0.10"
WORKER_IPS=("10.0.0.11" "10.0.0.12")

# 检查依赖
for cmd in qm wget sshpass nc; do
  if ! command -v $cmd &>/dev/null; then
    err "缺少依赖: $cmd，请先安装！"
    echo -e "\n[解决方法] 运行: apt update && apt install -y $cmd\n"
    exit 1
  fi
done

wait_for_ssh() {
  local ip=$1
  local max_try=30
  local try=0
  while ((try < max_try)); do
    if ping -c 1 -W 2 $ip &>/dev/null && nc -z $ip 22 &>/dev/null; then
      return 0
    fi
    sleep 5
    ((try++))
    log "等待 $ip SSH可用... ($try/$max_try)"
  done
  err "$ip SSH不可用，可能原因：\n- 虚拟机未获取到IP\n- cloud-init未生效或root密码未设置\n- 网络未通或防火墙阻断"
  exit 1
}

wait_for_port() {
  local ip=$1
  local port=$2
  local max_try=60
  local try=0
  while ((try < max_try)); do
    if nc -z $ip $port &>/dev/null; then
      return 0
    fi
    sleep 10
    ((try++))
    log "等待 $ip:$port 可用... ($try/$max_try)"
  done
  err "$ip:$port 未开放，可能原因：\n- KubeSphere服务未启动或安装失败\n- 网络/防火墙阻断\n- 资源不足导致服务未正常运行"
  exit 1
}

# 下载ISO，多源重试
log "检查Debian ISO..."
if [ ! -f "$ISO_PATH" ]; then
  log "尝试多源下载最新Debian ISO: $ISO_FILE"
  ISO_OK=0
  for url in "${ISO_URLS[@]}"; do
    log "尝试下载: $url"
    if wget -O "$ISO_PATH" "$url"; then
      ISO_OK=1
      break
    else
      warn "下载失败: $url"
    fi
  done
  if [ $ISO_OK -ne 1 ]; then
    err "ISO下载多次失败，请检查网络或手动下载到 $ISO_PATH"
    echo -e "\n[手动下载建议] 访问以下任一链接手动下载："
    for url in "${ISO_URLS[@]}"; do
      echo "  $url"
    done
    echo -e "\n下载完成后，将文件重命名为 $ISO_FILE 并放置到 $ISO_PATH\n"
    exit 1
  fi
else
  log "ISO已存在: $ISO_PATH"
fi

# 创建虚拟机
for idx in ${!VM_IDS[@]}; do
  id=${VM_IDS[$idx]}
  name=${VM_NAMES[$idx]}
  ip=${VM_IPS[$idx]}
  log "处理虚拟机 $name (ID:$id, IP:$ip) ..."
  if qm list | grep -q " $id "; then
    warn "虚拟机 $id 已存在，跳过创建"
    continue
  fi
  if ! qm create $id \
    --name $name \
    --memory $VM_MEM \
    --cores $VM_CORES \
    --net0 virtio,bridge=$BRIDGE \
    --scsihw virtio-scsi-pci \
    --serial0 socket \
    --agent 1; then
    err "创建虚拟机 $id 失败，请检查PVE资源和配置"
    exit 1
  fi
  if ! qm disk create $id $VM_DISK --storage $STORAGE --scsi0; then
    err "创建磁盘失败 $id，请检查存储空间"
    exit 1
  fi
  qm set $id --scsi0 $STORAGE:vm-$id-disk-0
  qm set $id --ide2 local:iso/$ISO_FILE,media=cdrom
  qm set $id --ide3 $STORAGE:cloudinit
  qm set $id --ciuser $CLOUDINIT_USER --cipassword $CLOUDINIT_PASS
  qm set $id --ipconfig0 ip=$ip/24,gw=$GATEWAY
  qm set $id --nameserver "$DNS"
  qm set $id --boot order=ide2,scsi0
  qm set $id --onboot 1
done

# 启动虚拟机
log "批量启动虚拟机..."
for id in "${VM_IDS[@]}"; do
  status=$(qm list | awk -v id="$id" '$1==id{print $3}')
  if [ "$status" = "running" ]; then
    warn "虚拟机 $id 已在运行，跳过"
  else
    log "启动虚拟机 $id ..."
    if ! qm start $id; then
      err "启动虚拟机 $id 失败，请检查PVE资源和配置"
      exit 1
    fi
    sleep 5
  fi
done

# 等待所有虚拟机SSH可用
for idx in ${!VM_IDS[@]}; do
  ip=${VM_IPS[$idx]}
  wait_for_ssh $ip
  log "虚拟机 $ip SSH已就绪"
done

# SSH初始化
log "批量SSH初始化..."
for idx in ${!VM_IDS[@]}; do
  name=${VM_NAMES[$idx]}
  ip=${VM_IPS[$idx]}
  log "初始化 $name ($ip) ..."
  remote_cmd="hostnamectl set-hostname $name && apt-get update -y && apt-get install -y vim curl wget net-tools lsb-release sudo openssh-server && echo '初始化完成: $name'"
  if ! sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 $CLOUDINIT_USER@$ip "$remote_cmd"; then
    err "$name 初始化失败，命令: $remote_cmd"
    echo "[建议] 检查网络、cloud-init、root密码、PVE模板配置等。"
    exit 1
  fi
  log "$name 初始化成功"
done

# K8S和KubeSphere自动部署
log "\n开始K8S集群和KubeSphere自动部署..."

# 1. master节点初始化K8S（重试3次）
log "[K8S] master节点初始化..."
K8S_INIT_OK=0
for try in {1..3}; do
  remote_cmd="apt-get update -y && apt-get install -y apt-transport-https ca-certificates curl gnupg2 software-properties-common && curl -fsSL https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | apt-key add - && echo 'deb https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main' > /etc/apt/sources.list.d/kubernetes.list && apt-get update -y && apt-get install -y kubelet kubeadm kubectl && swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab && kubeadm init --pod-network-cidr=192.168.0.0/16 --apiserver-advertise-address=$MASTER_IP --ignore-preflight-errors=NumCPU --ignore-preflight-errors=Mem && mkdir -p /root/.kube && cp /etc/kubernetes/admin.conf /root/.kube/config && kubectl taint nodes --all node-role.kubernetes.io/control-plane- && kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml && echo 'K8S master初始化完成'"
  if sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "$remote_cmd"; then
    K8S_INIT_OK=1
    break
  fi
  warn "K8S master初始化失败，重试($try/3)，命令: $remote_cmd"
  sleep 20
done
[ $K8S_INIT_OK -eq 1 ] || { err "K8S master初始化最终失败"; exit 1; }

# 2. 获取join命令（重试）
JOIN_CMD=""
for try in {1..10}; do
  JOIN_CMD=$(sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "kubeadm token create --print-join-command" 2>/dev/null || true)
  if [[ $JOIN_CMD == kubeadm* ]]; then
    break
  fi
  warn "获取join命令失败，重试($try/10)"
  sleep 10
done
if [[ ! $JOIN_CMD == kubeadm* ]]; then
  err "无法获取K8S join命令，终止"
  exit 1
fi

# 3. worker节点加入集群（重试）
for ip in "${WORKER_IPS[@]}"; do
  log "[K8S] $ip 加入集群..."
  JOIN_OK=0
  for try in {1..3}; do
    remote_cmd="apt-get update -y && apt-get install -y apt-transport-https ca-certificates curl gnupg2 software-properties-common && curl -fsSL https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | apt-key add - && echo 'deb https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main' > /etc/apt/sources.list.d/kubernetes.list && apt-get update -y && apt-get install -y kubelet kubeadm kubectl && swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab && $JOIN_CMD --ignore-preflight-errors=NumCPU --ignore-preflight-errors=Mem && echo 'K8S worker加入完成'"
    if sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$ip "$remote_cmd"; then
      JOIN_OK=1
      break
    fi
    warn "$ip 加入集群失败，重试($try/3)，命令: $remote_cmd"
    sleep 20
  done
  [ $JOIN_OK -eq 1 ] || { err "$ip 加入集群最终失败"; exit 1; }
done

# 4. 检查K8S集群状态
log "[K8S] 检查集群状态..."
if ! sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "kubectl get nodes -o wide && kubectl get pods -A"; then
  err "K8S集群状态异常，请检查deploy.log和K8S安装日志"
  exit 1
fi

# 5. 安装KubeSphere
log "[KubeSphere] master节点安装KubeSphere..."
remote_cmd="curl -sfL https://get-ks.ksops.io | sh && ./kk create cluster -f ./config-sample.yaml || ./kk create cluster"
if ! sshpass -p "$CLOUDINIT_PASS" ssh -o StrictHostKeyChecking=no $CLOUDINIT_USER@$MASTER_IP "$remote_cmd"; then
  err "KubeSphere安装失败，命令: $remote_cmd"
  echo "[建议] 检查KubeSphere安装日志、PVE资源、网络等。"
  exit 1
fi

# 6. 检查KubeSphere端口
wait_for_port $MASTER_IP 30880
log "KubeSphere控制台: http://$MASTER_IP:30880 (首次访问需等待几分钟)"
log "默认用户名: admin，密码: P@88w0rd"
log "全部自动化部署完成，详细日志见 $LOGFILE" 