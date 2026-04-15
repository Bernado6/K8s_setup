#!/usr/bin/env bash
# =============================================================================
# 03-control-plane-init.sh — Phase 4 & 5: Control Plane Init + Calico CNI
# =============================================================================
# Run this script on the CONTROL PLANE node only, AFTER 02-node-prep.sh.
#
# What it does:
#   1. Initialises the cluster with kubeadm init
#   2. Sets up kubeconfig for the ubuntu user
#   3. Installs Calico CNI (tigera-operator + custom resources)
#   4. Saves the kubeadm join command to ~/join-command.sh
#
# Usage:
#   scp -i ~/.ssh/k8s-keypair.pem 03-control-plane-init.sh ubuntu@<CP_IP>:~
#   ssh -i ~/.ssh/k8s-keypair.pem ubuntu@<CP_IP> \
#     "CP_PRIVATE_IP=<PRIVATE_IP> bash ~/03-control-plane-init.sh"
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
# Calico version — keep in sync with Kubernetes version
CALICO_VERSION="v3.28.0"

# Pod network CIDR — must match Calico's default and must NOT overlap your VPC CIDR
POD_CIDR="192.168.0.0/16"

# Control plane private IP (required for --apiserver-advertise-address)
# Can be passed as env var: CP_PRIVATE_IP=x.x.x.x bash 03-control-plane-init.sh
if [[ -z "${CP_PRIVATE_IP:-}" ]]; then
  # Auto-detect from EC2 metadata
  CP_PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
  echo "Auto-detected private IP: $CP_PRIVATE_IP"
fi

echo "============================================================"
echo " Control Plane Init — $(hostname)"
echo " Private IP : $CP_PRIVATE_IP"
echo " Pod CIDR   : $POD_CIDR"
echo " Calico     : $CALICO_VERSION"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. kubeadm init
# ---------------------------------------------------------------------------
echo ""
echo "--- [1/3] kubeadm init ---"

if kubectl get nodes &>/dev/null 2>&1; then
  echo "Cluster already initialised — skipping kubeadm init."
else
  sudo kubeadm init \
    --pod-network-cidr="$POD_CIDR" \
    --apiserver-advertise-address="$CP_PRIVATE_IP" \
    --upload-certs \
    2>&1 | tee /tmp/kubeadm-init.log

  echo "kubeadm init complete."
fi

# ---------------------------------------------------------------------------
# 2. kubeconfig for ubuntu user
# ---------------------------------------------------------------------------
echo ""
echo "--- [2/3] kubeconfig setup ---"
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
echo "kubeconfig written to $HOME/.kube/config"

# Verify API server is reachable
kubectl cluster-info

# ---------------------------------------------------------------------------
# 3. Calico CNI
# ---------------------------------------------------------------------------
echo ""
echo "--- [3/3] Calico CNI (${CALICO_VERSION}) ---"

# Apply Tigera Operator
kubectl create -f \
  "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" \
  --dry-run=client 2>/dev/null || true
kubectl apply -f \
  "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

# Apply Custom Resources (uses POD_CIDR 192.168.0.0/16 by default)
kubectl create -f \
  "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml" \
  --dry-run=client 2>/dev/null || true
kubectl apply -f \
  "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"

echo "Calico manifests applied. Waiting for pods to start..."

# Wait up to 3 minutes for calico-system namespace to exist
for i in $(seq 1 18); do
  if kubectl get namespace calico-system &>/dev/null 2>&1; then
    break
  fi
  echo "  Waiting for calico-system namespace... (${i}/18)"
  sleep 10
done

# Wait for Calico pods to be Running
kubectl wait --for=condition=Ready pods \
  --all -n calico-system \
  --timeout=180s || {
    echo "WARNING: Calico pods not all Ready within 3 minutes."
    echo "Check status: kubectl get pods -n calico-system"
  }

echo "Calico CNI ready."

# ---------------------------------------------------------------------------
# Wait for control plane node to become Ready
# ---------------------------------------------------------------------------
echo ""
echo "Waiting for control plane node to be Ready..."
kubectl wait --for=condition=Ready node "$(hostname)" --timeout=120s
kubectl get nodes -o wide

# ---------------------------------------------------------------------------
# Save join command
# ---------------------------------------------------------------------------
echo ""
echo "--- Generating worker join command ---"
JOIN_CMD=$(kubeadm token create --print-join-command)

cat > "$HOME/join-command.sh" <<EOF
#!/usr/bin/env bash
# Run this on each WORKER NODE to join the cluster.
# Token expires in 24h. Regenerate with:
#   kubeadm token create --print-join-command
sudo $JOIN_CMD
EOF
chmod +x "$HOME/join-command.sh"

echo ""
echo "============================================================"
echo " CONTROL PLANE READY"
echo "============================================================"
echo ""
echo " Nodes:"
kubectl get nodes -o wide
echo ""
echo " System pods:"
kubectl get pods -n kube-system --no-headers | awk '{print "  " $1 "\t" $3}'
echo ""
echo " Join command saved to: ~/join-command.sh"
echo " Contents:"
cat "$HOME/join-command.sh"
echo ""
echo " NEXT STEP:"
echo "   1. Copy ~/join-command.sh to each worker node:"
echo "      scp -i ~/.ssh/k8s-keypair.pem ~/join-command.sh ubuntu@<WORKER_IP>:~"
echo "   2. SSH into the worker and run: bash ~/join-command.sh"
echo "   3. Then run verify.sh from the control plane."
echo "============================================================"
