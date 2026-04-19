#!/bin/bash
#
# Setup for Control Plane (Master) servers

set -euxo pipefail

PUBLIC_IP_ACCESS="false"
NODENAME=$(hostname -s)
POD_CIDR="192.168.0.0/16"

# Pull required images
sudo kubeadm config images pull

# Initialize kubeadm based on PUBLIC_IP_ACCESS

if [[ "$PUBLIC_IP_ACCESS" == "false" ]]; then

    # Auto-detect private IP from the default route interface (no hardcoded eth1)
    MASTER_PRIVATE_IP=$(ip route get 1.1.1.1 | awk 'NR==1 {print $7}')
    echo "Detected private IP: $MASTER_PRIVATE_IP"

    if [[ -z "$MASTER_PRIVATE_IP" ]]; then
        echo "Error: Could not detect private IP address"
        exit 1
    fi

    sudo kubeadm init \
        --apiserver-advertise-address="$MASTER_PRIVATE_IP" \
        --apiserver-cert-extra-sans="$MASTER_PRIVATE_IP" \
        --pod-network-cidr="$POD_CIDR" \
        --node-name "$NODENAME" \
        --ignore-preflight-errors Swap

elif [[ "$PUBLIC_IP_ACCESS" == "true" ]]; then

    MASTER_PUBLIC_IP=$(curl -s ifconfig.me)
    sudo kubeadm init \
        --control-plane-endpoint="$MASTER_PUBLIC_IP" \
        --apiserver-cert-extra-sans="$MASTER_PUBLIC_IP" \
        --pod-network-cidr="$POD_CIDR" \
        --node-name "$NODENAME" \
        --ignore-preflight-errors Swap

else
    echo "Error: PUBLIC_IP_ACCESS has an invalid value: $PUBLIC_IP_ACCESS"
    exit 1
fi

# Configure kubeconfig
mkdir -p "$HOME"/.kube
sudo cp -i /etc/kubernetes/admin.conf "$HOME"/.kube/config
sudo chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config

# Install Calico Network Plugin

# Install Tigera Operator and CRDs
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/operator-crds.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/tigera-operator.yaml

sleep 120

# Download custom resources
curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/custom-resources.yaml

# Get cluster CIDR from kube-controller-manager
CLUSTER_CIDR=$(kubectl -n kube-system get pod -l component=kube-controller-manager -o yaml | grep -i cluster-cidr | awk '{print $2}' | sed 's/--cluster-cidr=//')

if [ -z "$CLUSTER_CIDR" ]; then
    echo "Warning: Could not detect cluster CIDR, using default $POD_CIDR"
    CLUSTER_CIDR="$POD_CIDR"
fi

echo "Using cluster CIDR: $CLUSTER_CIDR"

# Update CIDR in custom-resources.yaml
sed -i "s|cidr: 192.168.0.0/16|cidr: $CLUSTER_CIDR|g" custom-resources.yaml

# Apply custom resources
kubectl apply -f custom-resources.yaml
sleep 60