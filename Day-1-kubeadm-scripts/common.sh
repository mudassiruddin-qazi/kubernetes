#!/bin/bash
#
# Common setup for all servers (Control Plane and Nodes)

set -euxo pipefail

# Kubernetes Variable Declaration
KUBERNETES_VERSION="v1.30"
CRIO_VERSION="v1.30"
KUBERNETES_INSTALL_VERSION="1.30.0-1.1"

# Disable swap
sudo swapoff -a

# Keeps the swap off during reboot
(crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a") | crontab - || true
sudo apt-get update -qq

# Ensure required kernel modules are loaded
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Verify kernel modules are loaded
for module in overlay br_netfilter; do
    if ! lsmod | grep -q "$module"; then
        echo "Error: Kernel module $module is not loaded!" >&2
        exit 1
    fi
done

# Sysctl params required by setup, persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

sudo apt-get update -qq
sudo apt-get install -y -qq apt-transport-https ca-certificates curl gpg software-properties-common

# Install CRI-O Runtime
sudo mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key | \
    sudo gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/ /" | \
    sudo tee /etc/apt/sources.list.d/cri-o.list

sudo apt-get update -qq
sudo apt-get install -y -qq cri-o

sudo systemctl daemon-reload
sudo systemctl enable crio --now
sudo systemctl restart crio

# Verify CRI-O installation
if ! command -v crio >/dev/null 2>&1; then
    echo "Error: CRI-O installation failed" >&2
    exit 1
fi

# Ensure CRI-O socket exists
if [ ! -S /var/run/crio/crio.sock ]; then
    echo "Error: CRI-O socket not found!" >&2
    exit 1
fi

# Configure crictl to use CRI-O
cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///var/run/crio/crio.sock
EOF

# Install kubelet, kubectl, and kubeadm
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key | \
    sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" | \
    sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -qq
sudo apt-get install -y -qq kubelet="$KUBERNETES_INSTALL_VERSION" kubectl="$KUBERNETES_INSTALL_VERSION" kubeadm="$KUBERNETES_INSTALL_VERSION"

# Prevent automatic updates for kubelet, kubeadm, and kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Verify kubeadm installation
if ! command -v kubeadm >/dev/null 2>&1; then
    echo "Error: kubeadm installation failed, attempting manual download..."
    sudo curl -LO https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubeadm
    sudo chmod +x kubeadm
    sudo mv kubeadm /usr/local/bin/
fi

# Install jq (JSON processor)
sudo apt-get install -y -qq jq

# Detect primary network interface and retrieve local IP address
local_ip=$(hostname -I | awk '{print $1}')

# Write the local IP address to the kubelet default configuration file
sudo bash -c "cat > /etc/default/kubelet << EOF
KUBELET_EXTRA_ARGS=--node-ip=$local_ip
EOF"

# Restart kubelet to apply node IP configuration
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# Final verification
if ! command -v kubeadm >/dev/null 2>&1; then
    echo "Critical Error: kubeadm still not found after reinstallation." >&2
    exit 1
fi

echo "✅ Kubernetes node setup completed successfully!"
