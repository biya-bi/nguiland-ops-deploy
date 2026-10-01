#!/usr/bin/env bash
set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${scripts_dir}/logger.sh"

SSH_PORT=22
POD_CIDR="10.244.0.0/16"

logger::info "--- 1. SSH SAFETY & PURGE ---"
sudo iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /etc/kubernetes /var/lib/etcd /var/lib/kubelet $HOME/.kube

logger::info "--- 2. NETWORK RESET ---"
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT
sudo iptables -t nat -F
sudo iptables -F
sudo iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT

logger::info "--- 3. KUBEADM INIT ---"
sudo kubeadm init --pod-network-cidr=$POD_CIDR
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

logger::info "--- 4. UNTAINT & LABEL ---"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
kubectl label nodes --all builtin.csi.k8s.io/hostpath=true --overwrite

logger::info "--- 5. INSTALL FLANNEL ---"
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

logger::info "--- 5.1 REFRESHING RUNTIME & KUBELET ---"
# Give Flannel a moment to write the CNI config file to /etc/cni/net.d/
sleep 5 
sudo systemctl restart containerd
sudo systemctl restart kubelet

logger::info "--- 6. WAIT FOR NODE READY ---"
logger::info "Waiting for node to be Ready..."
until kubectl get nodes | grep -w "Ready"; do
  echo -n "."
  sleep 2
done
echo
logger::info "Node is Ready!"

logger::info "--- 7. INSTALL STORAGE (CSI v1.17.1) ---"
TAG="v1.17.1"
BASE_URL="https://raw.githubusercontent.com/kubernetes-csi/csi-driver-host-path/$TAG/deploy/kubernetes-1.30/hostpath"

kubectl apply -f "$BASE_URL/csi-hostpath-driverinfo.yaml"
kubectl apply -f "$BASE_URL/csi-hostpath-plugin.yaml"
kubectl apply -f "$BASE_URL/csi-hostpath-testing.yaml"

# Apply Global Tolerations to the CSI pods so they schedule regardless of taints
kubectl patch statefulset csi-hostpathplugin -p '{"spec":{"template":{"spec":{"tolerations":[{"operator":"Exists"}]}}}}'
kubectl patch statefulset csi-hostpath-socat -p '{"spec":{"template":{"spec":{"tolerations":[{"operator":"Exists"}]}}}}'

# StorageClass Setup
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-host-path/$TAG/examples/csi-storageclass.yaml"
kubectl patch storageclass csi-hostpath-sc -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

logger::info "--- RESET & REINSTALL COMPLETE ---"
