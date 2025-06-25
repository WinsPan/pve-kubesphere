#!/bin/bash

# PVE KubeSphere 部署脚本 - 第三部分：KubeSphere安装
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
KUBESPHERE_VERSION="v4.1.3"
KUBESPHERE_PORT="30880"

# 检查主节点连接
check_master_connection() {
    log_step "检查主节点连接..."
    
    if ! ping -c 1 $MASTER_IP > /dev/null 2>&1; then
        log_error "无法连接到主节点 $MASTER_IP"
        exit 1
    fi
    
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes root@$MASTER_IP "echo '连接成功'" > /dev/null 2>&1; then
        log_error "无法SSH连接到主节点 $MASTER_IP"
        exit 1
    fi
    
    log_info "主节点连接正常"
}

# 检查Kubernetes集群状态
check_k8s_cluster() {
    log_step "检查Kubernetes集群状态..."
    
    local check_cmd="
        # 检查节点状态
        echo '=== 节点状态 ==='
        kubectl get nodes
        
        # 检查pod状态
        echo '=== Pod状态 ==='
        kubectl get pods --all-namespaces
        
        # 检查集群信息
        echo '=== 集群信息 ==='
        kubectl cluster-info
        
        # 检查存储类
        echo '=== 存储类 ==='
        kubectl get storageclass
    "
    
    log_info "在主节点上检查集群状态..."
    ssh root@$MASTER_IP "$check_cmd"
}

# 安装OpenEBS本地存储
install_openebs() {
    log_step "安装OpenEBS本地存储..."
    
    local openebs_cmd="
        # 添加OpenEBS Helm仓库
        helm repo add openebs https://openebs.github.io/charts
        helm repo update
        
        # 安装OpenEBS
        helm install openebs openebs/openebs \\
            --namespace openebs \\
            --create-namespace \\
            --set localprovisioner.enabled=true \\
            --set localprovisioner.basePath=/var/openebs/local \\
            --set ndm.enabled=false \\
            --set ndmOperator.enabled=false
        
        # 等待OpenEBS就绪
        kubectl wait --for=condition=ready pod -l app=openebs-localpv-provisioner -n openebs --timeout=300s
        
        # 设置默认存储类
        kubectl patch storageclass openebs-hostpath -p '{\"metadata\": {\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'
        
        # 验证存储类
        kubectl get storageclass
    "
    
    log_info "在主节点上安装OpenEBS..."
    ssh root@$MASTER_IP "$openebs_cmd"
}

# 安装Helm
install_helm() {
    log_step "安装Helm..."
    
    local helm_cmd="
        # 下载Helm
        curl https://get.helm.sh/helm-v3.12.0-linux-amd64.tar.gz -o helm.tar.gz
        
        # 解压Helm
        tar -xzf helm.tar.gz
        
        # 移动Helm到系统路径
        mv linux-amd64/helm /usr/local/bin/
        
        # 清理临时文件
        rm -rf linux-amd64 helm.tar.gz
        
        # 验证安装
        helm version
        
        # 配置Helm
        helm repo add stable https://charts.helm.sh/stable
        helm repo update
    "
    
    log_info "在主节点上安装Helm..."
    ssh root@$MASTER_IP "$helm_cmd"
}

