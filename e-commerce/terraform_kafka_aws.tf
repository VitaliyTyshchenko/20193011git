

# terraform kafka
# │
# ├── AWS NATIVE (managed)
# │   ├── Amazon MSK Provisioned        ← Kafka
# │   ├── Amazon MQ                     ← RabbitMQ
# │   ├── AWS Lambda                    ← business logic
# │   ├── Amazon API Gateway (HTTP)     ← REST API
# │   ├── Amazon DynamoDB               ← orders DB
# │   ├── Amazon S3                     ← frontend files
# │   ├── Amazon CloudFront             ← CDN / storefront
# │   ├── AWS Secrets Manager           ← broker credentials
# │   ├── Amazon CloudWatch             ← logs & metrics
# │   ├── AWS IAM                       ← roles & policies
# │   ├── Amazon VPC / subnets / SGs    ← networking
# │   └── Amazon ECS Fargate cluster    ← container platform
# │
# └── THIRD-PARTY CONTAINERS (on ECS Fargate)
#    ├── apache/rocketmq:5.1.4         ← RocketMQ nameserver
#    ├── apache/rocketmq:5.1.4         ← RocketMQ broker
#    ├── apacherocketmq/rocketmq-dashboard ← RocketMQ web UI
#    └── provectuslabs/kafka-ui        ← Kafka web UI



# Layer 	Technology 	Type 	Est. cost/mo
# Static storefront	Amazon S3 + CloudFront	AWS Native	$0
# REST API	Amazon API Gateway (HTTP)	AWS Native	$0
# Business logic	AWS Lambda — Python 3.11	AWS Native	$0
# Orders database	Amazon DynamoDB (PAY_PER_REQUEST)	AWS Native	$0
# Kafka broker	Amazon MSK — kafka.t3.small × 2	AWS Native	~$154
# RabbitMQ broker	Amazon MQ — mq.m5.large, v3.13	AWS Native	~$216
# RocketMQ	ECS Fargate — apache/rocketmq:5.1.4	Container	~$45
# Kafka UI	ECS Fargate — provectuslabs/kafka-ui	Container	~$15
# Credentials	AWS Secrets Manager + KMS	AWS Native	~$1.40
# Observability	Amazon CloudWatch	AWS Native	~$1
# Networking	VPC, Subnets, IGW, Security Groups	AWS Native	$0
# Total	~$432

# Deploy Steps
# # 	File 	Resources provisioned 	Deploy 	Cost/mo 	Saves
# 1 	…step1foundation… 	Credentials (single random_string), KMS key, VPC, subnets, IGW, route tables 	~1 min 	$1 	step1_credentials.txt
# 2 	…step2networking… 	4 Security Groups (lambda, msk, mq, ecs), DynamoDB VPC gateway endpoint 	~1 min 	$0 	step2_networking.txt
# 3 	…step3iam… 	Lambda execution role, ECS execution role, ECS task role + policies 	~1 min 	$0 	—
# 4 	…step4storage… 	DynamoDB table (orders), S3 bucket (versioning on), Secrets Manager secret 	~2 min 	$0.40 	—
# 5 	…step5brokersmskmq… 	MSK cluster (Kafka 3.8.x, SASL/SCRAM, public=DISABLED), Amazon MQ (RabbitMQ) 	~25–35 min 	$370 	step5_brokers.txt
# 6 	…step6lambdalayer… 	S3 bucket for layer zip, CodeBuild project, null_resource trigger, Lambda layer 	~3–5 min 	$0 	step6_layer.txt
# 7 	…step7lambdafunctions… 	3 Lambda functions: order_handler, payment_handler, orders_list_handler + CloudWatch log groups 	~2 min 	$0 	—
# 8 	…step8apigateway… 	HTTP API, 4 routes (POST /orders, GET /orders, GET /orders/{id}, POST /orders/{id}/pay) 	~1 min 	$0 	step8_api.txt
# 9 	…step9ecsrocketmq… 	ECS cluster, Service Discovery, RocketMQ (nameserver+broker+dashboard), Kafka UI, CloudFront, S3 HTML 	~7 min 	$75 	step9_endpoints.txt
# 10 	…step10outputs… 	All final Terraform outputs, uri.txt with every endpoint + credential 	~1 min 	

########################

terraform {
  required_version = "= 1.15.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.60.0"
    }

    local = {
      source  = "hashicorp/local"
      version = "= 2.9.1"
    }

    null = {
      source  = "hashicorp/null"
      version = "= 3.3.2"
    }
  }
}

locals {
  project = "terraformautokafka"
  azs     = ["us-east-1a", "us-east-1b"]
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}


###########################

# =============================================================
# STEP 1 — Foundation (no dependencies)
# Resources: credentials, KMS, VPC
# Cost estimate:
#   random_string/password : free
#   aws_kms_key            : ~$1/month + $0.03 per 10k API calls
#   aws_vpc + subnets      : free
#   aws_internet_gateway   : free (pay only for data transfer)
#   aws_route_table        : free
#   Total step 1           : ~$1/month
# =============================================================

# =============================================================
# CREDENTIALS — one pair, aliased per service via locals
# =============================================================

resource "random_string" "shared_username_shared_password" {
  length  = 17
  special = false
  upper   = false
}



locals {
  kafka_username    = random_string.shared_username_shared_password.result
  kafka_password    = random_string.shared_username_shared_password.result
  rabbitmq_username = random_string.shared_username_shared_password.result
  rabbitmq_password = random_string.shared_username_shared_password.result
  rocketmq_username = random_string.shared_username_shared_password.result
  rocketmq_password = random_string.shared_username_shared_password.result
}

# =============================================================
# AUTO-SAVE step1_credentials.txt
# =============================================================

resource "local_file" "step1_credentials_txt" {
  filename        = "${path.module}/step1_credentials.txt"
  file_permission = "0644"
  content         = <<-EOT
PROJECT=terraformautokafka

SHARED_USERNAME=${random_string.shared_username_shared_password.result}
SHARED_PASSWORD=${random_string.shared_username_shared_password.result}

KAFKA_USERNAME=${local.kafka_username}
KAFKA_PASSWORD=${local.kafka_password}
RABBITMQ_USERNAME=${local.rabbitmq_username}
RABBITMQ_PASSWORD=${local.rabbitmq_password}
ROCKETMQ_USERNAME=${local.rocketmq_username}
ROCKETMQ_PASSWORD=${local.rocketmq_password}
EOT
}

