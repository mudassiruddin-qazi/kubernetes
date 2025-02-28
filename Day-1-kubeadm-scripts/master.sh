#!/bin/bash
#
# Setup for Control Plane (Master) servers

set -euxo pipefail

# If you need public access to API server using the server's Public IP address, set PUBLIC_IP_ACCESS to "true"
PUBLIC_IP_ACCESS="false"
NODENAME=$(hostname -s)
POD_CIDR="192.168.0.0/16"

# Ensure Kubernetes binaries (kubeadm, kubectl, kubelet) are installed
if ! command -v kubeadm &>/dev/null || ! command -v kubectl &>/dev/null || ! command -v kubelet &>/dev/null; then
    echo "❌ Error: kubeadm, kubectl, or kubelet not found! Installing Kubernetes components..."
    
    # Define Kubernetes version
    KUBERNETES_VERSION="v1.30"
    KUBERNETES_INSTALL_VERSION="1.30.0-1.1"

    # Update system packages
    sudo apt-get update -y
    sudo apt-get install -y apt-transport-https ca-certificates curl gpg

    # Add Kubernetes package repository
    curl -fsSL https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/Release.key |
        sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/deb/ /" |
        sudo tee /etc/apt/sources.list.d/kubernetes.list

    sudo apt-get update -y
    sudo apt-get install -y kubelet="$KUBERNETES_INSTALL_VERSION" kubectl="$KUBERNETES_INSTALL_VERSION" kubeadm="$KUBERNETES_INSTALL_VERSION"

    # Prevent automatic updates for Kubernetes packages
    sudo apt-mark hold kubelet kubeadm kubectl
fi

# Verify kubeadm is installed
if ! command -v kubeadm &>/dev/null; then
    echo "❌ Error: kubeadm is still not found after installation. Exiting..."
    exit 1
fi

# Pull required images
sudo kubeadm config images pull

# Determine the primary network interface dynamically
PRIMARY_INTERFACE=$(ip route | grep default | awk '{print $5}')
MASTER_PRIVATE_IP=$(ip -4 addr show "$PRIMARY_INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# Initialize kubeadm based on PUBLIC_IP_ACCESS
if [[ "$PUBLIC_IP_ACCESS" == "false" ]]; then
    sudo kubeadm init \
        --apiserver-advertise-address="$MASTER_PRIVATE_IP" \
        --apiserver-cert-extra-sans="$MASTER_PRIVATE_IP" \
        --pod-network-cidr="$POD_CIDR" \
        --node-name "$NODENAME" \
        --ignore-preflight-errors Swap

elif [[ "$PUBLIC_IP_ACCESS" == "true" ]]; then
    if ! command -v curl >/dev/null 2>&1; then
        echo "❌ Error: curl is not installed. Please install curl and retry."
        exit 1
    fi

    MASTER_PUBLIC_IP=$(curl -s ifconfig.me)

    if [[ -z "$MASTER_PUBLIC_IP" ]]; then
        echo "❌ Error: Unable to retrieve public IP address!"
        exit 1
    fi

    sudo kubeadm init \
        --control-plane-endpoint="$MASTER_PUBLIC_IP" \
        --apiserver-cert-extra-sans="$MASTER_PUBLIC_IP" \
        --pod-network-cidr="$POD_CIDR" \
        --node-name "$NODENAME" \
        --ignore-preflight-errors Swap
else
    echo "❌ Error: Invalid value for PUBLIC_IP_ACCESS: $PUBLIC_IP_ACCESS"
    exit 1
fi

# Check if kubeadm init was successful
if [[ $? -ne 0 ]]; then
    echo "❌ Error: kubeadm init failed. Check logs using 'sudo journalctl -xeu kubelet'"
    exit 1
fi

# Configure kubeconfig
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

# Verify kubectl is working
if ! kubectl get nodes >/dev/null 2>&1; then
    echo "❌ Error: kubectl is not working. Check 'kubectl cluster-info'"
    exit 1
fi

# Install Calico Network Plugin
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

echo "✅ Control Plane setup completed successfully!"
