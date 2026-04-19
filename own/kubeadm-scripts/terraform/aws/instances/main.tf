provider "aws" {
  region = "eu-west-1"
}

data "aws_subnets" "vpc_subnets" {
  filter {
    name   = "vpc-id"
    values = ["vpc-035369def6854bbeb"]
  }
}

module "ec2_instance" {
  source = "../modules/ec2"

  instance_name  = "k8s-node"
  ami_id         = "ami-00c257e12d6828491"
  instance_type  = "t2.medium"
  vpc_id         = "vpc-035369def6854bbeb"
  subnet_ids     = data.aws_subnets.vpc_subnets.ids
  instance_count = 3

  inbound_from_port  = ["0", "6443", "30000", "0"]
  inbound_to_port    = ["65000", "6443", "32768", "65000"]
  inbound_protocol   = ["TCP", "TCP", "TCP", "TCP"]
  inbound_cidr       = ["172.31.0.0/16", "0.0.0.0/0", "0.0.0.0/0", "10.244.0.0/16"]
  outbound_from_port = ["0"]
  outbound_to_port   = ["0"]
  outbound_protocol  = ["-1"]
  outbound_cidr      = ["0.0.0.0/0"]
}