# 安装KubeSphere
install_kubesphere() {
    log_step "安装KubeSphere..."
    
    local kubesphere_cmd="
        # 下载KubeSphere安装脚本
        curl -L https://kubesphere.io/download/stable/$KUBESPHERE_VERSION > kubesphere-installer.yaml
        
        # 下载KubeSphere配置文件
        curl -L https://kubesphere.io/download/stable/$KUBESPHERE_VERSION > kubesphere-config.yaml
        
        # 修改配置文件
        cat > kubesphere-config.yaml << 'EOF'
apiVersion: installer.kubesphere.io/v1alpha1
kind: ClusterConfiguration
metadata:
  name: ks-installer
  namespace: kubesphere-system
  labels:
    version: $KUBESPHERE_VERSION
spec:
  zone: ""
  local_registry: ""
  etcd:
    monitoring: false
    endpointIps: localhost
    port: 2379
    tlsEnable: true
  common:
    core:
      console:
        enableMultiLogin: true
        port: 30880
        type: NodePort
    apiserver:
      enable: true
    controllerManager:
      enable: true
    redis:
      enable: false
    openldap:
      enable: false
    minioVolumeSize: 2Gi
    monitoring:
      endpoint: http://prometheus-operated.kubesphere-monitoring-system.svc:9090
    gpu:
      enable: false
  authentication:
    jwtSecret: ""
    authenticateRateLimiterMaxTries: 10
    authenticateRateLimiterDuration: 10m
    oauthOptions:
      accessTokenMaxAge: 1h
      accessTokenInactivityTimeout: 30m
  audit:
    enable: false
  devops:
    enable: false
    jenkinsMemoryLim: 2Gi
    jenkinsMemoryReq: 1500Mi
    jenkinsVolumeSize: 8Gi
    jenkinsJavaOpts_Xms: 512m
    jenkinsJavaOpts_Xmx: 512m
    jenkinsJavaOpts_MaxRAM: 2g
  events:
    enable: false
    ruler:
      enabled: true
      replicas: 2
  logging:
    enable: false
    elasticsearchMasterReplicas: 1
    elasticsearchDataReplicas: 1
    logsidecarReplicas: 2
    elasticsearchMasterVolumeSize: 4Gi
    elasticsearchDataVolumeSize: 20Gi
    logMaxAge: 7
    elkPrefix: logstash
    containersLogMountedPath: ""
    kibana:
      enable: false
  metrics_server:
    enable: false
  monitoring:
    enable: false
    prometheusMemoryRequest: 400Mi
    prometheusVolumeSize: 20Gi
    grafana:
      enable: false
  multicluster:
    enable: false
  network:
    enable: false
    networkpolicy:
      enable: false
    ippool:
      type: none
    topology:
      type: none
  notification:
    enable: false
  openpitrix:
    enable: false
  servicemesh:
    enable: false
  terminal:
    enable: false
  alerting:
    enable: false
    alertmanagerReplicas: 1
    wechat:
      enabled: false
    dingtalk:
      enabled: false
    slack:
      enabled: false
    webhook:
      enabled: false
EOF
        
        # 应用KubeSphere安装器
        kubectl apply -f kubesphere-installer.yaml
        
        # 应用KubeSphere配置
        kubectl apply -f kubesphere-config.yaml
        
        # 等待KubeSphere安装器就绪
        kubectl wait --for=condition=ready pod -l app=ks-install -n kubesphere-system --timeout=300s
        
        # 检查安装进度
        kubectl logs -n kubesphere-system $(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath='{.items[0].metadata.name}') -f
    "
    
    log_info "在主节点上安装KubeSphere..."
    ssh root@$MASTER_IP "$kubesphere_cmd"
}

# 等待KubeSphere安装完成
wait_for_kubesphere() {
    log_step "等待KubeSphere安装完成..."
    
    local wait_cmd="
        # 检查KubeSphere安装状态
        kubectl get pod -n kubesphere-system
        
        # 检查KubeSphere控制台
        kubectl get svc -n kubesphere-system ks-console
        
        # 获取访问信息
        echo '=== KubeSphere访问信息 ==='
        kubectl get svc -n kubesphere-system ks-console -o jsonpath='{.spec.ports[0].nodePort}'
        
        # 检查所有KubeSphere组件
        kubectl get pod -n kubesphere-system --field-selector=status.phase=Running
    "
    
    log_info "检查KubeSphere安装状态..."
    ssh root@$MASTER_IP "$wait_cmd"
    
    log_info "KubeSphere安装可能需要10-30分钟，请耐心等待..."
    log_info "您可以通过以下命令查看安装进度："
    log_info "ssh root@$MASTER_IP 'kubectl logs -n kubesphere-system \$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath=\"{.items[0].metadata.name}\") -f'"
}

