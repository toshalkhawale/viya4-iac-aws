## AWS-EKS
#
# Terraform Registry : https://registry.terraform.io/namespaces/terraform-aws-modules
# GitHub Repository  : https://github.com/terraform-aws-modules
#

provider "aws" {
  region                  = var.location
  profile                 = var.aws_profile
  shared_credentials_file = var.aws_shared_credentials_file
  access_key              = var.aws_access_key_id
  secret_key              = var.aws_secret_access_key
  token                   = var.aws_session_token
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

data "aws_availability_zones" "available" {}

data "aws_caller_identity" "terraform" {}

locals {
  cluster_name                         = "${var.prefix}-eks"
  default_public_access_cidrs          = var.default_public_access_cidrs == null ? [] : var.default_public_access_cidrs
  vm_public_access_cidrs               = var.vm_public_access_cidrs == null ? local.default_public_access_cidrs : var.vm_public_access_cidrs
  cluster_endpoint_cidrs               = var.cluster_endpoint_public_access_cidrs == null ? local.default_public_access_cidrs : var.cluster_endpoint_public_access_cidrs
  cluster_endpoint_public_access_cidrs = length(local.cluster_endpoint_cidrs) == 0 ? [] : local.cluster_endpoint_cidrs
  postgres_public_access_cidrs         = var.postgres_public_access_cidrs == null ? local.default_public_access_cidrs : var.postgres_public_access_cidrs

  vpc_private_subnets                  = length(var.subnet_ids) == 0 ? module.vpc.private_subnets : var.subnet_ids["private"]

  db_subnet_public                     = length(var.subnet_ids) == 0 ? module.vpc.public_subnets : var.subnet_ids["public"]
  db_subnet_private                    = length(var.subnet_ids) == 0 ? module.vpc.database_subnets : var.subnet_ids["private"]

  jump_vm_subnet_public                = length(var.subnet_ids) == 0 ? module.vpc.public_subnets[0] : var.subnet_ids["public"][0]
  jump_vm_subnet_private               = length(var.subnet_ids) == 0 ? module.vpc.private_subnets[0] : var.subnet_ids["private"][0]

  nfs_vm_subnet_public                 = length(var.subnet_ids) == 0 ? module.vpc.public_subnets[0] : var.subnet_ids["public"][0]
  nfs_vm_subnet_private                = length(var.subnet_ids) == 0 ? module.vpc.public_subnets[0] : var.subnet_ids["private"][0]

  kubeconfig_filename = "${var.prefix}-eks-kubeconfig.conf"
  kubeconfig_path     = var.iac_tooling == "docker" ? "/workspace/${local.kubeconfig_filename}" : local.kubeconfig_filename
  kubeconfig_ca_cert  = data.aws_eks_cluster.cluster.certificate_authority.0.data

  subnets = length(var.subnet_ids) == 0 ? var.subnets : {}
}

data "external" "git_hash" {
  program = ["files/tools/iac_git_info.sh"]
}

data "external" "iac_tooling_version" {
  program = ["files/tools/iac_tooling_version.sh"]
}

resource "kubernetes_config_map" "sas_iac_buildinfo" {
  metadata {
    name      = "sas-iac-buildinfo"
    namespace = "kube-system"
  }

  data = {
    git-hash    = lookup(data.external.git_hash.result, "git-hash")
    timestamp   = chomp(timestamp())
    iac-tooling = var.iac_tooling
    terraform   = <<EOT
version: ${lookup(data.external.iac_tooling_version.result, "terraform_version")}
revision: ${lookup(data.external.iac_tooling_version.result, "terraform_revision")}
provider-selections: ${lookup(data.external.iac_tooling_version.result, "provider_selections")}
outdated: ${lookup(data.external.iac_tooling_version.result, "terraform_outdated")}
EOT
  }
}

# EKS Provider
provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(local.kubeconfig_ca_cert)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

# VPC Setup - https://github.com/terraform-aws-modules/terraform-aws-vpc
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "2.70.0"

  create_vpc = var.vpc_id == null ? true : false

  name = "${var.prefix}-vpc"
  cidr = var.vpc_cidr
  # NOTE - Only have a list of 2 AZs. Then only look for these subnets in the EFS mount below.
  # azs                  = slice( data.aws_availability_zones.available.names, 0,1 )
  azs                  = data.aws_availability_zones.available.names
  private_subnets      = length(var.subnet_ids) == 0 ? local.subnets.private : []
  public_subnets       = length(var.subnet_ids) == 0 ? local.subnets.public : []
  database_subnets     = length(var.subnet_ids) == 0 ? local.subnets.db : []
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags                = var.tags
  public_subnet_tags  = merge(var.tags, { "kubernetes.io/role/elb" = "1" }, { "kubernetes.io/cluster/${var.prefix}-eks" = "shared" })
  private_subnet_tags = merge(var.tags, { "kubernetes.io/role/internal-elb" = "1" }, { "kubernetes.io/cluster/${var.prefix}-eks" = "shared" })
}

