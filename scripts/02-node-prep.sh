#!/usr/bin/env bash
# =============================================================================
# 02-node-prep.sh — Phase 2 & 3: Node Preparation
# =============================================================================
# Run this script on BOTH the control plane and each worker node.
#
# What it does:
#   1. Updates packages
#   2. Disables swap (required by kubelet)
#   3. Loads kernel modules: overlay, br_netfilter
#   4. Sets sysctl params for Kubernetes networking
#   5. Installs and configures containerd (SystemdCgroup = true)
#   6. Installs kubelet, kubeadm, kubectl (v1.31, held at version)
#
# Usage:
#   scp -i ~/.ssh/k8s-keypair.pem 02-node-prep.sh ubuntu@<IP>:~
#   ssh -i ~/.ssh/k8s-keypair.pem ubuntu@<IP> "bash ~/02-node-prep.sh"
# =============================================================================

set -euo pipefail

K8S_VERSION="v1.31"

echo "============================================================"
echo " Node Preparation — $(hostname)"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. System update
# ---------------------------------------------------------------------------
echo ""
echo "--- [1/6] System update ---"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# ---------------------------------------------------------------------------
# 2. Disable swap
# ---------------------------------------------------------------------------
echo ""
echo "--- [2/6] Disabling swap ---"
sudo swapoff -a
# Comment out swap entries in /etc/fstab to survive reboots
sudo sed -i.bak '/ swap / s/^\(.*\)$/#\1/' /etc/fstab
echo "Swap disabled."

# ---------------------------------------------------------------------------
# 3. Kernel modules
# ---------------------------------------------------------------------------
echo ""
echo "--- [3/6] Kernel modules (overlay, br_netfilter) ---"
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
echo "Modules loaded."

# ---------------------------------------------------------------------------
# 4. sysctl for Kubernetes networking
# ---------------------------------------------------------------------------
echo ""
echo "--- [4/6] sysctl params ---"
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
echo "sysctl params applied."

# ---------------------------------------------------------------------------
# 5. containerd
# ---------------------------------------------------------------------------
echo ""
echo "--- [5/6] containerd ---"
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
# Generate default config
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# CRITICAL: set SystemdCgroup = true
# Without this, kubelet and containerd cgroup drivers mismatch and kubelet crashes.
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Verify the change was applied
if grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
  echo "SystemdCgroup = true confirmed."
else
  echo "ERROR: Failed to set SystemdCgroup = true in containerd config!"
  exit 1
fi

sudo systemctl restart containerd
sudo systemctl enable containerd
echo "containerd running."

# ---------------------------------------------------------------------------
# 6. Kubernetes binaries: kubelet, kubeadm, kubectl
# ---------------------------------------------------------------------------
echo ""
echo "--- [6/6] Kubernetes binaries (${K8S_VERSION}) ---"
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Add Kubernetes apt repository
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl

# Hold versions to prevent accidental upgrades
sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable --now kubelet
echo "kubelet, kubeadm, kubectl installed and held."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Node prep complete on: $(hostname)"
echo " Versions:"
echo "   kubeadm : $(kubeadm version -o short 2>/dev/null || kubeadm version)"
echo "   kubelet : $(kubelet --version)"
echo "   kubectl : $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
echo ""
echo " NEXT STEP:"
echo "   Control plane → run 03-control-plane-init.sh"
echo "   Worker node   → wait for join command from control plane"
echo "============================================================"