# =============================================================
# KMS KEY (required for MSK SCRAM secret encryption)
# =============================================================

resource "aws_kms_key" "msk" {
  description             = "${local.project} MSK SCRAM encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "msk" {
  name          = "alias/${local.project}-msk"
  target_key_id = aws_kms_key.msk.key_id
}

# =============================================================
# VPC
# =============================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = local.azs[count.index]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

#############


# =============================================================
# STEP 2 — Networking (depends on VPC from step 1)
# Resources: security groups, VPC endpoint for DynamoDB
# Cost estimate:
#   aws_security_group       : free
#   aws_vpc_endpoint dynamo  : free (Gateway type)
#   Total step 2             : $0/month
# =============================================================

# =============================================================
# SECURITY GROUPS
# =============================================================

resource "aws_security_group" "lambda" {
  name   = "${local.project}-lambda"
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "msk" {
  name   = "${local.project}-msk"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "Kafka TLS internal"
    from_port   = 9094
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Kafka SASL/SCRAM internal"
    from_port   = 9096
    to_port     = 9096
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Kafka SASL/SCRAM public"
    from_port   = 9196
    to_port     = 9196
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Lambda to MSK"
    from_port   = 9094
    to_port     = 9196
    protocol    = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "mq" {
  name   = "${local.project}-mq"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "RabbitMQ AMQPS"
    from_port   = 5671
    to_port     = 5671
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "RabbitMQ management console"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs" {
  name   = "${local.project}-ecs"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "RocketMQ nameserver"
    from_port   = 9876
    to_port     = 9876
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "RocketMQ broker"
    from_port   = 10909
    to_port     = 10912
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "RocketMQ dashboard and Kafka UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =============================================================
# VPC ENDPOINT — DynamoDB (Gateway, free)
# Allows Lambda in private subnets to reach DynamoDB
# without internet/NAT
# =============================================================

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

# =============================================================
# AUTO-SAVE step2_networking.txt
# =============================================================

resource "local_file" "step2_networking_txt" {
  filename        = "${path.module}/step2_networking.txt"
  file_permission = "0644"
  content         = <<-EOT
PROJECT=terraformautokafka

VPC_ID=${aws_vpc.main.id}
PUBLIC_SUBNET_1=${aws_subnet.public[0].id}
PUBLIC_SUBNET_2=${aws_subnet.public[1].id}
PRIVATE_SUBNET_1=${aws_subnet.private[0].id}
PRIVATE_SUBNET_2=${aws_subnet.private[1].id}
SG_LAMBDA=${aws_security_group.lambda.id}
SG_MSK=${aws_security_group.msk.id}
SG_MQ=${aws_security_group.mq.id}
SG_ECS=${aws_security_group.ecs.id}
DYNAMODB_VPC_ENDPOINT=${aws_vpc_endpoint.dynamodb.id}
EOT

  depends_on = [aws_vpc_endpoint.dynamodb]
}



########

# =============================================================
# STEP 3 — IAM (depends on VPC, DynamoDB, Secrets Manager)
# Resources: Lambda role, ECS execution role, ECS task role
# Cost estimate:
#   IAM roles/policies : free
#   Total step 3       : $0/month
# =============================================================

# =============================================================
# LAMBDA IAM ROLE
# =============================================================

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.project}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name = "${local.project}-lambda-permissions"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = "arn:aws:dynamodb:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${local.project}-orders"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:AmazonMSK_${local.project}*"
      },
      {
        Effect   = "Allow"
        Action   = ["kafka-cluster:*"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

# =============================================================
# ECS EXECUTION ROLE (pulls images, writes logs)
# =============================================================

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${local.project}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# =============================================================
# ECS TASK ROLE (runtime permissions for containers)
# =============================================================

resource "aws_iam_role" "ecs_task" {
  name               = "${local.project}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy" "ecs_task_permissions" {
  name = "${local.project}-ecs-task-permissions"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "secretsmanager:GetSecretValue",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}



############


# =============================================================
# STEP 4 — Storage (depends on IAM, KMS)
# Resources: DynamoDB, S3, Secrets Manager (Kafka SCRAM)
# Cost estimate:
#   DynamoDB PAY_PER_REQUEST : ~$0 at low volume
#   S3 bucket                : ~$0 (minimal static files)
#   Secrets Manager secret   : $0.40/month per secret
#   Total step 4             : ~$0.40/month
# Deploy time  : ~1-2 min
# Deletion time: ~1-2 min
# =============================================================

# =============================================================
# DYNAMODB — orders table
# =============================================================

resource "aws_dynamodb_table" "orders" {
  name         = "${local.project}-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "orderId"

  attribute {
    name = "orderId"
    type = "S"
  }
}

# =============================================================
# S3 — frontend bucket
# =============================================================

resource "aws_s3_bucket" "frontend" {
  bucket        = "${local.project}-frontend-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =============================================================
# SECRETS MANAGER — Kafka SCRAM credentials
# Must use customer KMS key (MSK requirement)
# =============================================================

resource "aws_secretsmanager_secret" "kafka_scram" {
  name       = "AmazonMSK_${local.project}"
  kms_key_id = aws_kms_key.msk.id
}

resource "aws_secretsmanager_secret_version" "kafka_scram" {
  secret_id = aws_secretsmanager_secret.kafka_scram.id
  secret_string = jsonencode({
    username = local.kafka_username
    password = local.kafka_password
  })
}



############


# =============================================================
# STEP 5 — Brokers: MSK (Kafka) + Amazon MQ (RabbitMQ)
# Depends on: VPC, subnets, security groups, KMS, Secrets Manager
# MSK requires minimum 2 brokers — it's an AWS hard limit
# Cost estimate:
#   MSK kafka.t3.small x2 brokers : ~$150/month
#   MSK EBS storage 20GB x2       : ~$4/month
#   Amazon MQ mq.m5.large         : ~$216/month
#   Total step 5                  : ~$370/month
#
# MSK provisions the full Kafka cluster internally — creates EC2 instances, 
# formats EBS volumes, starts Kafka brokers, configures ZooKeeper/KRaft, runs health checks, so
# Deploy time  : ~20-35 min (MSK is slow)
# Deletion time: ~20-35 min
# =============================================================
# OUTPUTS after this step (run: terraform output > step5_brokers.txt)
# =============================================================

# =============================================================
# MSK CONFIGURATION
# =============================================================

resource "aws_msk_configuration" "main" {
  name           = local.project
  kafka_versions = ["3.8.x"]
  server_properties = <<-PROPS
    auto.create.topics.enable=true
    delete.topic.enable=true
    log.retention.hours=24
    num.partitions=3
    default.replication.factor=2
    allow.everyone.if.no.acl.found=false
  PROPS
}

# =============================================================
# MSK CLUSTER (Kafka)
# =============================================================

resource "aws_msk_cluster" "main" {
  cluster_name           = local.project
  kafka_version          = "3.8.x"
  number_of_broker_nodes = 2

  configuration_info {
    arn      = aws_msk_configuration.main.arn
    revision = aws_msk_configuration.main.latest_revision
  }

  broker_node_group_info {
    instance_type   = "kafka.t3.small"
    client_subnets  = aws_subnet.private[*].id
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info { volume_size = 20 }
    }

    connectivity_info {
      public_access {
        type = "DISABLED"

   # step 5555 1111 enable public access
   # type = "SERVICE_PROVIDED_EIPS"



      }
    }
  }

  client_authentication {
    sasl {
      scram = true
    }
    unauthenticated = false
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
    encryption_at_rest_kms_key_arn = aws_kms_key.msk.arn
  }

  open_monitoring {
    prometheus {
      jmx_exporter  { enabled_in_broker = true }
      node_exporter { enabled_in_broker = true }
    }
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
    }
  }

  depends_on = [aws_secretsmanager_secret_version.kafka_scram]
}

resource "aws_cloudwatch_log_group" "msk" {
  name              = "/aws/msk/${local.project}"
  retention_in_days = 7
}

# =============================================================
# MSK SCRAM SECRET ASSOCIATION
# =============================================================

resource "aws_msk_scram_secret_association" "main" {
  cluster_arn     = aws_msk_cluster.main.arn
  secret_arn_list = [aws_secretsmanager_secret.kafka_scram.arn]
  depends_on      = [aws_secretsmanager_secret_version.kafka_scram]
}

# =============================================================
# AMAZON MQ — RabbitMQ
# =============================================================

resource "aws_mq_broker" "rabbitmq" {
  broker_name                = local.project
  engine_type                = "RabbitMQ"
  engine_version             = "3.13"
  host_instance_type         = "mq.m5.large"
  publicly_accessible        = true
  auto_minor_version_upgrade = true
  subnet_ids                 = [aws_subnet.public[0].id]

  user {
    username = local.rabbitmq_username
    password = local.rabbitmq_password
  }

  logs {
    general = true
  }

  maintenance_window_start_time {
    day_of_week = "SUNDAY"
    time_of_day = "02:00"
    time_zone   = "UTC"
  }
}

# =============================================================
# OUTPUTS — step 5 checkpoints
# =============================================================

output "step5_kafka_bootstrap_internal" {
  value       = aws_msk_cluster.main.bootstrap_brokers_sasl_scram
  description = "MSK internal SASL/SCRAM bootstrap (used by Lambda)"
}

output "step5_kafka_bootstrap_public" {
  value       = aws_msk_cluster.main.bootstrap_brokers_public_sasl_scram
  description = "MSK public SASL/SCRAM bootstrap (used by Kafka UI)"
}

output "step5_kafka_username" {
  value     = local.kafka_username

}

output "step5_kafka_password" {
  value     = local.kafka_password

}

output "step5_rabbitmq_management_url" {
  value       = aws_mq_broker.rabbitmq.instances[0].console_url
  description = "RabbitMQ web console URL"
}

output "step5_rabbitmq_amqp_url" {
  value       = aws_mq_broker.rabbitmq.instances[0].endpoints[0]
  description = "RabbitMQ AMQPS endpoint"
  sensitive   = true
}

output "step5_rabbitmq_username" {
  value     = local.rabbitmq_username

}

output "step5_rabbitmq_password" {
  value     = local.rabbitmq_password

}

# =============================================================
# AUTO-SAVE step5_brokers.txt after brokers are ready
# =============================================================

resource "null_resource" "save_step5_txt" {
  triggers = {
    msk_arn = aws_msk_cluster.main.arn
    mq_arn  = aws_mq_broker.rabbitmq.arn
  }

  provisioner "local-exec" {
    command = <<-CMD
      echo KAFKA_BOOTSTRAP_INTERNAL=${aws_msk_cluster.main.bootstrap_brokers_sasl_scram} > step5_brokers.txt
      echo KAFKA_BOOTSTRAP_PUBLIC=${aws_msk_cluster.main.bootstrap_brokers_public_sasl_scram} >> step5_brokers.txt
      echo KAFKA_USERNAME=${local.kafka_username} >> step5_brokers.txt
      echo KAFKA_PASSWORD=${local.kafka_password} >> step5_brokers.txt
      echo RABBITMQ_MANAGEMENT_URL=${aws_mq_broker.rabbitmq.instances[0].console_url} >> step5_brokers.txt
      echo RABBITMQ_AMQP_URL=${aws_mq_broker.rabbitmq.instances[0].endpoints[0]} >> step5_brokers.txt
      echo RABBITMQ_USERNAME=${local.rabbitmq_username} >> step5_brokers.txt
      echo RABBITMQ_PASSWORD=${local.rabbitmq_password} >> step5_brokers.txt
    CMD
  }

  depends_on = [
    aws_msk_scram_secret_association.main,
    aws_mq_broker.rabbitmq
  ]
}



##########


# =============================================================
# STEP 6 — Lambda Layer via AWS CodeBuild (zero local deps)
# Depends on: S3 bucket (step 4), IAM (step 3)
# Cost estimate:
#   CodeBuild build (~2 min) : ~$0.001 one-time
#   Lambda layer storage     : free
#   Total step 6             : ~$0/month
# Deploy time  : ~3-5 min (CodeBuild runs in AWS)
# Deletion time: ~1 min
# =============================================================

# =============================================================
# S3 BUCKET FOR LAYER ZIP (CodeBuild output)
# =============================================================

resource "aws_s3_bucket" "lambda_layer" {
  bucket        = "${local.project}-lambda-layer-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

# =============================================================
# IAM ROLE FOR CODEBUILD
# =============================================================

resource "aws_iam_role" "codebuild" {
  name = "${local.project}-codebuild"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "${local.project}-codebuild"
  role = aws_iam_role.codebuild.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = ["${aws_s3_bucket.lambda_layer.arn}", "${aws_s3_bucket.lambda_layer.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:PublishLayerVersion", "lambda:GetLayerVersion"]
        Resource = "*"
      }
    ]
  })
}