# 配置KubeSphere访问
configure_access() {
    log_step "配置KubeSphere访问..."
    
    local access_cmd="
        # 获取NodePort端口
        NODEPORT=\$(kubectl get svc -n kubesphere-system ks-console -o jsonpath='{.spec.ports[0].nodePort}')
        
        # 创建访问信息文件
        cat > kubesphere-access.txt << EOF
# KubeSphere访问信息
# 生成时间: \$(date)

## 访问地址
- 控制台地址: http://$MASTER_IP:\$NODEPORT
- 默认用户名: admin
- 默认密码: P@88w0rd

## 获取密码命令
kubectl get secret -n kubesphere-system ks-console-secret -o jsonpath='{.data.password}' | base64 -d

## 常用命令
- 查看安装状态: kubectl get pod -n kubesphere-system
- 查看服务: kubectl get svc -n kubesphere-system
- 查看日志: kubectl logs -n kubesphere-system \$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath='{.items[0].metadata.name}')

## 端口转发（如果需要）
kubectl port-forward -n kubesphere-system svc/ks-console 30880:80
EOF
        
        # 获取默认密码
        PASSWORD=\$(kubectl get secret -n kubesphere-system ks-console-secret -o jsonpath='{.data.password}' | base64 -d)
        echo \"默认密码: \$PASSWORD\" >> kubesphere-access.txt
        
        # 显示访问信息
        echo \"=== KubeSphere访问信息 ===\"
        echo \"控制台地址: http://$MASTER_IP:\$NODEPORT\"
        echo \"默认用户名: admin\"
        echo \"默认密码: \$PASSWORD\"
    "
    
    log_info "配置KubeSphere访问..."
    ssh root@$MASTER_IP "$access_cmd"
}

# 安装常用工具
install_tools() {
    log_step "安装常用工具..."
    
    local tools_cmd="
        # 安装k9s（Kubernetes CLI工具）
        wget https://github.com/derailed/k9s/releases/download/v0.27.3/k9s_Linux_amd64.tar.gz
        tar -xzf k9s_Linux_amd64.tar.gz
        mv k9s /usr/local/bin/
        rm k9s_Linux_amd64.tar.gz
        
        # 安装kubectx和kubens
        git clone https://github.com/ahmetb/kubectx /opt/kubectx
        ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx
        ln -s /opt/kubectx/kubens /usr/local/bin/kubens
        
        # 安装krew
        (
            set -x; cd \"\$(mktemp -d)\" &&
            OS=\"\$(uname | tr '[:upper:]' '[:lower:]')\" &&
            ARCH=\"\$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\\(arm\\)\\(64\\)\\?.*/\\1\\2/' -e 's/aarch64$/arm64/')\" &&
            KREW=\"krew-\${OS}_\${ARCH}\" &&
            curl -fsSLO \"https://github.com/kubernetes-sigs/krew/releases/latest/download/\${KREW}.tar.gz\" &&
            tar zxvf \"\${KREW}.tar.gz\" &&
            ./\"\${KREW}\" install krew
        )
        
        # 添加krew到PATH
        echo 'export PATH=\"\${KREW_ROOT:-\\$HOME/.krew}/bin:\$PATH\"' >> ~/.bashrc
        export PATH=\"\${KREW_ROOT:-\\$HOME/.krew}/bin:\$PATH\"
        
        # 安装kubectl插件
        kubectl krew install ctx
        kubectl krew install ns
        kubectl krew install tree
        
        # 验证工具安装
        k9s version
        kubectx --help
        kubens --help
    "
    
    log_info "在主节点上安装常用工具..."
    ssh root@$MASTER_IP "$tools_cmd"
}

