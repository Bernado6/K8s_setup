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

# Wait for Tigera operator to be ready before applying custom resources
kubectl rollout status deployment tigera-operator -n tigera-operator --timeout=120s

# Download and apply custom resources with correct CIDR
curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/custom-resources.yaml
sed -i "s|cidr: 192.168.0.0/16|cidr: $POD_CIDR|g" custom-resources.yaml
kubectl apply -f custom-resources.yaml

# Wait for FelixConfiguration CRD to be available before patching
echo "Waiting for FelixConfiguration CRD..."
until kubectl get crd felixconfigurations.crd.projectcalico.org &>/dev/null; do
    sleep 5
done

# Auto-detect the host network interface name for Felix MTU detection
HOST_IFACE=$(ip route get 1.1.1.1 | awk 'NR==1 {print $5}')
echo "Detected host interface: $HOST_IFACE"

# Patch Felix to use the correct interface pattern for MTU auto-detection
kubectl patch felixconfiguration default --type=merge --patch "{
  \"spec\": {
    \"mtuIfacePattern\": \"^($HOST_IFACE|eth.*|ens.*|enp.*|eno.*)\"
  }
}" || echo "Warning: FelixConfiguration patch failed - may not exist yet, calico-node will still start"

# Patch Calico Installation for correct IP autodetection interface
kubectl patch installation default --type=merge --patch "{
  \"spec\": {
    \"calicoNetwork\": {
      \"nodeAddressAutodetectionV4\": {
        \"interface\": \"$HOST_IFACE\"
      }
    }
  }
}"

echo "Waiting for calico-node pods to be ready..."
kubectl rollout status daemonset calico-node -n calico-system --timeout=300s

echo "Calico installation complete."
kubectl get pods -n calico-system