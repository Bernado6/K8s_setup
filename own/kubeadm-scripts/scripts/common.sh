#!/bin/bash
#
# Common setup for all servers (Control Plane and Nodes)
# Converted for yum-based systems (RHEL, CentOS, Amazon Linux)

set -euxo pipefail

# Kubernetes Variable Declaration
KUBERNETES_VERSION="v1.34"
CRICTL_VERSION="v1.35.0"
KUBERNETES_INSTALL_VERSION="1.34.0"

# Disable swap
sudo swapoff -a

# Keeps the swap off during reboot
(crontab -l 2>/dev/null; echo "@reboot /sbin/swapoff -a") | crontab - || true

sudo yum update -y

# Create the .conf file to load the modules at bootup
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# Install required packages
sudo yum install -y ca-certificates curl gnupg

# Install containerd Runtime via Docker's CentOS/RHEL repo
sudo yum install -y yum-utils
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo yum install -y containerd.io

sudo systemctl daemon-reload
sudo systemctl enable containerd --now
sudo systemctl start containerd.service

echo "Containerd runtime installed successfully"

# Generate the default containerd configuration
sudo containerd config default | sudo tee /etc/containerd/config.toml

# Enable SystemdCgroup
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Restart containerd to apply changes
sudo systemctl restart containerd

# Detect architecture for downloads (amd64 vs arm64)
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64)  CRICTL_ARCH="amd64" ;;
  aarch64) CRICTL_ARCH="arm64" ;;
  *)
    echo "Unsupported architecture: $ARCH_RAW"
    exit 1
    ;;
esac

# Install crictl
curl -LO "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz"
sudo tar zxvf "crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz" -C /usr/local/bin
rm -f "crictl-${CRICTL_VERSION}-linux-${CRICTL_ARCH}.tar.gz"

# Configure crictl to use containerd
cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

echo "crictl installed and configured successfully"

# Install kubelet, kubectl, and kubeadm
# Add Kubernetes yum repository
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

sudo yum install -y \
  kubelet-"$KUBERNETES_INSTALL_VERSION" \
  kubectl-"$KUBERNETES_INSTALL_VERSION" \
  kubeadm-"$KUBERNETES_INSTALL_VERSION" \
  --disableexcludes=kubernetes

# Prevent automatic updates for kubelet, kubeadm, and kubectl
sudo yum install -y yum-plugin-versionlock
sudo yum versionlock add kubelet kubeadm kubectl

sudo systemctl enable kubelet --now

# Install jq, a command-line JSON processor
sudo yum install -y jq

# Retrieve the local IP address of the eth1 interface and set it for kubelet
local_ip="$(ip --json addr show eth1 | jq -r '.[0].addr_info[] | select(.family == "inet") | .local')"

# Write the local IP address to the kubelet default configuration file
cat > /etc/default/kubelet <<EOF
KUBELET_EXTRA_ARGS=--node-ip=$local_ip
EOF