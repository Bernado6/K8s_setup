# Kubernetes on AWS with kubeadm

A step-by-step guide to bootstrapping a production-like Kubernetes cluster on AWS EC2 using `kubeadm`. This setup creates a **1 control plane + 1 worker node** cluster running **Calico CNI** on **Ubuntu 22.04**.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Phase 1 — AWS Infrastructure Provisioning](#phase-1--aws-infrastructure-provisioning)
4. [Phase 2 — Node Preparation (Both Nodes)](#phase-2--node-preparation-both-nodes)
5. [Phase 3 — Install Kubernetes Binaries (Both Nodes)](#phase-3--install-kubernetes-binaries-both-nodes)
6. [Phase 4 — Initialise the Control Plane](#phase-4--initialise-the-control-plane)
7. [Phase 5 — Install Calico CNI](#phase-5--install-calico-cni)
8. [Phase 6 — Join the Worker Node](#phase-6--join-the-worker-node)
9. [Phase 7 — Verification](#phase-7--verification)
10. [Script Reference](#script-reference)
11. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
                        AWS VPC (default)
          ┌──────────────────────────────────────────┐
          │                                          │
          │   ┌─────────────────────┐                │
          │   │  Control Plane      │                │
          │   │  (t3.medium)        │                │
          │   │                     │                │
          │   │  etcd               │                │
          │   │  API Server :6443   │                │
          │   │  Scheduler          │                │
          │   │  Controller Manager │                │
          │   │  kubelet            │                │
          │   │  containerd         │                │
          │   └──────────┬──────────┘                │
          │              │ kubeadm join               │
          │   ┌──────────▼──────────┐                │
          │   │  Worker Node        │                │
          │   │  (t3.medium)        │                │
          │   │                     │                │
          │   │  kubelet            │                │
          │   │  kube-proxy         │                │
          │   │  containerd         │                │
          │   │  Your app pods      │                │
          │   └─────────────────────┘                │
          │                                          │
          │   CNI: Calico (pod CIDR 192.168.0.0/16)  │
          └──────────────────────────────────────────┘
```

**Why this design?**

- The **control plane** is the brain — it stores cluster state in etcd, schedules workloads, and exposes the API. It should never run your application containers (Kubernetes taints it by default).
- The **worker node** is the muscle — it runs your actual pods (FastAPI, RAG services, etc.).
- **Calico** provides each pod its own IP address and enforces network policies between pods.

---

## Prerequisites

### On the machine where you run `01-provision-aws.sh`

| Tool | Why | Install |
|------|-----|---------|
| AWS CLI v2 | Creates EC2 resources via API | See [Phase 1 prerequisites](#11-install-aws-cli-v2) |
| jq | Parses JSON output from AWS CLI | `sudo apt-get install -y jq` |
| IAM permissions | Authority to create EC2/VPC/SG resources | IAM role or `aws configure` |

### On each EC2 node (handled by scripts)

- Ubuntu 22.04 LTS
- Internet access (to pull container images and apt packages)
- 2 vCPU, 2 GB RAM minimum — `kubeadm` will refuse to initialise on anything smaller

---

## Phase 1 — AWS Infrastructure Provisioning

**Script:** `scripts/01-provision-aws.sh`
**Run on:** Your local machine or an existing EC2 with AWS CLI access

### What it creates

| Resource | Name | Purpose |
|----------|------|---------|
| EC2 Key Pair | `k8s-keypair` | SSH access to both nodes |
| Security Group | `k8s-control-plane-sg` | Firewall rules for the control plane |
| Security Group | `k8s-worker-sg` | Firewall rules for worker nodes |
| EC2 Instance | `k8s-control-plane` | t3.medium, 30 GB gp3 |
| EC2 Instance | `k8s-worker-1` | t3.medium, 30 GB gp3 |

### 1.1 Install AWS CLI v2

If you're running this from inside an existing EC2:

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
aws --version
```

### 1.2 IAM Permissions

The EC2 (or user) needs permission to create EC2 resources. Two options:

**Option A — IAM Role (recommended):** Attach an IAM role to your EC2 with `AmazonEC2FullAccess` or a custom policy. No credentials are stored on disk — the instance fetches temporary credentials from the metadata service automatically.

```bash
# Verify you have a role attached and it works:
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/
aws ec2 describe-vpcs --query "Vpcs[0].VpcId"
```

**Option B — AWS credentials:** Run `aws configure` and enter your Access Key ID, Secret Access Key, region, and output format.

### 1.3 Security Group Rules — explained

Kubernetes requires specific ports to be open between nodes. The script creates two security groups and opens only what is needed:

#### Control Plane Security Group (`k8s-control-plane-sg`)

| Port | Protocol | Source | Why |
|------|----------|--------|-----|
| 22 | TCP | `0.0.0.0/0` | SSH access for administration |
| 6443 | TCP | `0.0.0.0/0` | Kubernetes API server — `kubectl` and worker nodes talk to this |
| 2379–2380 | TCP | control-plane SG | etcd cluster ports — only the control plane needs to reach etcd |
| 10250–10259 | TCP | control-plane SG | kubelet API, kube-scheduler, kube-controller-manager health checks |
| All traffic | All | worker SG | Intra-cluster communication (Calico BGP, pod-to-pod traffic) |

#### Worker Node Security Group (`k8s-worker-sg`)

| Port | Protocol | Source | Why |
|------|----------|--------|-----|
| 22 | TCP | `0.0.0.0/0` | SSH access |
| 10250 | TCP | control-plane SG | kubelet API — the control plane calls this to manage pods on the worker |
| 30000–32767 | TCP | `0.0.0.0/0` | NodePort service range — exposes services to external traffic |
| All traffic | All | control-plane SG | Intra-cluster communication |

> **Why separate security groups?** If you add more worker nodes later, you just attach `k8s-worker-sg` — no rule changes needed.

### 1.4 Why t3.medium?

`kubeadm` enforces minimum requirements:
- **2 vCPU** — the scheduler and API server are multi-threaded; a single vCPU causes timeouts
- **2 GB RAM** — etcd alone needs ~512 MB; less than 2 GB causes kubelet to fail preflight

`t3.medium` (2 vCPU, 4 GB RAM) satisfies requirements with headroom for your application pods.

### 1.5 Why 30 GB storage?

Container images and etcd snapshots consume disk fast. The base Ubuntu OS + containerd + Kubernetes system images take ~8 GB. 30 GB gives safe headroom for your application images (FastAPI, vector store cache, etc.) without running into the disk pressure eviction threshold.

### Run it

```bash
bash scripts/01-provision-aws.sh
# or with a specific region:
bash scripts/01-provision-aws.sh --region us-east-1
```

The script prints both IPs and saves them to `scripts/cluster-ips.env`:

```
Control Plane:  54.x.x.x  (public)  /  10.0.x.x (private)
Worker Node:    54.x.x.x  (public)
```

> **Save the private IP of the control plane** — you'll need it for `kubeadm init`.

---

## Phase 2 — Node Preparation (Both Nodes)

**Script:** `scripts/02-node-prep.sh` (steps 1–4 below)
**Run on:** Control plane AND worker node

SSH into each node and run the script:

```bash
scp -i ~/.ssh/k8s-keypair.pem scripts/02-node-prep.sh ubuntu@<IP>:~
ssh -i ~/.ssh/k8s-keypair.pem ubuntu@<IP> "bash ~/02-node-prep.sh"
```

### 2.1 Disable Swap

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/' /etc/fstab
```

**Why:** The Linux kernel can move memory pages to disk (swap) when RAM is low. Kubernetes assumes it has full control over memory allocation for pods — if the kernel swaps out a container's memory, the kubelet's resource accounting breaks. The QoS (Quality of Service) guarantees that Kubernetes gives pods (Guaranteed, Burstable, BestEffort) are meaningless if the OS can silently page out memory. `kubeadm` performs a preflight check and **refuses to initialise** if swap is on.

The `sed` command comments out any swap entry in `/etc/fstab` so it stays off after a reboot.

### 2.2 Kernel Modules

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
```

**Why:**

| Module | Why Kubernetes needs it |
|--------|------------------------|
| `overlay` | The overlay filesystem driver. `containerd` uses OverlayFS to layer container images efficiently — each container gets a writable layer on top of read-only image layers without duplicating files. |
| `br_netfilter` | Makes the Linux bridge (used for pod networking) respect iptables rules. Without it, traffic between pods on the same node bypasses iptables — Kubernetes NetworkPolicy and kube-proxy's load-balancing rules would be silently ignored. |

The `/etc/modules-load.d/k8s.conf` file makes these load automatically on reboot.

### 2.3 sysctl Network Parameters

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

**Why:**

| Parameter | Effect |
|-----------|--------|
| `net.bridge.bridge-nf-call-iptables = 1` | Forces bridged IPv4 traffic through iptables. Required for kube-proxy to intercept pod traffic for load balancing and NetworkPolicy enforcement. |
| `net.bridge.bridge-nf-call-ip6tables = 1` | Same for IPv6 bridged traffic. |
| `net.ipv4.ip_forward = 1` | Allows the kernel to forward packets between network interfaces. Without this, a node cannot route traffic from a pod's virtual network interface to the physical NIC — pods would be network-isolated from everything. |

### 2.4 Install and Configure containerd

```bash
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

**Why containerd?** containerd is the industry-standard container runtime that Kubernetes uses via the CRI (Container Runtime Interface). Docker used to be used directly, but Kubernetes removed the Docker shim in v1.24 — containerd is now the default.

**Why `SystemdCgroup = true`?** This is the most common source of `kubeadm` failures.

Linux uses **cgroups** (control groups) to enforce CPU and memory limits on processes. There are two cgroup drivers:

- `cgroupfs` — the containerd default; it manages cgroups directly
- `systemd` — delegates cgroup management to systemd (PID 1)

On modern Ubuntu, **systemd is already managing cgroups for every process** on the host. If containerd uses `cgroupfs` while systemd uses systemd cgroups, you end up with **two separate cgroup hierarchies** managing the same processes. This causes kubelet to crash because it sees conflicting cgroup state. Setting `SystemdCgroup = true` makes containerd hand cgroup management to systemd — one hierarchy, no conflicts.

---

## Phase 3 — Install Kubernetes Binaries (Both Nodes)

**Script:** `scripts/02-node-prep.sh` (this is the second half of the same script)
**Run on:** Control plane AND worker node

### 3.1 Add the Kubernetes apt Repository

```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=...] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
```

**Why a separate repo?** The Kubernetes packages are not in Ubuntu's default apt repository. Kubernetes maintains its own signed package repository at `pkgs.k8s.io`. The GPG key verification ensures the packages haven't been tampered with.

### 3.2 Install the Three Binaries

```bash
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

| Binary | Role |
|--------|------|
| `kubelet` | The node agent — runs on every node, receives pod specs from the API server and starts/stops containers via containerd |
| `kubeadm` | The bootstrap tool — used once to initialise the cluster (control plane) or join a node (workers). Not used during normal operation. |
| `kubectl` | The CLI client — lets you talk to the API server to deploy apps, inspect pods, etc. Only strictly needed on the control plane, but useful on all nodes for debugging. |

**Why `apt-mark hold`?** Kubernetes is sensitive to version skew. If `apt-get upgrade` silently updates kubelet to a newer minor version than kubeadm, the cluster can break. Holding the packages prevents accidental upgrades. To upgrade later, you deliberately unhold, upgrade in the correct sequence (control plane first), then re-hold.

---

## Phase 4 — Initialise the Control Plane

**Script:** `scripts/03-control-plane-init.sh`
**Run on:** Control plane only

```bash
scp -i ~/.ssh/k8s-keypair.pem scripts/03-control-plane-init.sh ubuntu@<CP_PUBLIC_IP>:~
ssh -i ~/.ssh/k8s-keypair.pem ubuntu@<CP_PUBLIC_IP> \
  "CP_PRIVATE_IP=<CP_PRIVATE_IP> bash ~/03-control-plane-init.sh"
```

### 4.1 kubeadm init

```bash
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --apiserver-advertise-address=<CP_PRIVATE_IP>
```

**What happens during `kubeadm init`:**

1. **Preflight checks** — verifies swap is off, modules are loaded, containerd is running, ports are free
2. **Generates certificates** — creates a CA and signs TLS certs for the API server, etcd, and kubelet. All cluster communication is encrypted.
3. **Starts etcd** — a static pod that stores all cluster state (pod definitions, secrets, configmaps)
4. **Starts the API server** — the central control point; all other components talk to it
5. **Starts the scheduler** — watches for unscheduled pods and assigns them to nodes based on resource availability
6. **Starts the controller manager** — runs control loops (e.g., ensures the desired number of pod replicas are running)
7. **Bootstraps RBAC** — sets up the default ClusterRoles
8. **Prints a `kubeadm join` command** — contains a short-lived token for worker nodes to authenticate

**Why `--pod-network-cidr=192.168.0.0/16`?** This reserves an IP range exclusively for pod networking. It must:
- Not overlap with your VPC CIDR (typically `172.31.0.0/16` for default VPCs)
- Match what the CNI plugin expects — Calico defaults to `192.168.0.0/16`

**Why `--apiserver-advertise-address=<PRIVATE_IP>`?** The API server needs to know which IP to listen on and advertise to worker nodes. On EC2, the public IP is a NAT address managed by AWS — the instance itself doesn't have it on any interface. Using the private IP ensures the API server binds to a real interface.

### 4.2 kubeconfig Setup

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

**Why:** `kubeadm` writes the cluster admin credentials to `/etc/kubernetes/admin.conf` (owned by root). Copying it to `~/.kube/config` and fixing ownership lets the `ubuntu` user run `kubectl` without `sudo`. The file contains the cluster's CA certificate and a client certificate — treat it like a password.

---

## Phase 5 — Install Calico CNI

**Script:** `scripts/03-control-plane-init.sh` (second half)
**Run on:** Control plane only

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml
```

### Why a CNI plugin is required

After `kubeadm init`, if you run `kubectl get nodes`, the control plane will show `NotReady`. This is expected — the node has no CNI plugin installed yet. Without a CNI:

- Pods cannot get IP addresses
- Pods cannot communicate with each other across nodes
- The node stays in `NotReady` because the kubelet's network health check fails

Kubernetes deliberately does not include a CNI — it defines a standard interface (the Container Network Interface spec) and lets you choose your implementation.

### Why Calico

| Feature | Calico | Flannel | Cilium |
|---------|--------|---------|--------|
| NetworkPolicy support | Yes | No | Yes |
| Performance | High (native routing) | Moderate (VXLAN overlay) | Highest (eBPF) |
| Complexity | Medium | Low | High |
| Production usage | Very widely used | Common in labs | Growing fast |

Calico uses native BGP routing by default (no encapsulation overhead) and supports Kubernetes NetworkPolicy — you can write rules like "only the API pod can talk to the database pod."

### What the two manifests do

| Manifest | What it installs |
|----------|-----------------|
| `tigera-operator.yaml` | The Tigera Operator — a Kubernetes operator that manages the Calico lifecycle (installation, upgrades, configuration) |
| `custom-resources.yaml` | A `Installation` custom resource that tells the operator to install Calico with `192.168.0.0/16` as the pod CIDR |

---

## Phase 6 — Join the Worker Node

**Script:** `scripts/04-worker-join.sh` or `~/join-command.sh` from the control plane
**Run on:** Worker node only

### 6.1 Get the join command

The control plane script saves the join command to `~/join-command.sh`. Copy it to the worker:

```bash
# From your local machine:
scp -i ~/.ssh/k8s-keypair.pem ubuntu@<CP_IP>:~/join-command.sh .
scp -i ~/.ssh/k8s-keypair.pem join-command.sh ubuntu@<WORKER_IP>:~
ssh -i ~/.ssh/k8s-keypair.pem ubuntu@<WORKER_IP> "bash ~/join-command.sh"
```

Or use `04-worker-join.sh` with explicit token values:

```bash
ssh -i ~/.ssh/k8s-keypair.pem ubuntu@<WORKER_IP> \
  "JOIN_TOKEN=<token> JOIN_HASH=sha256:<hash> CP_PRIVATE_IP=<ip> bash ~/04-worker-join.sh"
```

### 6.2 What kubeadm join does

```bash
sudo kubeadm join <CP_PRIVATE_IP>:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

1. **Contacts the API server** at `<CP_PRIVATE_IP>:6443`
2. **Authenticates** using the bootstrap token (short-lived, auto-expires in 24h)
3. **Verifies the control plane** using the CA cert hash — prevents joining a rogue cluster
4. **Downloads cluster configuration** (kubelet config, certificates)
5. **Starts kubelet** which registers the node with the API server
6. **Calico** detects the new node and sets up pod networking on it

> **Token expiry:** Bootstrap tokens expire after 24 hours. If you need to join a node later, regenerate the command on the control plane:
> ```bash
> kubeadm token create --print-join-command
> ```

---

## Phase 7 — Verification

**Script:** `scripts/verify.sh`
**Run on:** Control plane

```bash
scp -i ~/.ssh/k8s-keypair.pem scripts/verify.sh ubuntu@<CP_IP>:~
ssh -i ~/.ssh/k8s-keypair.pem ubuntu@<CP_IP> "bash ~/verify.sh"
```

### What the script checks

| Check | Command | Expected result |
|-------|---------|-----------------|
| Nodes Ready | `kubectl get nodes` | Both nodes show `Ready` |
| System pods | `kubectl get pods -n kube-system` | All `Running` or `Completed` |
| Calico pods | `kubectl get pods -n calico-system` | All `Running` |
| Pod scheduling | Runs a test nginx pod | Scheduled on the **worker**, not control plane |
| In-cluster DNS | `nslookup kubernetes.default.svc.cluster.local` | Resolves successfully |

### Manual verification commands

```bash
# Node overview
kubectl get nodes -o wide

# All pods across all namespaces
kubectl get pods -A

# Detailed node info (CPU, memory, taints)
kubectl describe node <node-name>

# Events (useful for debugging)
kubectl get events -A --sort-by='.lastTimestamp'
```

---

## Script Reference

```
scripts/
├── 01-provision-aws.sh        # Run locally / on existing EC2 — creates AWS infra
├── 02-node-prep.sh            # Run on BOTH nodes — OS prep + K8s binaries
├── 03-control-plane-init.sh   # Run on CONTROL PLANE only — kubeadm init + Calico
├── 04-worker-join.sh          # Run on WORKER NODE only — kubeadm join
├── verify.sh                  # Run on CONTROL PLANE — health checks
└── cluster-ips.env            # Auto-generated by 01-provision-aws.sh — stores IPs
```

### End-to-end execution order

```bash
# 1. From local machine / existing EC2
bash scripts/01-provision-aws.sh
source scripts/cluster-ips.env   # loads CP_PUBLIC_IP, CP_PRIVATE_IP, WRK_PUBLIC_IP

# 2. Prepare BOTH nodes (run in parallel in two terminals)
scp -i ~/.ssh/k8s-keypair.pem scripts/02-node-prep.sh ubuntu@$CP_PUBLIC_IP:~
scp -i ~/.ssh/k8s-keypair.pem scripts/02-node-prep.sh ubuntu@$WRK_PUBLIC_IP:~
ssh -i ~/.ssh/k8s-keypair.pem ubuntu@$CP_PUBLIC_IP "bash ~/02-node-prep.sh"
ssh -i ~/.ssh/k8s-keypair.pem ubuntu@$WRK_PUBLIC_IP "bash ~/02-node-prep.sh"

# 3. Initialise control plane
scp -i ~/.ssh/k8s-keypair.pem scripts/03-control-plane-init.sh ubuntu@$CP_PUBLIC_IP:~
ssh -i ~/.ssh/k8s-keypair.pem ubuntu@$CP_PUBLIC_IP \
  "CP_PRIVATE_IP=$CP_PRIVATE_IP bash ~/03-control-plane-init.sh"

# 4. Copy join command to worker and join
scp -i ~/.ssh/k8s-keypair.pem ubuntu@$CP_PUBLIC_IP:~/join-command.sh .
scp -i ~/.ssh/k8s-keypair.pem join-command.sh ubuntu@$WRK_PUBLIC_IP:~
ssh -i ~/.ssh/k8s-keypair.pem ubuntu@$WRK_PUBLIC_IP "bash ~/join-command.sh"

# 5. Verify
scp -i ~/.ssh/k8s-keypair.pem scripts/verify.sh ubuntu@$CP_PUBLIC_IP:~
ssh -i ~/.ssh/k8s-keypair.pem ubuntu@$CP_PUBLIC_IP "bash ~/verify.sh"
```

---

## Troubleshooting

### Node stays `NotReady` after join

```bash
# Check kubelet logs on the node
journalctl -u kubelet -n 50 --no-pager

# Common causes:
# 1. CNI not installed yet — wait 2-3 minutes after Calico apply
# 2. containerd not running: sudo systemctl status containerd
# 3. swap still on: swapon --show
```

### `kubeadm init` preflight errors

| Error | Fix |
|-------|-----|
| `[ERROR Swap]` | `sudo swapoff -a` |
| `[ERROR CRI]` | `sudo systemctl restart containerd` |
| `[ERROR NumCPU]` | Use at least t3.small (2 vCPU) |
| `[ERROR Mem]` | Use at least t3.small (2 GB RAM) |
| `[ERROR Port-6443]` | Another process is using 6443; check with `ss -tlnp` |

### Calico pods stuck in `Init` or `Pending`

```bash
kubectl describe pod -n calico-system <pod-name>

# Common causes:
# 1. Pod CIDR mismatch — ensure custom-resources.yaml uses 192.168.0.0/16
# 2. Image pull timeout — check internet access on the node
# 3. Node not Ready yet — wait for kubelet to stabilise
```

### `kubectl` connection refused

```bash
# Ensure kubeconfig is set
export KUBECONFIG=$HOME/.kube/config
kubectl cluster-info

# If API server is down:
sudo systemctl status kubelet
sudo crictl ps   # check if API server container is running
```

### Bootstrap token expired (worker join fails)

```bash
# On the control plane, generate a fresh join command:
kubeadm token create --print-join-command
# Use the output to run kubeadm join on the worker
```

### Tear down (cleanup)

```bash
# On worker: reset node
sudo kubeadm reset -f
sudo systemctl stop kubelet

# On control plane: drain and delete worker, then reset
kubectl drain <worker-node-name> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <worker-node-name>
sudo kubeadm reset -f

# Delete AWS resources
aws ec2 terminate-instances --instance-ids <CP_ID> <WRK_ID>
aws ec2 delete-security-group --group-id <CP_SG>
aws ec2 delete-security-group --group-id <WRK_SG>
aws ec2 delete-key-pair --key-name k8s-keypair
```