# =============================================================
# CODEBUILD PROJECT — builds kafka-python layer zip
# =============================================================

resource "aws_codebuild_project" "lambda_layer" {
  name         = "${local.project}-lambda-layer"
  service_role = aws_iam_role.codebuild.arn

  artifacts {
    type      = "S3"
    location  = aws_s3_bucket.lambda_layer.bucket
    name      = "kafka_layer.zip"
    packaging = "ZIP"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "NO_SOURCE"
    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        build:
          commands:
            - mkdir -p python
            - pip install kafka-python==2.0.2 -t python/ --quiet
      artifacts:
        files:
          - "python/**/*"
    BUILDSPEC
  }
}

# =============================================================
# TRIGGER CODEBUILD — runs once at terraform apply
# =============================================================

resource "null_resource" "run_codebuild" {
  triggers = {
    project_name = aws_codebuild_project.lambda_layer.name
  }

  provisioner "local-exec" {
    command = <<-CMD
      BUILD_ID=$(aws codebuild start-build --project-name ${aws_codebuild_project.lambda_layer.name} --region ${data.aws_region.current.region} --query "build.id" --output text)
      echo "CodeBuild started: $BUILD_ID"
      while true; do
        STATUS=$(aws codebuild batch-get-builds --ids $BUILD_ID --region ${data.aws_region.current.region} --query "builds[0].buildStatus" --output text)
        echo "Build status: $STATUS"
        if [ "$STATUS" = "SUCCEEDED" ]; then echo "Build complete."; break; fi
        if [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "FAULT" ] || [ "$STATUS" = "STOPPED" ] || [ "$STATUS" = "TIMED_OUT" ]; then echo "Build failed: $STATUS"; exit 1; fi
        sleep 15
      done
    CMD
  }

  depends_on = [aws_codebuild_project.lambda_layer]
}