# Associate private subnets with the private routing table.
resource "aws_route_table_association" "private" {
  count = length(var.subnet_ids) == 0 ? length(local.subnets.private) : 0 

  subnet_id      = length(var.subnet_ids) == 0 ? local.subnets.private[count.index] : module.vpc.private_subnets[count.index]
  ## TODO: handle BYO network - lookup route_table_id from subnet_id?
  route_table_id = length(var.subnet_ids) == 0 ? local.subnets.private[count.index] : module.vpc.private_route_table_ids[0]
}

# Associate public subnets with the public routing table.
resource "aws_route_table_association" "public" {
  count = length(var.subnet_ids) == 0 ? length(local.subnets.private) : 0 

  subnet_id      = length(var.subnet_ids) == 0 ? local.subnets.private[count.index] : module.vpc.public_subnets[count.index]
  ## TODO: handle BYO network - lookup route_table_id from subnet_id?
  route_table_id = length(var.subnet_ids) == 0 ? local.subnets.private[count.index] : module.vpc.public_route_table_ids[0]
}

# Security Groups - https://www.terraform.io/docs/providers/aws/r/security_group.html
resource "aws_security_group" "sg" {
  name   = "${var.prefix}-sg"
  vpc_id = var.vpc_id == null ? module.vpc.vpc_id : var.vpc_id

  egress {
    description = "Allow all outbound traffic."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(var.tags, map("Name", "${var.prefix}-sg"))
}


# EFS File System - https://www.terraform.io/docs/providers/aws/r/efs_file_system.html
resource "aws_efs_file_system" "efs-fs" {
  count            = var.storage_type == "ha" ? 1 : 0
  creation_token   = "${var.prefix}-efs"
  performance_mode = var.efs_performance_mode
  tags             = merge(var.tags, map("Name", "${var.prefix}-efs"))
}

# EFS Mount Target - https://www.terraform.io/docs/providers/aws/r/efs_mount_target.html
resource "aws_efs_mount_target" "efs-mt" {
  # NOTE - Testing. use num_azs = 2
  count           = var.storage_type == "ha" ? length(local.vpc_private_subnets) : 0
  file_system_id  = aws_efs_file_system.efs-fs.0.id
  subnet_id       = element(local.vpc_private_subnets, count.index)
  security_groups = [aws_security_group.sg.id]
}

# Processing the cloud-init/jump/cloud-config template file
data "template_file" "jump-cloudconfig" {
  template = file("${path.module}/files/cloud-init/jump/cloud-config")
  vars = {
    rwx_filestore_endpoint  = var.storage_type == "ha" ? aws_efs_file_system.efs-fs.0.dns_name : module.nfs.private_ip_address
    rwx_filestore_path      = var.storage_type == "ha" ? "/" : "/export"
    jump_rwx_filestore_path = var.jump_rwx_filestore_path
    vm_admin                = var.jump_vm_admin
  }

  depends_on = [aws_efs_file_system.efs-fs, aws_efs_mount_target.efs-mt, module.nfs]
}

# Defining the cloud-config to use
data "template_cloudinit_config" "jump" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content      = data.template_file.jump-cloudconfig.rendered
  }
}

# Jump BOX
module "jump" {
  source             = "./modules/aws_vm"
  name               = "${var.prefix}-jump"
  tags               = var.tags
  subnet_id          = var.create_jump_public_ip ? local.jump_vm_subnet_public : local.jump_vm_subnet_private
  security_group_ids = [aws_security_group.sg.id]
  create_public_ip   = var.create_jump_public_ip

  os_disk_type                  = var.os_disk_type
  os_disk_size                  = var.os_disk_size
  os_disk_delete_on_termination = var.os_disk_delete_on_termination
  os_disk_iops                  = var.os_disk_iops

  create_vm      = var.create_jump_vm
  vm_type        = var.jump_vm_type
  vm_admin       = var.jump_vm_admin
  ssh_public_key = file(var.ssh_public_key)

  cloud_init = data.template_cloudinit_config.jump.rendered

  depends_on = [module.nfs, aws_security_group_rule.all]

}

resource "aws_security_group_rule" "vms" {
  count             = ((var.storage_type == "standard" && var.create_nfs_public_ip) || var.create_jump_vm) && length(local.vm_public_access_cidrs) > 0 ? 1 : 0
  type              = "ingress"
  description       = "Allow SSH from source"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = local.vm_public_access_cidrs
  security_group_id = aws_security_group.sg.id
}

