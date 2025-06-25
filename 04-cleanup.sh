#!/bin/bash

# PVE KubeSphere 部署脚本 - 第四部分：清理和重置
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
PVE_HOST="10.0.0.1"
PVE_USER="root"
MASTER_IP="10.0.0.10"
WORKER_IPS=("10.0.0.11" "10.0.0.12")
ALL_NODES=("$MASTER_IP" "${WORKER_IPS[@]}")
VM_BASE_ID=100

# 确认清理操作
confirm_cleanup() {
    log_warn "警告：此操作将完全清理KubeSphere环境！"
    log_warn "包括："
    log_warn "- 删除所有Kubernetes集群数据"
    log_warn "- 删除所有虚拟机"
    log_warn "- 清理所有存储和网络配置"
    log_warn ""
    
    read -p "您确定要继续吗？(输入 'yes' 确认): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_info "操作已取消"
        exit 0
    fi
    
    log_info "开始清理操作..."
}

# 清理Kubernetes集群
cleanup_k8s_cluster() {
    log_step "清理Kubernetes集群..."
    
    # 在主节点上清理集群
    if ping -c 1 $MASTER_IP > /dev/null 2>&1; then
        log_info "在主节点上清理Kubernetes集群..."
        
        ssh root@$MASTER_IP << 'EOF'
            # 删除所有命名空间（除了系统命名空间）
            kubectl get namespaces --no-headers | grep -v "kube-system\|kube-public\|kube-node-lease\|default" | awk '{print $1}' | xargs -r kubectl delete namespace
            
            # 删除所有持久卷声明
            kubectl delete pvc --all --all-namespaces --ignore-not-found=true
            
            # 删除所有持久卷
            kubectl delete pv --all --ignore-not-found=true
            
            # 删除所有存储类
            kubectl delete storageclass --all --ignore-not-found=true
            
            # 重置kubeadm
            kubeadm reset -f
            
            # 清理iptables规则
            iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
            
            # 清理IPVS规则
            ipvsadm -C
            
            # 清理CNI配置
            rm -rf /etc/cni/net.d/*
            rm -rf /opt/cni/bin/*
            
            # 清理containerd
            ctr -n k8s.io containers list | awk '{print $1}' | xargs -r ctr -n k8s.io containers delete
            ctr -n k8s.io images list | awk '{print $1}' | xargs -r ctr -n k8s.io images delete
            
            # 清理kubelet配置
            rm -rf /var/lib/kubelet/*
            rm -rf /etc/kubernetes/*
            rm -rf ~/.kube
            
            # 停止并禁用kubelet
            systemctl stop kubelet
            systemctl disable kubelet
            
            # 卸载Kubernetes包
            apt remove -y kubelet kubeadm kubectl
            apt autoremove -y
            
            # 清理apt缓存
            apt clean
            
            log_info "主节点Kubernetes清理完成"
EOF
    fi
    
    # 在worker节点上清理
    for worker_ip in "${WORKER_IPS[@]}"; do
        if ping -c 1 $worker_ip > /dev/null 2>&1; then
            log_info "在worker节点 $worker_ip 上清理Kubernetes..."
            
            ssh root@$worker_ip << 'EOF'
                # 重置kubeadm
                kubeadm reset -f
                
                # 清理iptables规则
                iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
                
                # 清理IPVS规则
                ipvsadm -C
                
                # 清理CNI配置
                rm -rf /etc/cni/net.d/*
                rm -rf /opt/cni/bin/*
                
                # 清理containerd
                ctr -n k8s.io containers list | awk '{print $1}' | xargs -r ctr -n k8s.io containers delete
                ctr -n k8s.io images list | awk '{print $1}' | xargs -r ctr -n k8s.io images delete
                
                # 清理kubelet配置
                rm -rf /var/lib/kubelet/*
                rm -rf /etc/kubernetes/*
                
                # 停止并禁用kubelet
                systemctl stop kubelet
                systemctl disable kubelet
                
                # 卸载Kubernetes包
                apt remove -y kubelet kubeadm kubectl
                apt autoremove -y
                
                # 清理apt缓存
                apt clean
                
                log_info "Worker节点Kubernetes清理完成"
EOF
        fi
    done
}

# 清理containerd
cleanup_containerd() {
    log_step "清理containerd..."
    
    for node_ip in "${ALL_NODES[@]}"; do
        if ping -c 1 $node_ip > /dev/null 2>&1; then
            log_info "在节点 $node_ip 上清理containerd..."
            
            ssh root@$node_ip << 'EOF'
                # 停止containerd
                systemctl stop containerd
                systemctl disable containerd
                
                # 删除所有容器和镜像
                ctr containers list | awk '{print $1}' | xargs -r ctr containers delete
                ctr images list | awk '{print $1}' | xargs -r ctr images delete
                
                # 清理containerd数据
                rm -rf /var/lib/containerd/*
                rm -rf /run/containerd/*
                
                # 卸载containerd
                apt remove -y containerd.io
                apt autoremove -y
                
                # 清理Docker仓库
                rm -f /etc/apt/sources.list.d/docker.list
                rm -f /usr/share/keyrings/docker-archive-keyring.gpg
                
                log_info "containerd清理完成"
EOF
        fi
    done
}

# 清理系统配置
cleanup_system_config() {
    log_step "清理系统配置..."
    
    for node_ip in "${ALL_NODES[@]}"; do
        if ping -c 1 $node_ip > /dev/null 2>&1; then
            log_info "在节点 $node_ip 上清理系统配置..."
            
            ssh root@$node_ip << 'EOF'
                # 恢复swap
                sed -i '/#.*swap/s/^#//' /etc/fstab
                
                # 删除内核模块配置
                rm -f /etc/modules-load.d/containerd.conf
                rm -f /etc/sysctl.d/99-kubernetes-cri.conf
                
                # 删除hosts配置
                sed -i '/k8s-master/d' /etc/hosts
                sed -i '/k8s-worker1/d' /etc/hosts
                sed -i '/k8s-worker2/d' /etc/hosts
                
                # 清理bash配置
                sed -i '/kubectl completion/d' ~/.bashrc
                sed -i '/alias k=kubectl/d' ~/.bashrc
                sed -i '/complete -o default -F __start_kubectl k/d' ~/.bashrc
                
                # 清理临时文件
                rm -rf /tmp/*
                rm -rf /var/tmp/*
                
                # 清理日志
                journalctl --vacuum-time=1d
                
                log_info "系统配置清理完成"
EOF
        fi
    done
}

# 停止和删除虚拟机
cleanup_vms() {
    log_step "停止和删除虚拟机..."
    
    if ping -c 1 $PVE_HOST > /dev/null 2>&1; then
        log_info "在PVE主机上清理虚拟机..."
        
        ssh $PVE_USER@$PVE_HOST << EOF
            # 停止虚拟机
            for i in {100..102}; do
                if qm status \$i > /dev/null 2>&1; then
                    log_info "停止虚拟机 \$i"
                    qm stop \$i
                    sleep 5
                fi
            done
            
            # 删除虚拟机
            for i in {100..102}; do
                if qm status \$i > /dev/null 2>&1; then
                    log_info "删除虚拟机 \$i"
                    qm destroy \$i
                fi
            done
            
            # 清理模板文件
            rm -f /var/lib/vz/template/cache/debian-12-standard_12.2-1_amd64.tar.zst
            
            # 清理未使用的磁盘
            pvesm cleanup
            
            log_info "虚拟机清理完成"
EOF
    fi
}

# 清理网络配置
cleanup_network() {
    log_step "清理网络配置..."
    
    if ping -c 1 $PVE_HOST > /dev/null 2>&1; then
        log_info "在PVE主机上清理网络配置..."
        
        ssh $PVE_USER@$PVE_HOST << 'EOF'
            # 清理防火墙规则
            iptables -F
            iptables -t nat -F
            iptables -t mangle -F
            iptables -X
            
            # 重启网络服务
            systemctl restart networking
            
            log_info "网络配置清理完成"
EOF
    fi
}

# 清理本地文件
cleanup_local_files() {
    log_step "清理本地文件..."
    
    # 删除生成的文件
    rm -f hosts.txt
    rm -f join-command.txt
    rm -f cluster-info.txt
    rm -f kubesphere-deployment-report.txt
    
    # 删除日志文件
    rm -f *.log
    
    log_info "本地文件清理完成"
}

# 重置系统（可选）
reset_system() {
    log_step "重置系统配置..."
    
    read -p "是否要重置系统配置到初始状态？(输入 'yes' 确认): " reset_confirm
    
    if [ "$reset_confirm" = "yes" ]; then
        for node_ip in "${ALL_NODES[@]}"; do
            if ping -c 1 $node_ip > /dev/null 2>&1; then
                log_info "重置节点 $node_ip 系统配置..."
                
                ssh root@$node_ip << 'EOF'
                    # 重置主机名
                    echo "debian" > /etc/hostname
                    hostnamectl set-hostname debian
                    
                    # 重置网络配置
                    cat > /etc/network/interfaces << 'INTERFACES'
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
auto eth0
iface eth0 inet dhcp
INTERFACES
                    
                    # 重启网络
                    systemctl restart networking
                    
                    # 清理用户数据
                    rm -rf /home/*
                    rm -rf /root/.kube
                    rm -rf /root/.helm
                    
                    log_info "系统重置完成"
EOF
            fi
        done
    fi
}

# 生成清理报告
generate_cleanup_report() {
    log_step "生成清理报告..."
    
    cat > cleanup-report.txt << EOF
# KubeSphere环境清理报告
# 生成时间: $(date)

## 清理内容
- Kubernetes集群数据
- containerd容器和镜像
- 系统配置文件
- 虚拟机实例
- 网络配置
- 本地文件

## 清理状态
- 主节点 (10.0.0.10): 已清理
- Worker节点1 (10.0.0.11): 已清理
- Worker节点2 (10.0.0.12): 已清理
- PVE主机 (10.0.0.1): 已清理

## 注意事项
1. 所有数据已被永久删除
2. 如需重新部署，请重新运行安装脚本
3. 建议在重新部署前重启所有节点

## 重新部署步骤
1. 运行 01-pve-prepare.sh 准备PVE环境
2. 运行 02-k8s-install.sh 安装Kubernetes
3. 运行 03-kubesphere-install.sh 安装KubeSphere

清理完成！环境已重置到初始状态。
EOF
    
    log_info "清理报告已生成: cleanup-report.txt"
}

# 主函数
main() {
    log_info "开始KubeSphere环境清理..."
    
    confirm_cleanup
    cleanup_k8s_cluster
    cleanup_containerd
    cleanup_system_config
    cleanup_vms
    cleanup_network
    cleanup_local_files
    reset_system
    generate_cleanup_report
    
    log_info "KubeSphere环境清理完成！"
    log_info "所有数据已被删除，环境已重置。"
    log_info "如需重新部署，请重新运行安装脚本。"
}

# 执行主函数
main "$@" 