# =============================================================
# LAMBDA LAYER — uploaded from S3 after CodeBuild
# =============================================================

resource "aws_lambda_layer_version" "kafka_python" {
  layer_name               = "${local.project}-kafka-python"
  s3_bucket                = aws_s3_bucket.lambda_layer.bucket
  s3_key                   = "kafka_layer.zip"
  compatible_runtimes      = ["python3.11"]
  compatible_architectures = ["x86_64"]

  depends_on = [null_resource.run_codebuild]
}

# =============================================================
# OUTPUT + AUTO-SAVE step6_layer.txt
# =============================================================

output "step6_lambda_layer_arn" {
  value       = aws_lambda_layer_version.kafka_python.arn
  description = "kafka-python Lambda layer ARN"
}

resource "local_file" "step6_layer_txt" {
  filename        = "${path.module}/step6_layer.txt"
  file_permission = "0644"
  content         = <<-EOT
LAMBDA_LAYER_ARN=${aws_lambda_layer_version.kafka_python.arn}
LAMBDA_LAYER_NAME=${aws_lambda_layer_version.kafka_python.layer_name}
LAMBDA_LAYER_VERSION=${aws_lambda_layer_version.kafka_python.version}
EOT
  depends_on = [aws_lambda_layer_version.kafka_python]
}



##########

# =============================================================
# STEP 7 — Lambda Functions
# Depends on: IAM (step3), DynamoDB (step4), MSK (step5), layer (step6)
# Cost estimate:
#   Lambda invocations (low volume) : ~$0 (free tier covers it)
#   Total step 7                    : ~$0/month
# Deploy time  : ~1-2 min
# Deletion time: ~1 min
# =============================================================

# =============================================================
# ORDER HANDLER — create order, publish OrderCreated to Kafka
# =============================================================

resource "local_file" "order_handler_py" {
  filename = "${path.module}/.lambdas/order_handler.py"
  content  = <<-PYTHON
import json, os, boto3, uuid
from datetime import datetime

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['ORDERS_TABLE'])

def handler(event, context):
    try:
        body = json.loads(event.get('body') or '{}')
    except:
        body = {}

    order_id = str(uuid.uuid4())
    order = {
        'orderId':   order_id,
        'product':   body.get('product', 'Unknown'),
        'price':     str(body.get('price', 0)),
        'status':    'PENDING',
        'createdAt': datetime.utcnow().isoformat()
    }
    table.put_item(Item=order)

    try:
        from kafka import KafkaProducer
        import ssl
        ctx = ssl.create_default_context()
        producer = KafkaProducer(
            bootstrap_servers=os.environ['KAFKA_BOOTSTRAP'].split(','),
            security_protocol='SASL_SSL',
            sasl_mechanism='SCRAM-SHA-512',
            sasl_plain_username=os.environ['KAFKA_USERNAME'],
            sasl_plain_password=os.environ['KAFKA_PASSWORD'],
            ssl_context=ctx,
            value_serializer=lambda v: json.dumps(v).encode('utf-8'),
            request_timeout_ms=5000
        )
        producer.send('orders', {'event': 'OrderCreated', 'order': order})
        producer.flush(timeout=5)
        producer.close()
    except Exception as e:
        print(f"Kafka error (non-fatal): {e}")

    return {
        'statusCode': 201,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*'
        },
        'body': json.dumps(order)
    }
  PYTHON
}