resource "aws_security_group_rule" "all" {
  type              = "ingress"
  description       = "Allow internal security group communication."
  from_port         = 0
  to_port           = 0
  protocol          = "all"
  security_group_id = aws_security_group.sg.id
  self              = true
}

data "template_file" "nfs-cloudconfig" {
  template = file("${path.module}/files/cloud-init/nfs/cloud-config")
  count    = var.storage_type == "standard" ? 1 : 0

  vars = {
    vm_admin        = var.nfs_vm_admin
    base_cidr_block = var.vpc_cidr  ## TODO: handle BYO network
  }

}

# Defining the cloud-config to use
data "template_cloudinit_config" "nfs" {
  count = var.storage_type == "standard" ? 1 : 0

  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content      = data.template_file.nfs-cloudconfig.0.rendered
  }
}

# NFS Server VM
module "nfs" {
  source             = "./modules/aws_vm"
  name               = "${var.prefix}-nfs-server"
  tags               = var.tags
  subnet_id          = var.create_jump_public_ip ? local.nfs_vm_subnet_public : local.nfs_vm_subnet_private
  security_group_ids = [aws_security_group.sg.id]
  create_public_ip   = var.create_nfs_public_ip

  os_disk_type                  = var.os_disk_type
  os_disk_size                  = var.os_disk_size
  os_disk_delete_on_termination = var.os_disk_delete_on_termination
  os_disk_iops                  = var.os_disk_iops

  data_disk_count             = 4
  data_disk_type              = var.nfs_raid_disk_type
  data_disk_size              = var.nfs_raid_disk_size
  data_disk_iops              = var.nfs_raid_disk_iops
  data_disk_availability_zone = data.aws_availability_zones.available.names[0]

  create_vm      = var.storage_type == "standard" ? true : false
  vm_type        = var.nfs_vm_type
  vm_admin       = var.nfs_vm_admin
  ssh_public_key = file(var.ssh_public_key)

  cloud_init = var.storage_type == "standard" ? data.template_cloudinit_config.nfs.0.rendered : null
}

# EBS CSI driver IAM Policy for EKS worker nodes - https://registry.terraform.io/modules/terraform-aws-modules/iam
module "iam_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "3.8.0"

  name        = "${var.prefix}_ebs_csi_policy"
  description = "EBS CSI driver IAM Policy"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "ec2:AttachVolume",
        "ec2:CreateSnapshot",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:DeleteSnapshot",
        "ec2:DeleteTags",
        "ec2:DeleteVolume",
        "ec2:DescribeInstances",
        "ec2:DescribeSnapshots",
        "ec2:DescribeTags",
        "ec2:DescribeVolumes",
        "ec2:DetachVolume",
        "elasticfilesystem:DescribeFileSystems",
        "iam:DeletePolicyVersion"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}

# Mapping node_pools to worker_groups
locals {

  default_node_pool = [
    {
      name                 = "default"
      instance_type        = var.default_nodepool_vm_type
      root_volume_size     = var.default_nodepool_os_disk_size
      root_volume_type     = var.default_nodepool_os_disk_type
      root_iops            = var.default_nodepool_os_disk_iops
      asg_desired_capacity = var.default_nodepool_node_count
      asg_min_size         = var.default_nodepool_min_nodes
      asg_max_size         = var.default_nodepool_max_nodes
      kubelet_extra_args   = "--node-labels=${replace(replace(jsonencode(var.default_nodepool_labels), "/[\"\\{\\}]/", ""), ":", "=")} --register-with-taints=${join(",", var.default_nodepool_taints)}"
      additional_userdata  = (var.default_nodepool_custom_data != "" ? file(var.default_nodepool_custom_data) : "")
    }
  ]

  user_node_pool = [
    for np_key, np_value in var.node_pools :
      {
        name                 = np_key
        instance_type        = np_value.vm_type
        root_volume_size     = np_value.os_disk_size
        root_volume_type     = np_value.os_disk_type
        root_iops            = np_value.os_disk_iops
        asg_desired_capacity = np_value.min_nodes
        asg_min_size         = np_value.min_nodes
        asg_max_size         = np_value.max_nodes
        kubelet_extra_args   = "--node-labels=${replace(replace(jsonencode(np_value.node_labels), "/[\"\\{\\}]/", ""), ":", "=")} --register-with-taints=${join(",", np_value.node_taints)}"
        additional_userdata  = (np_value.custom_data != "" ? file(np_value.custom_data) : "")
      }
  ]

  # Merging the default_node_pool into the work_groups node pools
  worker_groups = concat(local.default_node_pool, local.user_node_pool)
}

