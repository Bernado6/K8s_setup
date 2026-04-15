#!/usr/bin/env bash
# =============================================================================
# verify.sh — Phase 7: Cluster Verification
# =============================================================================
# Run this script on the CONTROL PLANE after all nodes have joined.
#
# Checks:
#   1. All nodes are Ready
#   2. All kube-system pods are Running
#   3. All calico-system pods are Running
#   4. A test pod schedules on the worker node (not control plane)
#   5. DNS resolution works inside the cluster
#
# Usage:
#   bash verify.sh
# =============================================================================

set -euo pipefail

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; ((PASS++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }

echo "============================================================"
echo " Cluster Verification — $(hostname)"
echo " $(date)"
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. All nodes Ready
# ---------------------------------------------------------------------------
echo ""
echo "--- [1] Node status ---"
kubectl get nodes -o wide
echo ""

NOT_READY=$(kubectl get nodes --no-headers | grep -v " Ready" | wc -l)
if [[ "$NOT_READY" -eq 0 ]]; then
  pass "All nodes are Ready"
else
  fail "$NOT_READY node(s) are NOT Ready"
fi

# ---------------------------------------------------------------------------
# 2. kube-system pods
# ---------------------------------------------------------------------------
echo ""
echo "--- [2] kube-system pods ---"
kubectl get pods -n kube-system -o wide
echo ""

NOT_RUNNING=$(kubectl get pods -n kube-system --no-headers \
  | grep -v -E "Running|Completed" | wc -l)
if [[ "$NOT_RUNNING" -eq 0 ]]; then
  pass "All kube-system pods are Running/Completed"
else
  fail "$NOT_RUNNING kube-system pod(s) not Running"
fi

# ---------------------------------------------------------------------------
# 3. calico-system pods
# ---------------------------------------------------------------------------
echo ""
echo "--- [3] calico-system pods ---"
kubectl get pods -n calico-system -o wide
echo ""

NOT_RUNNING=$(kubectl get pods -n calico-system --no-headers \
  | grep -v -E "Running|Completed" | wc -l)
if [[ "$NOT_RUNNING" -eq 0 ]]; then
  pass "All calico-system pods are Running"
else
  fail "$NOT_RUNNING calico-system pod(s) not Running"
fi

# ---------------------------------------------------------------------------
# 4. Test pod — schedules on worker node
# ---------------------------------------------------------------------------
echo ""
echo "--- [4] Test pod scheduling ---"

# Clean up any leftover test pod
kubectl delete pod verify-test-pod --ignore-not-found=true --wait=true

kubectl run verify-test-pod \
  --image=nginx:stable-alpine \
  --restart=Never \
  --labels="app=verify-test"

echo "Waiting for verify-test-pod to be Running..."
kubectl wait --for=condition=Ready pod/verify-test-pod --timeout=60s

POD_NODE=$(kubectl get pod verify-test-pod -o jsonpath='{.spec.nodeName}')
CONTROL_PLANE_NODE=$(kubectl get nodes \
  --selector='node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].metadata.name}')

echo "  Pod scheduled on: $POD_NODE"
echo "  Control plane:    $CONTROL_PLANE_NODE"

if [[ "$POD_NODE" != "$CONTROL_PLANE_NODE" ]]; then
  pass "Test pod scheduled on worker node (not control plane)"
else
  fail "Test pod scheduled on control plane — workers may not be joined yet"
fi

# ---------------------------------------------------------------------------
# 5. In-cluster DNS
# ---------------------------------------------------------------------------
echo ""
echo "--- [5] In-cluster DNS ---"

kubectl run dns-test \
  --image=busybox:1.36 \
  --restart=Never \
  --rm \
  --attach \
  --command -- nslookup kubernetes.default.svc.cluster.local 2>/dev/null \
  && pass "In-cluster DNS resolves kubernetes.default.svc.cluster.local" \
  || fail "In-cluster DNS lookup failed"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
echo ""
echo "--- Cleanup ---"
kubectl delete pod verify-test-pod --ignore-not-found=true
echo "Test pod deleted."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " VERIFICATION SUMMARY"
echo "============================================================"
echo "  Passed : $PASS"
echo "  Failed : $FAIL"
echo ""

kubectl get nodes -o wide
echo ""

if [[ "$FAIL" -eq 0 ]]; then
  echo " Cluster is healthy and ready to deploy workloads."
  echo ""
  echo " Quick-start commands:"
  echo "   kubectl get nodes"
  echo "   kubectl get pods -A"
  echo "   kubectl create namespace foundation-rag"
else
  echo " $FAIL check(s) failed. Investigate above before deploying."
  echo ""
  echo " Debug commands:"
  echo "   kubectl describe node <node-name>"
  echo "   kubectl logs -n calico-system <pod-name>"
  echo "   journalctl -u kubelet -n 50"
  exit 1
fi
echo "============================================================"