data "archive_file" "order_handler" {
  type        = "zip"
  source_file = local_file.order_handler_py.filename
  output_path = "${path.module}/.lambdas/order_handler.zip"
  depends_on  = [local_file.order_handler_py]
}

resource "aws_lambda_function" "order" {
  filename         = data.archive_file.order_handler.output_path
  source_code_hash = data.archive_file.order_handler.output_base64sha256
  function_name    = "${local.project}-order"
  role             = aws_iam_role.lambda.arn
  handler          = "order_handler.handler"
  runtime          = "python3.11"
  timeout          = 30
  memory_size      = 256
  layers           = [aws_lambda_layer_version.kafka_python.arn]

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      ORDERS_TABLE    = aws_dynamodb_table.orders.name
      KAFKA_BOOTSTRAP = aws_msk_cluster.main.bootstrap_brokers_sasl_scram
      KAFKA_USERNAME  = local.kafka_username
      KAFKA_PASSWORD  = local.kafka_password
    }
  }
}

# =============================================================
# PAYMENT HANDLER — simulate payment, publish result to Kafka
# =============================================================

resource "local_file" "payment_handler_py" {
  filename = "${path.module}/.lambdas/payment_handler.py"
  content  = <<-PYTHON
import json, os, boto3, random
from datetime import datetime

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['ORDERS_TABLE'])

def handler(event, context):
    path_params = event.get('pathParameters') or {}
    order_id = path_params.get('orderId', '')

    success    = random.random() < 0.85
    new_status = 'PAYMENT_COMPLETED' if success else 'PAYMENT_FAILED'

    table.update_item(
        Key={'orderId': order_id},
        UpdateExpression='SET #s = :s, updatedAt = :t',
        ExpressionAttributeNames={'#s': 'status'},
        ExpressionAttributeValues={':s': new_status, ':t': datetime.utcnow().isoformat()}
    )

    try:
        from kafka import KafkaProducer
        import ssl
        ctx = ssl.create_default_context()
        producer = KafkaProducer(
            bootstrap_servers=os.environ['KAFKA_BOOTSTRAP'].split(','),
            security_protocol='SASL_SSL',
            sasl_mechanism='SCRAM-SHA-512',
            sasl_plain_username=os.environ['KAFKA_USERNAME'],
            sasl_plain_password=os.environ['KAFKA_PASSWORD'],
            ssl_context=ctx,
            value_serializer=lambda v: json.dumps(v).encode('utf-8'),
            request_timeout_ms=5000
        )
        event_name = 'PaymentCompleted' if success else 'PaymentFailed'
        producer.send('payments', {'event': event_name, 'orderId': order_id,
                                   'timestamp': datetime.utcnow().isoformat()})
        producer.flush(timeout=5)
        producer.close()
    except Exception as e:
        print(f"Kafka error (non-fatal): {e}")

    return {
        'statusCode': 200,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*'
        },
        'body': json.dumps({'orderId': order_id, 'status': new_status})
    }
  PYTHON
}

data "archive_file" "payment_handler" {
  type        = "zip"
  source_file = local_file.payment_handler_py.filename
  output_path = "${path.module}/.lambdas/payment_handler.zip"
  depends_on  = [local_file.payment_handler_py]
}

resource "aws_lambda_function" "payment" {
  filename         = data.archive_file.payment_handler.output_path
  source_code_hash = data.archive_file.payment_handler.output_base64sha256
  function_name    = "${local.project}-payment"
  role             = aws_iam_role.lambda.arn
  handler          = "payment_handler.handler"
  runtime          = "python3.11"
  timeout          = 30
  memory_size      = 256
  layers           = [aws_lambda_layer_version.kafka_python.arn]

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      ORDERS_TABLE    = aws_dynamodb_table.orders.name
      KAFKA_BOOTSTRAP = aws_msk_cluster.main.bootstrap_brokers_sasl_scram
      KAFKA_USERNAME  = local.kafka_username
      KAFKA_PASSWORD  = local.kafka_password
    }
  }
}

# =============================================================
# ORDERS LIST HANDLER — get order(s) from DynamoDB
# =============================================================

resource "local_file" "orders_list_handler_py" {
  filename = "${path.module}/.lambdas/orders_list_handler.py"
  content  = <<-PYTHON
import json, os, boto3

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['ORDERS_TABLE'])

def handler(event, context):
    path_params = event.get('pathParameters') or {}
    order_id = path_params.get('orderId')

    if order_id:
        item = table.get_item(Key={'orderId': order_id}).get('Item', {})
        body = json.dumps(item)
    else:
        items = table.scan(Limit=50).get('Items', [])
        body = json.dumps({'orders': items})

    return {
        'statusCode': 200,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*'
        },
        'body': body
    }
  PYTHON
}

data "archive_file" "orders_list_handler" {
  type        = "zip"
  source_file = local_file.orders_list_handler_py.filename
  output_path = "${path.module}/.lambdas/orders_list_handler.zip"
  depends_on  = [local_file.orders_list_handler_py]
}

resource "aws_lambda_function" "orders_list" {
  filename         = data.archive_file.orders_list_handler.output_path
  source_code_hash = data.archive_file.orders_list_handler.output_base64sha256
  function_name    = "${local.project}-orders-list"
  role             = aws_iam_role.lambda.arn
  handler          = "orders_list_handler.handler"
  runtime          = "python3.11"
  timeout          = 3
  memory_size      = 128

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      ORDERS_TABLE = aws_dynamodb_table.orders.name
    }
  }
}

# =============================================================
# CLOUDWATCH LOG GROUPS FOR LAMBDAS
# =============================================================

