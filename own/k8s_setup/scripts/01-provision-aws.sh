#!/usr/bin/env bash
# =============================================================================
# 01-provision-aws.sh — Phase 1: AWS Infrastructure Provisioning
# =============================================================================
# Creates: key pair, security groups, and 2 EC2 instances (Ubuntu 22.04)
#   - k8s-control-plane  (t3.medium, 30GB gp3)
#   - k8s-worker-1       (t3.medium, 30GB gp3)
#
# Prerequisites:
#   - AWS CLI configured (aws configure)
#   - jq installed (brew install jq / apt install jq)
#
# Usage:
#   bash 01-provision-aws.sh
#   bash 01-provision-aws.sh --region us-east-1
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config — override via env or flags
# ---------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-$(aws configure get region)}"
KEY_NAME="k8s-keypair"
KEY_PATH="$HOME/.ssh/${KEY_NAME}.pem"
INSTANCE_TYPE="t3.medium"
VOLUME_SIZE=30

# Parse optional --region flag
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) AWS_REGION="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

export AWS_DEFAULT_REGION="$AWS_REGION"

echo "==> Region: $AWS_REGION"
echo "==> Instance type: $INSTANCE_TYPE"

# ---------------------------------------------------------------------------
# 1.1 Key Pair
# ---------------------------------------------------------------------------
echo ""
echo "--- [1/5] Key Pair ---"
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" &>/dev/null; then
  echo "Key pair '$KEY_NAME' already exists — skipping creation."
else
  aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --query 'KeyMaterial' \
    --output text > "$KEY_PATH"
  chmod 400 "$KEY_PATH"
  echo "Created key pair: $KEY_PATH"
fi

# ---------------------------------------------------------------------------
# 1.2 VPC & Subnet
# ---------------------------------------------------------------------------
echo ""
echo "--- [2/5] VPC & Subnet ---"
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)

if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
  echo "ERROR: No default VPC found in region $AWS_REGION."
  echo "Create one with: aws ec2 create-default-vpc"
  exit 1
fi
echo "VPC: $VPC_ID"

SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[0].SubnetId" --output text)
echo "Subnet: $SUBNET_ID"

# ---------------------------------------------------------------------------
# 1.3 Security Groups
# ---------------------------------------------------------------------------
echo ""
echo "--- [3/5] Security Groups ---"

create_sg_if_missing() {
  local name="$1" desc="$2"
  local existing
  existing=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$name" "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
  if [[ "$existing" != "None" && -n "$existing" ]]; then
    echo "$existing"
  else
    aws ec2 create-security-group \
      --group-name "$name" \
      --description "$desc" \
      --vpc-id "$VPC_ID" \
      --query GroupId --output text
  fi
}

CP_SG=$(create_sg_if_missing "k8s-control-plane-sg" "K8s Control Plane")
WRK_SG=$(create_sg_if_missing "k8s-worker-sg" "K8s Worker Nodes")
echo "Control plane SG: $CP_SG"
echo "Worker SG:        $WRK_SG"

authorize_if_missing() {
  # Silently ignores duplicate rule errors
  aws ec2 authorize-security-group-ingress "$@" 2>/dev/null || true
}

# Control plane rules
authorize_if_missing --group-id "$CP_SG" --protocol tcp --port 22    --cidr 0.0.0.0/0
authorize_if_missing --group-id "$CP_SG" --protocol tcp --port 6443  --cidr 0.0.0.0/0
authorize_if_missing --group-id "$CP_SG" --protocol tcp --port 2379-2380  --source-group "$CP_SG"
authorize_if_missing --group-id "$CP_SG" --protocol tcp --port 10250-10259 --source-group "$CP_SG"
authorize_if_missing --group-id "$CP_SG" --protocol -1  --source-group "$WRK_SG"

# Worker node rules
authorize_if_missing --group-id "$WRK_SG" --protocol tcp --port 22          --cidr 0.0.0.0/0
authorize_if_missing --group-id "$WRK_SG" --protocol tcp --port 10250       --source-group "$CP_SG"
authorize_if_missing --group-id "$WRK_SG" --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0
authorize_if_missing --group-id "$WRK_SG" --protocol -1  --source-group "$CP_SG"

echo "Security group rules applied."

# ---------------------------------------------------------------------------
# 1.4 Ubuntu 22.04 AMI
# ---------------------------------------------------------------------------
echo ""
echo "--- [4/5] AMI Lookup ---"
AMI_ID=$(aws ec2 describe-images \
  --owners 099720109477 \
  --filters \
    "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
    "Name=state,Values=available" \
    "Name=architecture,Values=x86_64" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text)
echo "AMI: $AMI_ID (Ubuntu 22.04 LTS)"

# ---------------------------------------------------------------------------
# 1.5 Launch EC2 Instances
# ---------------------------------------------------------------------------
echo ""
echo "--- [5/5] Launching EC2 Instances ---"

launch_instance() {
  local name="$1" role="$2" sg="$3"
  local existing
  existing=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$name" "Name=instance-state-name,Values=running,pending,stopped" \
    --query "Reservations[0].Instances[0].InstanceId" --output text 2>/dev/null || true)
  if [[ "$existing" != "None" && -n "$existing" ]]; then
    echo "$existing"
  else
    aws ec2 run-instances \
      --image-id "$AMI_ID" \
      --instance-type "$INSTANCE_TYPE" \
      --key-name "$KEY_NAME" \
      --security-group-ids "$sg" \
      --subnet-id "$SUBNET_ID" \
      --associate-public-ip-address \
      --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"gp3\"}}]" \
      --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Role,Value=${role}},{Key=Cluster,Value=foundation-rag}]" \
      --query "Instances[0].InstanceId" --output text
  fi
}

CP_ID=$(launch_instance "k8s-control-plane" "control-plane" "$CP_SG")
WRK_ID=$(launch_instance "k8s-worker-1" "worker" "$WRK_SG")
echo "Control plane instance: $CP_ID"
echo "Worker instance:        $WRK_ID"

echo ""
echo "Waiting for instances to reach 'running' state..."
aws ec2 wait instance-running --instance-ids "$CP_ID" "$WRK_ID"
echo "Both instances are running."

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
CP_PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$CP_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
CP_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids "$CP_ID" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
WRK_PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$WRK_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo ""
echo "============================================================"
echo " CLUSTER INSTANCES READY"
echo "============================================================"
echo " Control Plane:"
echo "   Instance ID : $CP_ID"
echo "   Public IP   : $CP_PUBLIC_IP"
echo "   Private IP  : $CP_PRIVATE_IP"
echo ""
echo " Worker Node:"
echo "   Instance ID : $WRK_ID"
echo "   Public IP   : $WRK_PUBLIC_IP"
echo ""
echo " SSH:"
echo "   ssh -i $KEY_PATH ubuntu@$CP_PUBLIC_IP   # control plane"
echo "   ssh -i $KEY_PATH ubuntu@$WRK_PUBLIC_IP  # worker"
echo ""
echo " NEXT STEP: Run 02-node-prep.sh on BOTH nodes."
echo " Pass the control plane private IP when initialising:"
echo "   CP_PRIVATE_IP=$CP_PRIVATE_IP"
echo "============================================================"

# Save IPs for later scripts
cat > "$(dirname "$0")/cluster-ips.env" <<EOF
CP_PUBLIC_IP=$CP_PUBLIC_IP
CP_PRIVATE_IP=$CP_PRIVATE_IP
WRK_PUBLIC_IP=$WRK_PUBLIC_IP
CP_ID=$CP_ID
WRK_ID=$WRK_ID
EOF
echo "IPs saved to scripts/cluster-ips.env"
