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
sudo apt-get update -y

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

sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Install CRI-O Runtime
sudo apt-get update -y
sudo apt-get install -y software-properties-common curl apt-transport-https ca-certificates

# Ensure the APT keyring directory exists
sudo mkdir -p /etc/apt/keyrings

# Add the CRI-O repository key
curl -fsSL https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/Release.key | \
    sudo gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg

# Add CRI-O repository
echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/stable:/$CRIO_VERSION/deb/ /" | \
    sudo tee /etc/apt/sources.list.d/cri-o.list

sudo apt-get update -y
sudo apt-get install -y cri-o

# Verify CRI-O installation
if ! command -v crio >/dev/null 2>&1; then
    echo "Error: CRI-O installation failed" >&2
    exit 1
fi

# Restart CRI-O service and enable it
sudo systemctl daemon-reload
sudo systemctl enable crio --now
sudo systemctl restart crio

# Check CRI-O service status
if ! sudo systemctl is-active --quiet crio; then
    echo "Error: CRI-O service failed to start. Capturing logs..." >&2
    sudo journalctl -xeu crio | tail -50
    echo "Reinstalling CRI-O to fix potential issues..."
    
    sudo apt-get remove --purge -y cri-o
    sudo apt-get update
    sudo apt-get install -y cri-o
    sudo systemctl restart crio

    if ! sudo systemctl is-active --quiet crio; then
        echo "Critical Error: CRI-O reinstall did not fix the issue." >&2
        echo "📌 Suggested Debugging Steps:"
        echo "1️⃣ Check CRI-O logs: sudo journalctl -xeu crio | tail -50"
        echo "2️⃣ Verify CRI-O socket: ls -l /var/run/crio/crio.sock"
        echo "3️⃣ Check SELinux/AppArmor: sudo aa-status (AppArmor) or sestatus (SELinux)"
        echo "4️⃣ Manually restart CRI-O: sudo systemctl restart crio && sleep 5 && crictl info"
        exit 1
    fi
fi

# Verify CRI-O socket exists
if [ ! -S /var/run/crio/crio.sock ]; then
    echo "Error: CRI-O socket not found! CRI-O is not running properly." >&2
    exit 1
fi

# Configure crictl to use CRI-O
cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///var/run/crio/crio.sock
EOF

# Final CRI-O check
if ! crictl info >/dev/null 2>&1; then
    echo "Error: CRI-O is installed but not responding!" >&2
    sudo journalctl -xeu crio | tail -50
    exit 1
fi

echo "CRI-O runtime installed successfully"

# Install kubelet, kubectl, and kubeadm
curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key | \
    sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" | \
    sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y
sudo apt-get install -y kubelet="$KUBERNETES_INSTALL_VERSION" kubectl="$KUBERNETES_INSTALL_VERSION" kubeadm="$KUBERNETES_INSTALL_VERSION"

# Prevent automatic updates for kubelet, kubeadm, and kubectl
sudo apt-mark hold kubelet kubeadm kubectl

sudo apt-get update -y

# Install jq, a command-line JSON processor
sudo apt-get install -y jq

# Detect primary network interface and retrieve local IP address
local_ip="$(ip route get 8.8.8.8 | awk '{print $7; exit}')"

# Write the local IP address to the kubelet default configuration file
cat > /etc/default/kubelet << EOF
KUBELET_EXTRA_ARGS=--node-ip=$local_ip
EOF

# Restart kubelet to apply node IP configuration
sudo systemctl daemon-reload
sudo systemctl restart kubelet

echo "✅ Kubernetes node setup completed successfully!"