resource "aws_cloudwatch_log_group" "lambda_order" {
  name              = "/aws/lambda/${local.project}-order"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "lambda_payment" {
  name              = "/aws/lambda/${local.project}-payment"
  retention_in_days = 1
}

resource "aws_cloudwatch_log_group" "lambda_orders_list" {
  name              = "/aws/lambda/${local.project}-orders-list"
  retention_in_days = 1
}




##########

# =============================================================
# STEP 8 — API Gateway (HTTP API)
# Depends on: Lambda functions (step 7)
# Cost estimate:
#   API Gateway HTTP API : ~$1/million requests (~$0 at low volume)
#   Total step 8         : ~$0/month
# Deploy time  : ~1 min
# Deletion time: ~1 min
# =============================================================

resource "aws_apigatewayv2_api" "main" {
  name          = local.project
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
}

# =============================================================
# LAMBDA PERMISSIONS
# =============================================================

resource "aws_lambda_permission" "order" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.order.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*"
}

resource "aws_lambda_permission" "payment" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.payment.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*"
}

resource "aws_lambda_permission" "orders_list" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.orders_list.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*"
}

# =============================================================
# INTEGRATIONS
# =============================================================

resource "aws_apigatewayv2_integration" "order" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.order.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "payment" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.payment.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_integration" "orders_list" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.orders_list.invoke_arn
  payload_format_version = "2.0"
}

# =============================================================
# ROUTES
# =============================================================

resource "aws_apigatewayv2_route" "create_order" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /orders"
  target    = "integrations/${aws_apigatewayv2_integration.order.id}"
}

resource "aws_apigatewayv2_route" "get_orders" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /orders"
  target    = "integrations/${aws_apigatewayv2_integration.orders_list.id}"
}

resource "aws_apigatewayv2_route" "get_order" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /orders/{orderId}"
  target    = "integrations/${aws_apigatewayv2_integration.orders_list.id}"
}

resource "aws_apigatewayv2_route" "pay_order" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /orders/{orderId}/pay"
  target    = "integrations/${aws_apigatewayv2_integration.payment.id}"
}

# =============================================================
# OUTPUTS — step 8 checkpoint
# =============================================================

output "step8_api_url" {
  value       = aws_apigatewayv2_stage.default.invoke_url
  description = "API Gateway base URL"
}

# =============================================================
# AUTO-SAVE step8_api.txt
# =============================================================

resource "null_resource" "save_step8_txt" {
  triggers = {
    api_id = aws_apigatewayv2_api.main.id
  }

  provisioner "local-exec" {
    command = <<-CMD
      echo API_URL=${aws_apigatewayv2_stage.default.invoke_url} > step8_api.txt
      echo POST_ORDER=${aws_apigatewayv2_stage.default.invoke_url}/orders >> step8_api.txt
      echo GET_ORDERS=${aws_apigatewayv2_stage.default.invoke_url}/orders >> step8_api.txt
      echo PAY_ORDER=${aws_apigatewayv2_stage.default.invoke_url}/orders/{orderId}/pay >> step8_api.txt
    CMD
  }

  depends_on = [aws_apigatewayv2_stage.default]
}


###########

# =============================================================
# STEP 9 — ECS (RocketMQ + Kafka UI) + CloudFront + HTML
# Depends on: VPC, IAM, MSK, S3, API Gateway
# Cost estimate:
#   ECS Fargate RocketMQ nameserver (0.5vCPU/1GB)  : ~$15/month
#   ECS Fargate RocketMQ broker     (1vCPU/2GB)    : ~$30/month
#   ECS Fargate RocketMQ dashboard  (0.5vCPU/1GB)  : ~$15/month
#   ECS Fargate Kafka UI            (0.5vCPU/1GB)  : ~$15/month
#   CloudFront                                      : ~$0 (low volume)
#   Total step 9                                    : ~$75/month
# Deploy time  : ~5-7 min
# Deletion time: ~3-5 min
# =============================================================

# =============================================================
# ECS CLUSTER
# =============================================================

resource "aws_ecs_cluster" "main" {
  name = local.project

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# =============================================================
# SERVICE DISCOVERY (RocketMQ internal DNS)
# =============================================================

resource "aws_service_discovery_private_dns_namespace" "main" {
  name = "${local.project}.local"
  vpc  = aws_vpc.main.id
}

resource "aws_service_discovery_service" "rocketmq_nameserver" {
  name = "rocketmq-nameserver"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main.id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {}

}

# =============================================================
# CLOUDWATCH LOG GROUPS FOR ECS
# =============================================================

resource "aws_cloudwatch_log_group" "rocketmq" {
  name              = "/ecs/${local.project}/rocketmq"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "kafka_ui" {
  name              = "/ecs/${local.project}/kafka-ui"
  retention_in_days = 7
}

# =============================================================
# ROCKETMQ NAMESERVER
# =============================================================

resource "aws_ecs_task_definition" "rocketmq_nameserver" {
  family                   = "${local.project}-rocketmq-nameserver"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "rocketmq-nameserver"
    image     = "apache/rocketmq:5.1.4"
    essential = true
    command   = ["sh", "mqnamesrv"]
    portMappings = [
      { containerPort = 9876, hostPort = 9876, protocol = "tcp" }
    ]
    environment = [
      { name = "JAVA_OPT_EXT", value = "-Xms256m -Xmx512m" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.rocketmq.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "nameserver"
      }
    }
  }])
}

resource "aws_ecs_service" "rocketmq_nameserver" {
  name            = "${local.project}-rocketmq-nameserver"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.rocketmq_nameserver.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn = aws_service_discovery_service.rocketmq_nameserver.arn
  }
}

# =============================================================
# ROCKETMQ BROKER
# =============================================================

resource "aws_ecs_task_definition" "rocketmq_broker" {
  family                   = "${local.project}-rocketmq-broker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "rocketmq-broker"
    image     = "apache/rocketmq:5.1.4"
    essential = true
    command   = ["sh", "mqbroker", "-n", "rocketmq-nameserver.${local.project}.local:9876", "autoCreateTopicEnable=true"]
    portMappings = [
      { containerPort = 10909, hostPort = 10909, protocol = "tcp" },
      { containerPort = 10911, hostPort = 10911, protocol = "tcp" },
      { containerPort = 10912, hostPort = 10912, protocol = "tcp" }
    ]
    environment = [
      { name = "JAVA_OPT_EXT", value = "-Xms512m -Xmx1024m" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.rocketmq.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "broker"
      }
    }
  }])
}