# EKS Setup - https://github.com/terraform-aws-modules/terraform-aws-eks
module "eks" {
  source                                = "terraform-aws-modules/eks/aws"
  version                               = "14.0.0"
  cluster_name                          = local.cluster_name
  cluster_version                       = var.kubernetes_version
  cluster_endpoint_private_access       = true
  cluster_endpoint_private_access_cidrs = [var.vpc_cidr]  ## TODO: handle BYO network
  cluster_endpoint_public_access        = true
  cluster_endpoint_public_access_cidrs  = local.cluster_endpoint_public_access_cidrs
  write_kubeconfig                      = false
  subnets                               = length(var.subnet_ids) == 0 ? concat([module.vpc.private_subnets.0, module.vpc.private_subnets.1]) : var.subnet_ids["private"]
  vpc_id                                = var.vpc_id == null ? module.vpc.vpc_id : var.vpc_id
  tags                                  = var.tags

  workers_group_defaults = {
    # tags = var.tags
    additional_security_group_ids = [aws_security_group.sg.id]
  }

  # Added to support EBS CSI driver
  workers_additional_policies = [module.iam_policy.arn]

  worker_groups = local.worker_groups
}

module "kubeconfig" {
  source                   = "./modules/kubeconfig"
  prefix                   = var.prefix
  create_static_kubeconfig = var.create_static_kubeconfig
  path                     = local.kubeconfig_path
  namespace                = "kube-system"

  cluster_name             = local.cluster_name
  endpoint                 = module.eks.cluster_endpoint
  ca_crt                   = local.kubeconfig_ca_cert

  depends_on = [ module.eks ]
}

# Database Setup - https://github.com/terraform-aws-modules/terraform-aws-rds
module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "2.20.0"

  identifier = (var.postgres_server_name == "" ? "${var.prefix}db" : var.postgres_server_name)

  engine            = "postgres"
  engine_version    = var.postgres_server_version
  instance_class    = var.postgres_instance_type # sku_name
  allocated_storage = var.postgres_storage_size
  storage_encrypted = var.postgres_storage_encrypted

  # kms_key_id        = "arm:aws:kms:<region>:<account id>:key/<kms key id>"
  name = var.postgres_db_name

  # NOTE: Do NOT use 'user' as the value for 'username' as it throws:
  # "Error creating DB Instance: InvalidParameterValue: MasterUsername
  # user cannot be used as it is a reserved word used by the engine"
  username = var.postgres_administrator_login
  password = var.postgres_administrator_password
  port     = var.postgres_server_port

  vpc_security_group_ids = [aws_security_group.sg.id]

  maintenance_window = "Mon:00:00-Mon:03:00"
  backup_window      = "03:00-06:00"

  # disable backups to create DB faster
  backup_retention_period = var.postgres_backup_retention_days

  tags = var.tags

  # enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # DB subnet group - use public subnet if public access is requested
  publicly_accessible = length(local.postgres_public_access_cidrs) > 0 ? true : false
  subnet_ids          = length(local.postgres_public_access_cidrs) > 0 ? local.db_subnet_public : local.db_subnet_private

  # DB parameter group
  family = "postgres${var.postgres_server_version}"

  # DB option group
  major_engine_version = var.postgres_server_version

  # Snapshot name upon DB deletion
  final_snapshot_identifier = (var.postgres_server_name == "" ? var.prefix : var.postgres_server_name)

  # Database Deletion Protection
  deletion_protection = var.postgres_deletion_protection

  multi_az = var.postgres_multi_az

  parameters = var.postgres_parameters
  options    = var.postgres_options

  # Flags for module to flag if postgres should be created or not.
  create_db_instance        = var.create_postgres
  create_db_subnet_group    = var.create_postgres
  create_db_parameter_group = var.create_postgres
  create_db_option_group    = var.create_postgres

}

resource "aws_security_group_rule" "postgres_internal" {
  count             = var.create_postgres ? 1 : 0
  type              = "ingress"
  description       = "Allow Postgres within network"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.sg.id
}

resource "aws_security_group_rule" "postgres_external" {
  count             = var.create_postgres && length(local.postgres_public_access_cidrs) > 0 ? 1 : 0
  type              = "ingress"
  description       = "Allow Postgres from source"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  cidr_blocks       = local.postgres_public_access_cidrs
  security_group_id = aws_security_group.sg.id
}

# Resource Groups - https://www.terraform.io/docs/providers/aws/r/resourcegroups_group.html
resource "aws_resourcegroups_group" "aws_rg" {
  name = "${var.prefix}-rg"

  resource_query {
    query = <<JSON
{
  "ResourceTypeFilters": [
    "AWS::AllSupported"
  ],
  "TagFilters": ${jsonencode([
    for key, values in var.tags : {
      "Key" : key,
      "Values" : [values]
    }
])}
}
JSON
}
}