# 创建示例应用
create_sample_app() {
    log_step "创建示例应用..."
    
    local sample_cmd="
        # 创建示例命名空间
        kubectl create namespace demo
        
        # 部署nginx示例
        kubectl create deployment nginx --image=nginx:alpine -n demo
        
        # 创建服务
        kubectl expose deployment nginx --port=80 --target-port=80 --type=NodePort -n demo
        
        # 获取服务信息
        kubectl get svc -n demo
        
        # 创建示例配置文件
        cat > sample-apps.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
  namespace: demo
spec:
  type: NodePort
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30080
EOF
        
        # 应用示例配置
        kubectl apply -f sample-apps.yaml
        
        echo \"示例应用已创建在demo命名空间中\"
    "
    
    log_info "创建示例应用..."
    ssh root@$MASTER_IP "$sample_cmd"
}

# 生成最终部署报告
generate_deployment_report() {
    log_step "生成部署报告..."
    
    cat > kubesphere-deployment-report.txt << EOF
# KubeSphere部署完成报告
# 生成时间: $(date)

## 部署概览
- PVE主机: 10.0.0.1
- Kubernetes版本: v1.28.0
- KubeSphere版本: $KUBESPHERE_VERSION
- 集群节点: 3个 (1个master + 2个worker)

## 节点信息
- Master节点: 10.0.0.10
- Worker节点1: 10.0.0.11
- Worker节点2: 10.0.0.12

## 访问信息
- KubeSphere控制台: http://10.0.0.10:30880
- 默认用户名: admin
- 默认密码: P@88w0rd

## 已安装组件
- Kubernetes v1.28.0
- Calico网络插件
- OpenEBS本地存储
- Helm v3.12.0
- KubeSphere $KUBESPHERE_VERSION

## 常用命令
- 查看节点: kubectl get nodes
- 查看pods: kubectl get pods --all-namespaces
- 查看服务: kubectl get svc --all-namespaces
- 访问KubeSphere: kubectl port-forward -n kubesphere-system svc/ks-console 30880:80

## 下一步操作
1. 访问KubeSphere控制台
2. 配置存储和网络
3. 部署应用程序
4. 配置监控和日志

## 故障排除
- 查看安装日志: kubectl logs -n kubesphere-system \$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath='{.items[0].metadata.name}')
- 检查节点状态: kubectl describe nodes
- 检查pod状态: kubectl describe pods -n kubesphere-system

## 备份和恢复
- 备份etcd: etcdctl snapshot save backup.db
- 备份配置: kubectl get all --all-namespaces -o yaml > backup.yaml

部署完成！KubeSphere已成功安装在您的PVE环境中。
EOF
    
    log_info "部署报告已生成: kubesphere-deployment-report.txt"
}

# 主函数
main() {
    log_info "开始KubeSphere安装..."
    
    check_master_connection
    check_k8s_cluster
    install_helm
    install_openebs
    install_kubesphere
    wait_for_kubesphere
    configure_access
    install_tools
    create_sample_app
    generate_deployment_report
    
    log_info "KubeSphere安装完成！"
    log_info ""
    log_info "=== 访问信息 ==="
    log_info "控制台地址: http://$MASTER_IP:$KUBESPHERE_PORT"
    log_info "默认用户名: admin"
    log_info "默认密码: P@88w0rd"
    log_info ""
    log_info "=== 常用命令 ==="
    log_info "查看安装状态: ssh root@$MASTER_IP 'kubectl get pod -n kubesphere-system'"
    log_info "查看安装日志: ssh root@$MASTER_IP 'kubectl logs -n kubesphere-system \$(kubectl get pod -n kubesphere-system -l app=ks-install -o jsonpath=\"{.items[0].metadata.name}\") -f'"
    log_info ""
    log_info "部署完成！请访问KubeSphere控制台开始使用。"
}

# 执行主函数
main "$@" 