resource "aws_ecs_service" "rocketmq_broker" {
  name            = "${local.project}-rocketmq-broker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.rocketmq_broker.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  depends_on = [aws_ecs_service.rocketmq_nameserver]
}

# =============================================================
# ROCKETMQ DASHBOARD
# =============================================================

resource "aws_ecs_task_definition" "rocketmq_dashboard" {
  family                   = "${local.project}-rocketmq-dashboard"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "rocketmq-dashboard"
    image     = "apacherocketmq/rocketmq-dashboard:latest"
    essential = true
    portMappings = [
      { containerPort = 8080, hostPort = 8080, protocol = "tcp" }
    ]
    environment = [
      { name = "JAVA_OPTS", value = "-Drocketmq.namesrv.addr=rocketmq-nameserver.${local.project}.local:9876 -Dserver.port=8080 -Xms256m -Xmx512m" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.rocketmq.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "dashboard"
      }
    }
  }])
}

resource "aws_ecs_service" "rocketmq_dashboard" {
  name            = "${local.project}-rocketmq-dashboard"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.rocketmq_dashboard.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  depends_on = [aws_ecs_service.rocketmq_nameserver]
}

# =============================================================
# KAFKA UI
# =============================================================

resource "aws_ecs_task_definition" "kafka_ui" {
  family                   = "${local.project}-kafka-ui"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "kafka-ui"
    image     = "provectuslabs/kafka-ui:latest"
    essential = true
    portMappings = [
      { containerPort = 8080, hostPort = 8080, protocol = "tcp" }
    ]
    environment = [
      { name = "KAFKA_CLUSTERS_0_NAME",                          value = local.project },
      { name = "KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS",              value = aws_msk_cluster.main.bootstrap_brokers_public_sasl_scram },
      { name = "KAFKA_CLUSTERS_0_PROPERTIES_SECURITY_PROTOCOL",  value = "SASL_SSL" },
      { name = "KAFKA_CLUSTERS_0_PROPERTIES_SASL_MECHANISM",     value = "SCRAM-SHA-512" },
      { name = "KAFKA_CLUSTERS_0_PROPERTIES_SASL_JAAS_CONFIG",   value = "org.apache.kafka.common.security.scram.ScramLoginModule required username=\"${local.kafka_username}\" password=\"${local.kafka_password}\";" },
      { name = "AUTH_TYPE",                                       value = "DISABLED" },
      { name = "SERVER_PORT",                                     value = "8080" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.kafka_ui.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "kafka-ui"
      }
    }
  }])
}

resource "aws_ecs_service" "kafka_ui" {
  name            = "${local.project}-kafka-ui"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.kafka_ui.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  depends_on = [aws_msk_scram_secret_association.main]
}

# =============================================================
# CLOUDFRONT + S3 FRONTEND
# =============================================================

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.project}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.main.arn
        }
      }
    }]
  })
}

# =============================================================
# HTML FRONTEND — uploaded to S3
# =============================================================

resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  content_type = "text/html"
  content      = <<-HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>terraformautokafka Shop</title>
      <style>
        body { font-family: Arial, sans-serif; max-width: 800px; margin: 40px auto; padding: 0 20px; }
        h1   { color: #232f3e; }
        .product { border: 1px solid #ddd; padding: 15px; margin: 10px 0; border-radius: 8px; display: flex; justify-content: space-between; align-items: center; }
        button { background: #ff9900; color: white; border: none; padding: 10px 20px; cursor: pointer; border-radius: 4px; font-size: 14px; }
        button:hover { background: #e68a00; }
        button.pay { background: #28a745; }
        button.pay:hover { background: #218838; }
        #status { margin: 20px 0; padding: 12px; background: #f0f0f0; border-radius: 4px; }
        .order-item { background: #fff3e0; padding: 10px; margin: 5px 0; border-radius: 4px; font-size: 13px; }
      </style>
    </head>
    <body>
      <h1>terraformautokafka Shop</h1>
      <p>Event-driven demo: Kafka + RabbitMQ + RocketMQ</p>

      <h2>Products</h2>
      <div class="product"><span><b>Kafka Book</b> — $29.99</span>       <button onclick="placeOrder('Kafka Book', 29.99)">Buy</button></div>
      <div class="product"><span><b>RabbitMQ Course</b> — $49.99</span>  <button onclick="placeOrder('RabbitMQ Course', 49.99)">Buy</button></div>
      <div class="product"><span><b>RocketMQ T-Shirt</b> — $19.99</span> <button onclick="placeOrder('RocketMQ T-Shirt', 19.99)">Buy</button></div>

      <div id="status">Ready.</div>

      <h2>Orders <button onclick="loadOrders()" style="font-size:12px;padding:5px 10px;">Refresh</button></h2>
      <div id="orders"></div>

      <script>
        const API = '${aws_apigatewayv2_stage.default.invoke_url}';

        async function placeOrder(product, price) {
          document.getElementById('status').textContent = 'Placing order...';
          try {
            const r = await fetch(API + '/orders', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ product, price })
            });
            const o = await r.json();
            document.getElementById('status').textContent = 'Order placed! ID: ' + o.orderId;
            setTimeout(loadOrders, 500);
          } catch(e) {
            document.getElementById('status').textContent = 'Error: ' + e.message;
          }
        }

        async function payOrder(orderId) {
          const r = await fetch(API + '/orders/' + orderId + '/pay', { method: 'POST' });
          const o = await r.json();
          document.getElementById('status').textContent = 'Payment: ' + o.status;
          setTimeout(loadOrders, 500);
        }

        async function loadOrders() {
          try {
            const r = await fetch(API + '/orders');
            const data = await r.json();
            const orders = data.orders || [];
            document.getElementById('orders').innerHTML = orders.length
              ? orders.map(o =>
                  '<div class="order-item"><b>' + o.product + '</b> $' + o.price +
                  ' | <b>' + o.status + '</b> | ' + o.orderId.substring(0,8) + '...' +
                  (o.status === 'PENDING' ? ' <button class="pay" onclick="payOrder(\'' + o.orderId + '\')">Pay</button>' : '') +
                  '</div>').join('')
              : '<p>No orders yet.</p>';
          } catch(e) {
            document.getElementById('orders').innerHTML = '<p>Error loading orders.</p>';
          }
        }

        loadOrders();
      </script>
    </body>
    </html>
  HTML

  depends_on = [aws_apigatewayv2_stage.default]
}

# =============================================================
# OUTPUTS — step 9 checkpoints
# =============================================================

output "step9_cloudfront_url" {
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
  description = "Public storefront URL"
}

output "step9_kafka_ui_note" {
  value = "Kafka UI: ECS console > cluster ${local.project} > service kafka-ui > task > public IP > http://IP:8080"
}

output "step9_rocketmq_dashboard_note" {
  value = "RocketMQ Dashboard: ECS console > cluster ${local.project} > service rocketmq-dashboard > task > public IP > http://IP:8080"
}

# =============================================================
# AUTO-SAVE step9_endpoints.txt
# =============================================================

resource "null_resource" "save_step9_txt" {
  triggers = {
    cf_domain = aws_cloudfront_distribution.main.domain_name
  }

  provisioner "local-exec" {
    command = <<-CMD
      echo CLOUDFRONT_URL=https://${aws_cloudfront_distribution.main.domain_name} > step9_endpoints.txt
      echo KAFKA_UI_NOTE=Check ECS console - cluster ${local.project} - service kafka-ui - task public IP - port 8080 >> step9_endpoints.txt
      echo ROCKETMQ_DASHBOARD_NOTE=Check ECS console - cluster ${local.project} - service rocketmq-dashboard - task public IP - port 8080 >> step9_endpoints.txt
    CMD
  }

  depends_on = [
    aws_cloudfront_distribution.main,
    aws_ecs_service.kafka_ui,
    aws_ecs_service.rocketmq_dashboard
  ]
}


##########


# =============================================================
# STEP 10 — Final outputs + uri.txt
# Depends on: all previous steps
# Cost estimate:
#   local_file : free
#   Total step 10 : $0/month
# Deploy time  : ~1 min
# Deletion time: ~1 min
# =============================================================

# =============================================================
# OUTPUTS — full summary
# =============================================================

output "CLOUDFRONT_URL" {
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
  description = "Public storefront"
}

output "API_URL" {
  value       = aws_apigatewayv2_stage.default.invoke_url
  description = "REST API base URL"
}

output "KAFKA_PUBLIC_BOOTSTRAP_SERVERS" {
  value       = aws_msk_cluster.main.bootstrap_brokers_public_sasl_scram
  description = "MSK public SASL/SCRAM bootstrap"
}

output "KAFKA_USERNAME" {
  value     = local.kafka_username

}

output "KAFKA_PASSWORD" {
  value     = local.kafka_password

}

output "RABBITMQ_MANAGEMENT_URL" {
  value       = aws_mq_broker.rabbitmq.instances[0].console_url
  description = "RabbitMQ web console"
}

output "RABBITMQ_AMQP_URL" {
  value       = aws_mq_broker.rabbitmq.instances[0].endpoints[0]
  description = "RabbitMQ AMQPS endpoint"
}

output "RABBITMQ_USERNAME" {
  value     = local.rabbitmq_username

}

output "RABBITMQ_PASSWORD" {
  value     = local.rabbitmq_password

}

output "ROCKETMQ_NAMESERVER" {
  value       = "rocketmq-nameserver.${local.project}.local:9876"
  description = "RocketMQ nameserver (internal VPC DNS)"
}

output "ROCKETMQ_USERNAME" {
  value     = local.rocketmq_username

}

output "ROCKETMQ_PASSWORD" {
  value     = local.rocketmq_password

}

output "KAFKA_UI_NOTE" {
  value = "ECS console > cluster ${local.project} > service kafka-ui > task > public IP > http://IP:8080"
}

output "ROCKETMQ_DASHBOARD_NOTE" {
  value = "ECS console > cluster ${local.project} > service rocketmq-dashboard > task > public IP > http://IP:8080"
}

# =============================================================
# AUTO-GENERATE uri.txt (final, all endpoints + credentials)
# =============================================================

resource "local_file" "uri_txt" {
  filename        = "${path.module}/uri.txt"
  file_permission = "0644"
  content         = <<-EOT
PROJECT=terraformautokafka

CLOUDFRONT_URL=https://${aws_cloudfront_distribution.main.domain_name}
API_URL=${aws_apigatewayv2_stage.default.invoke_url}

KAFKA_PUBLIC_BOOTSTRAP_SERVERS=${aws_msk_cluster.main.bootstrap_brokers_public_sasl_scram}
KAFKA_INTERNAL_BOOTSTRAP_SERVERS=${aws_msk_cluster.main.bootstrap_brokers_sasl_scram}
KAFKA_USERNAME=${local.kafka_username}
KAFKA_PASSWORD=${local.kafka_password}

RABBITMQ_MANAGEMENT_URL=${aws_mq_broker.rabbitmq.instances[0].console_url}
RABBITMQ_AMQP_URL=${aws_mq_broker.rabbitmq.instances[0].endpoints[0]}
RABBITMQ_USERNAME=${local.rabbitmq_username}
RABBITMQ_PASSWORD=${local.rabbitmq_password}

ROCKETMQ_NAMESERVER=rocketmq-nameserver.${local.project}.local:9876
ROCKETMQ_USERNAME=${local.rocketmq_username}
ROCKETMQ_PASSWORD=${local.rocketmq_password}

KAFKA_UI=ECS console > cluster ${local.project} > service kafka-ui > task > public IP > http://IP:8080
ROCKETMQ_DASHBOARD=ECS console > cluster ${local.project} > service rocketmq-dashboard > task > public IP > http://IP:8080
EOT

  depends_on = [
    aws_cloudfront_distribution.main,
    aws_msk_cluster.main,
    aws_msk_scram_secret_association.main,
    aws_mq_broker.rabbitmq,
    aws_apigatewayv2_stage.default,
    aws_ecs_service.kafka_ui,
    aws_ecs_service.rocketmq_dashboard,
  ]
}


##########



