

############################################################
# Private S3, 3 tiers, 11 min s3 key rotation, audit, bastion,
# Python Lambda Functions EventBridge 
# SNS Simple Notification Service CloudWatch
# Cognito + API Gateway (presigned URLs). Region us-east-1.
# Replace every value containing 11111 before apply.
############################################################

terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.82" }
    random  = { source = "hashicorp/random" }
    local   = { source = "hashicorp/local" }
    archive = { source = "hashicorp/archive" }
    tls     = { source = "hashicorp/tls" }
    time    = { source = "hashicorp/time" }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      deployedwith = "terraformautov1"
    }
  }
}

############################ Variables ############################

variable "bucket_name" {
  default = "terraform-s3-bucket-202610232101"
}

# REPLACE: email for SNS notifications ("" = no email)
variable "notification_email" {
  default = "11111_YOUR_EMAIL@11111.COM"
}

# REPLACE: globally unique Cognito domain prefix (no "aws", "amazon", "cognito" in it)
variable "cognito_domain_prefix" {
  default = "11111-s3api-auth"
}

# REPLACE (optional): bastion SSH source, e.g. "11111.11111.11111.11111/32"
variable "bastion_ssh_cidr" {
  default = "0.0.0.0/0"
}

variable "bastion_username" {
  default = "bastionuser"
}

variable "ec2_username" {
  default = "s3user"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "az" {
  default = "us-east-1a"
}

# true = email on every IAM key create/delete (about 6 emails per 11 min rotation)
variable "notify_key_changes" {
  default = false
}

data "aws_caller_identity" "me" {}

locals {
  # change a tier here to move a user to another group
  user_tier = {
    "s3-readonly-user"  = "readonly"
    "s3-readwrite-user" = "readwrite"
    "s3-restore-user"   = "restore"
  }

  # web ui port per user, 0 = no web ui
  ports = {
    "s3-readonly-user"  = 8081
    "s3-readwrite-user" = 8082
    "s3-restore-user"   = 0
  }

  tiers = {
    readonly = {
      bucket_actions = ["s3:ListBucket", "s3:GetBucketLocation"]
      object_actions = ["s3:GetObject","s3:GetObjectVersion"]
      kms_actions    = ["kms:Decrypt"]
    }
    readwrite = {
      bucket_actions = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
      object_actions = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
      kms_actions    = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    }
    restore = {
      bucket_actions = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads", "s3:ListBucketVersions"]
      object_actions = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:RestoreObject"]
      kms_actions    = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    }
  }

  # api route => lambda tier + accepted jwt scopes (higher tiers also accepted)
  api_routes = {
    "GET /list"              = { tier = "readonly", scopes = ["read", "write", "restore"] }
    "GET /download"          = { tier = "readonly", scopes = ["read", "write", "restore"] }
    "POST /upload"           = { tier = "readwrite", scopes = ["write", "restore"] }
    "POST /multipart/start"  = { tier = "readwrite", scopes = ["write", "restore"] }
    "POST /multipart/parts"  = { tier = "readwrite", scopes = ["write", "restore"] }
    "POST /multipart/complete" = { tier = "readwrite", scopes = ["write", "restore"] }
    "POST /multipart/abort"  = { tier = "readwrite", scopes = ["write", "restore"] }
    "DELETE /object"         = { tier = "readwrite", scopes = ["write", "restore"] }
    "GET /versions"          = { tier = "restore", scopes = ["restore"] }
    "GET /download-version"  = { tier = "restore", scopes = ["restore"] }
    "POST /restore"          = { tier = "restore", scopes = ["restore"] }
    "POST /restore-version"  = { tier = "restore", scopes = ["restore"] }
  }

  client_tiers = ["read", "write", "restore"]
}

############################ KMS ############################

resource "aws_kms_key" "main" {
  description             = "s3 key"
  enable_key_rotation     = true
  rotation_period_in_days = 90
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.bucket_name}"
  target_key_id = aws_kms_key.main.key_id
}

############################ S3 main bucket ############################

resource "aws_s3_bucket" "main" {
  bucket        = var.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket                  = aws_s3_bucket.main.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "bucket_tls" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.main.arn, "${aws_s3_bucket.main.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "main" {
  bucket     = aws_s3_bucket.main.id
  policy     = data.aws_iam_policy_document.bucket_tls.json
  depends_on = [aws_s3_bucket_public_access_block.main]
}

############################ S3 access logs bucket ############################

resource "aws_s3_bucket" "logs" {
  bucket        = "${var.bucket_name}-logs"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "logs" {
  statement {
    sid       = "S3LogDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.main.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.me.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket     = aws_s3_bucket.logs.id
  policy     = data.aws_iam_policy_document.logs.json
  depends_on = [aws_s3_bucket_public_access_block.logs]
}

resource "aws_s3_bucket_logging" "main" {
  bucket        = aws_s3_bucket.main.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "access/"
  depends_on    = [aws_s3_bucket_policy.logs]
}

############################ IAM groups / users (no static keys) ############################

resource "aws_iam_group" "tier" {
  for_each = local.tiers
  name     = "s3-${each.key}"
}

data "aws_iam_policy_document" "tier" {
  for_each = local.tiers

  statement {
    sid       = "Bucket"
    actions   = each.value.bucket_actions
    resources = [aws_s3_bucket.main.arn]
  }
  statement {
    sid       = "Objects"
    actions   = each.value.object_actions
    resources = ["${aws_s3_bucket.main.arn}/*"]
  }
  statement {
    sid       = "Kms"
    actions   = each.value.kms_actions
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_group_policy" "tier" {
  for_each = local.tiers
  name     = "s3-${each.key}"
  group    = aws_iam_group.tier[each.key].name
  policy   = data.aws_iam_policy_document.tier[each.key].json
}

# force_destroy: the rotation lambda creates keys that terraform does not track
resource "aws_iam_user" "user" {
  for_each      = local.user_tier
  name          = each.key
  force_destroy = true
}

resource "aws_iam_user_group_membership" "user" {
  for_each = local.user_tier
  user     = aws_iam_user.user[each.key].name
  groups   = [aws_iam_group.tier[each.value].name]
}

############################ Secrets + rotation lambda (11 min) ############################

resource "aws_secretsmanager_secret" "creds" {
  for_each                = local.user_tier
  name                    = "s3-creds-${each.key}"
  recovery_window_in_days = 0
}

data "archive_file" "rotate" {
  type        = "zip"
  output_path = "${path.cwd}/rotate.zip"
  source {
    filename = "index.py"
    content  = <<-PY
      import boto3, json, os
      iam = boto3.client("iam")
      sm = boto3.client("secretsmanager")

      def handler(event, context):
          users = json.loads(os.environ["USERS"])
          for user, secret in users.items():
              keys = sorted(iam.list_access_keys(UserName=user)["AccessKeyMetadata"], key=lambda k: k["CreateDate"])
              # max 2 keys per user: drop the oldest, keep the previous one as grace
              while len(keys) >= 2:
                  iam.delete_access_key(UserName=user, AccessKeyId=keys.pop(0)["AccessKeyId"])
              new = iam.create_access_key(UserName=user)["AccessKey"]
              try:
                  sm.put_secret_value(
                      SecretId=secret,
                      SecretString=json.dumps({"access_key_id": new["AccessKeyId"], "secret_access_key": new["SecretAccessKey"]}),
                  )
              except Exception:
                  iam.delete_access_key(UserName=user, AccessKeyId=new["AccessKeyId"])
                  raise
    PY
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_group" "rotate" {
  name = "/aws/lambda/s3-key-rotation"
}

data "aws_iam_policy_document" "rotate" {
  statement {
    actions   = ["iam:ListAccessKeys", "iam:CreateAccessKey", "iam:DeleteAccessKey"]
    resources = [for u in aws_iam_user.user : u.arn]
  }
  statement {
    actions   = ["secretsmanager:PutSecretValue"]
    resources = [for s in aws_secretsmanager_secret.creds : s.arn]
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.rotate.arn}:*"]
  }
}

resource "aws_iam_role" "rotate" {
  name               = "s3-key-rotation"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "rotate" {
  name   = "rotate"
  role   = aws_iam_role.rotate.id
  policy = data.aws_iam_policy_document.rotate.json
}

resource "aws_lambda_function" "rotate" {
  function_name    = "s3-key-rotation"
  role             = aws_iam_role.rotate.arn
  runtime          = "python3.12"
  handler          = "index.handler"
  timeout          = 30
  filename         = data.archive_file.rotate.output_path
  source_code_hash = data.archive_file.rotate.output_base64sha256

  environment {
    variables = {
      USERS = jsonencode({ for u in keys(local.user_tier) : u => aws_secretsmanager_secret.creds[u].name })
    }
  }

  depends_on = [aws_cloudwatch_log_group.rotate, aws_iam_role_policy.rotate]
}

# wait for IAM propagation before the first run
resource "time_sleep" "iam" {
  create_duration = "20s"
  depends_on      = [aws_iam_role_policy.rotate]
}

# creates the first keys before the ec2 boots
resource "aws_lambda_invocation" "first" {
  function_name = aws_lambda_function.rotate.function_name
  input         = jsonencode({})
  depends_on    = [aws_iam_user.user, aws_secretsmanager_secret.creds, time_sleep.iam]
}

# depends_on users so the schedule is destroyed before the users
resource "aws_cloudwatch_event_rule" "rotate" {
  name                = "s3-key-rotation"
  schedule_expression = "rate(11 minutes)"
  depends_on          = [aws_iam_user.user, aws_lambda_invocation.first]
}

resource "aws_cloudwatch_event_target" "rotate" {
  rule = aws_cloudwatch_event_rule.rotate.name
  arn  = aws_lambda_function.rotate.arn
}

resource "aws_lambda_permission" "rotate" {
  statement_id  = "AllowEvents"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotate.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rotate.arn
}

############################ SNS / notifications ############################

resource "aws_sns_topic" "main" {
  name = "s3-notifications"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.main.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

data "aws_iam_policy_document" "sns" {
  statement {
    sid       = "AllowPublish"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.main.arn]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com", "events.amazonaws.com", "cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "main" {
  arn    = aws_sns_topic.main.arn
  policy = data.aws_iam_policy_document.sns.json
}

resource "aws_s3_bucket_notification" "main" {
  bucket = aws_s3_bucket.main.id
  topic {
    topic_arn = aws_sns_topic.main.arn
    events    = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*", "s3:ObjectRestore:*"]
  }
  depends_on = [aws_sns_topic_policy.main]
}

############################ CloudTrail / CloudWatch audit ############################

resource "aws_s3_bucket" "trail" {
  bucket        = "${var.bucket_name}-trail"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid       = "AclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
  statement {
    sid       = "Write"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.me.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket     = aws_s3_bucket.trail.id
  policy     = data.aws_iam_policy_document.trail_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.trail]
}

# no retention set = logs never expire
resource "aws_cloudwatch_log_group" "trail" {
  name = "/aws/cloudtrail/${var.bucket_name}"
}

data "aws_iam_policy_document" "trail_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "trail_logs" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.trail.arn}:*"]
  }
}

resource "aws_iam_role" "trail" {
  name               = "cloudtrail-to-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.trail_assume.json
}

resource "aws_iam_role_policy" "trail" {
  name   = "logs"
  role   = aws_iam_role.trail.id
  policy = data.aws_iam_policy_document.trail_logs.json
}

resource "aws_cloudtrail" "main" {
  name                          = "s3-audit"
  s3_bucket_name                = aws_s3_bucket.trail.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.trail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.trail.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true
    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.main.arn}/"]
    }
  }

  depends_on = [aws_s3_bucket_policy.trail, aws_iam_role_policy.trail]
}

resource "aws_cloudwatch_log_metric_filter" "denied" {
  name           = "s3-access-denied"
  log_group_name = aws_cloudwatch_log_group.trail.name
  pattern        = "{ $.errorCode = \"AccessDenied\" }"
  metric_transformation {
    name      = "S3AccessDenied"
    namespace = "S3Audit"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "denied" {
  alarm_name          = "s3-access-denied"
  namespace           = "S3Audit"
  metric_name         = "S3AccessDenied"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.main.arn]
}

# key created / revoked history to SNS (CloudTrail always keeps the history)
resource "aws_cloudwatch_event_rule" "keys" {
  count = var.notify_key_changes ? 1 : 0
  name  = "iam-access-key-changes"
  event_pattern = jsonencode({
    source        = ["aws.iam"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["iam.amazonaws.com"]
      eventName   = ["CreateAccessKey", "UpdateAccessKey", "DeleteAccessKey"]
    }
  })
}

resource "aws_cloudwatch_event_target" "keys" {
  count = var.notify_key_changes ? 1 : 0
  rule  = aws_cloudwatch_event_rule.keys[0].name
  arn   = aws_sns_topic.main.arn
}

############################ Network (private) ############################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "private-vpc" }
}

# public subnet: NAT gateway + bastion
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone       = var.az
  map_public_ip_on_launch = false
  tags                    = { Name = "public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 1)
  availability_zone = var.az
  tags              = { Name = "private" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

############################ Bastion ############################

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "tls_private_key" "bastion" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "bastion" {
  key_name   = "${var.bucket_name}-bastion"
  public_key = tls_private_key.bastion.public_key_openssh
}

resource "random_password" "bastion" {
  length  = 20
  special = false
}

resource "aws_security_group" "bastion" {
  name   = "bastion"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.bastion_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = aws_key_pair.bastion.key_name
  associate_public_ip_address = false
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  user_data = <<-EOT
    #!/bin/bash
    useradd -m ${var.bastion_username}
    echo "${var.bastion_username}:${random_password.bastion.result}" | chpasswd
    printf 'PasswordAuthentication yes\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/00-password.conf
    systemctl restart sshd
  EOT

  tags       = { Name = "bastion" }
  depends_on = [aws_internet_gateway.main]
}

resource "aws_eip" "bastion" {
  domain     = "vpc"
  instance   = aws_instance.bastion.id
  depends_on = [aws_internet_gateway.main]
}

############################ Private EC2 (mc + s3webui) ############################

resource "random_password" "ec2" {
  length  = 20
  special = false
}

resource "aws_security_group" "ec2" {
  name   = "ec2-private"
  vpc_id = aws_vpc.main.id

  # ssh only from the bastion
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # web ui ports from inside the vpc (later: vpn)
  ingress {
    from_port   = 8081
    to_port     = 8082
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ec2_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [for s in aws_secretsmanager_secret.creds : s.arn]
  }
}

resource "aws_iam_role" "ec2" {
  name               = "ec2-read-s3-creds"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy" "ec2" {
  name   = "secrets"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2_secrets.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "ec2-read-s3-creds"
  role = aws_iam_role.ec2.name
}

resource "aws_instance" "mc" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = false
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  user_data = <<-EOT
    #!/bin/bash
    useradd -m -G wheel ${var.ec2_username}
    echo "${var.ec2_username}:${random_password.ec2.result}" | chpasswd
    echo "PasswordAuthentication yes" > /etc/ssh/sshd_config.d/00-password.conf
    systemctl restart sshd

    curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
    chmod +x /usr/local/bin/mc
    dnf install -y docker jq iptables-nft
    systemctl enable --now docker
    mkdir -p /var/lib/s3-sync

    # block the metadata service for every non-root user (persistent)
    cat > /etc/systemd/system/block-imds.service <<'UNIT2'
    [Unit]
    Description=block metadata service for non-root users
    After=network.target
    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/usr/sbin/iptables -A OUTPUT -d 169.254.169.254 -m owner ! --uid-owner 0 -j REJECT
    [Install]
    WantedBy=multi-user.target
    UNIT2
    systemctl daemon-reload
    systemctl enable --now block-imds

    cat > /usr/local/bin/s3-sync.sh <<'SCRIPT'
    #!/bin/bash
    PAIRS="${join(" ", [for u, p in local.ports : "${u}:${p}"])}"
    for pair in $PAIRS; do
      u=$(echo $pair | cut -d: -f1)
      p=$(echo $pair | cut -d: -f2)
      s=$(aws secretsmanager get-secret-value --region us-east-1 --secret-id s3-creds-$u --query SecretString --output text) || continue
      ak=$(echo "$s" | jq -r .access_key_id)
      sk=$(echo "$s" | jq -r .secret_access_key)
      # skip if the key did not change
      if [ -f /var/lib/s3-sync/$u ] && [ "$(cat /var/lib/s3-sync/$u)" = "$ak" ]; then continue; fi
      runuser -l ${var.ec2_username} -c "/usr/local/bin/mc alias set $u https://s3.amazonaws.com $ak $sk --api S3v4" > /dev/null
      if [ "$p" != "0" ]; then
        docker rm -f s3webui-$u 2>/dev/null
        docker run -d --name s3webui-$u --restart unless-stopped -p $p:8080 \
          -e S3_ACCESS_KEY=$ak -e S3_SECRET_KEY=$sk \
          -e S3_ENDPOINT_URL=https://s3.amazonaws.com -e S3_REGION=us-east-1 \
          ghcr.io/wenisch-tech/s3webui:1.3.1
      fi
      echo "$ak" > /var/lib/s3-sync/$u
    done
    SCRIPT
    chmod +x /usr/local/bin/s3-sync.sh

    # checks every 7 min 7 sec (427 s)
    cat > /etc/systemd/system/s3-sync.service <<'UNIT'
    [Unit]
    Description=sync rotated s3 creds
    After=docker.service network-online.target
    [Service]
    ExecStart=/bin/bash -c 'while true; do /usr/local/bin/s3-sync.sh; sleep 427; done'
    Restart=always
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now s3-sync
  EOT

  tags = { Name = "mc-client" }
  depends_on = [
    aws_route_table_association.private,
    aws_nat_gateway.main,
    aws_vpc_endpoint.s3,
    aws_lambda_invocation.first,
  ]
}

############################ Cognito (jwt issuer) ############################

resource "aws_cognito_user_pool" "api" {
  name = "${var.bucket_name}-api"
}

resource "aws_cognito_resource_server" "api" {
  identifier   = "s3api"
  name         = "s3api"
  user_pool_id = aws_cognito_user_pool.api.id

  dynamic "scope" {
    for_each = local.client_tiers
    content {
      scope_name        = scope.value
      scope_description = "s3 ${scope.value}"
    }
  }
}

resource "aws_cognito_user_pool_domain" "api" {
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.api.id
}

# one app client per tier, client credentials flow
resource "aws_cognito_user_pool_client" "api" {
  for_each = toset(local.client_tiers)

  name                                 = "s3api-${each.key}"
  user_pool_id                         = aws_cognito_user_pool.api.id
  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes                 = ["s3api/${each.key}"]
  supported_identity_providers         = ["COGNITO"]

  depends_on = [aws_cognito_resource_server.api]
}

############################ API lambdas (presigned urls) ############################

data "archive_file" "api" {
  type        = "zip"
  output_path = "${path.cwd}/api.zip"
  source {
    filename = "index.py"
    content  = <<-PY
      import json, os, boto3
      from botocore.config import Config
      from botocore.exceptions import ClientError

      BUCKET = os.environ["BUCKET"]
      EXPIRES = int(os.environ.get("EXPIRES", "900"))
      s3 = boto3.client("s3", region_name=os.environ.get("AWS_REGION", "us-east-1"), config=Config(signature_version="s3v4"))

      def resp(code, body):
          return {"statusCode": code, "headers": {"content-type": "application/json"}, "body": json.dumps(body, default=str)}

      def body_of(event):
          try:
              return json.loads(event.get("body") or "{}")
          except Exception:
              return {}

      def qs(event):
          return event.get("queryStringParameters") or {}

      def need(d, *names):
          missing = [n for n in names if not d.get(n)]
          if missing:
              raise ValueError("missing: " + ",".join(missing))

      def presign(op, **params):
          return s3.generate_presigned_url(op, Params=dict(Bucket=BUCKET, **params), ExpiresIn=EXPIRES)

      # ---------- read ----------
      def list_objects(event):
          q = qs(event)
          args = {"Bucket": BUCKET, "MaxKeys": int(q.get("max", "100"))}
          if q.get("prefix"):
              args["Prefix"] = q["prefix"]
          if q.get("token"):
              args["ContinuationToken"] = q["token"]
          r = s3.list_objects_v2(**args)
          items = [{"key": o["Key"], "size": o["Size"], "modified": o["LastModified"], "storage_class": o.get("StorageClass")} for o in r.get("Contents", [])]
          return resp(200, {"objects": items, "next_token": r.get("NextContinuationToken")})

      def download(event):
          q = qs(event)
          need(q, "key")
          return resp(200, {"url": presign("get_object", Key=q["key"]), "expires_in": EXPIRES})

      # ---------- write ----------
      def upload(event):
          b = body_of(event)
          need(b, "key")
          return resp(200, {"url": presign("put_object", Key=b["key"]), "method": "PUT", "expires_in": EXPIRES})

      def mp_start(event):
          b = body_of(event)
          need(b, "key")
          r = s3.create_multipart_upload(Bucket=BUCKET, Key=b["key"])
          return resp(200, {"key": b["key"], "upload_id": r["UploadId"]})

      def mp_parts(event):
          b = body_of(event)
          need(b, "key", "upload_id", "parts")
          parts = b["parts"]
          if not isinstance(parts, list) or len(parts) > 1000:
              raise ValueError("parts must be a list of up to 1000 part numbers")
          urls = []
          for n in parts:
              n = int(n)
              if n < 1 or n > 10000:
                  raise ValueError("part number must be 1-10000")
              urls.append({"part": n, "url": presign("upload_part", Key=b["key"], UploadId=b["upload_id"], PartNumber=n)})
          return resp(200, {"urls": urls, "expires_in": EXPIRES})

      def mp_complete(event):
          b = body_of(event)
          need(b, "key", "upload_id", "parts")
          parts = sorted([{"PartNumber": int(p["part"]), "ETag": p["etag"]} for p in b["parts"]], key=lambda p: p["PartNumber"])
          r = s3.complete_multipart_upload(Bucket=BUCKET, Key=b["key"], UploadId=b["upload_id"], MultipartUpload={"Parts": parts})
          return resp(200, {"key": b["key"], "version_id": r.get("VersionId"), "etag": r.get("ETag")})

      def mp_abort(event):
          b = body_of(event)
          need(b, "key", "upload_id")
          s3.abort_multipart_upload(Bucket=BUCKET, Key=b["key"], UploadId=b["upload_id"])
          return resp(200, {"aborted": True})

      def delete_object(event):
          q = qs(event)
          need(q, "key")
          r = s3.delete_object(Bucket=BUCKET, Key=q["key"])
          return resp(200, {"deleted": q["key"], "delete_marker_version": r.get("VersionId")})

      # ---------- restore ----------
      def versions(event):
          q = qs(event)
          need(q, "key")
          r = s3.list_object_versions(Bucket=BUCKET, Prefix=q["key"])
          out = []
          for v in r.get("Versions", []):
              if v["Key"] == q["key"]:
                  out.append({"type": "version", "version_id": v["VersionId"], "latest": v["IsLatest"], "size": v["Size"], "modified": v["LastModified"]})
          for m in r.get("DeleteMarkers", []):
              if m["Key"] == q["key"]:
                  out.append({"type": "delete_marker", "version_id": m["VersionId"], "latest": m["IsLatest"], "modified": m["LastModified"]})
          return resp(200, {"versions": out})

      def download_version(event):
          q = qs(event)
          need(q, "key", "version_id")
          return resp(200, {"url": presign("get_object", Key=q["key"], VersionId=q["version_id"]), "expires_in": EXPIRES})

      def restore(event):
          b = body_of(event)
          need(b, "key")
          args = {"Bucket": BUCKET, "Key": b["key"], "RestoreRequest": {"Days": int(b.get("days", 7)), "GlacierJobParameters": {"Tier": b.get("tier", "Standard")}}}
          if b.get("version_id"):
              args["VersionId"] = b["version_id"]
          s3.restore_object(**args)
          return resp(202, {"restore_requested": b["key"]})

      def restore_version(event):
          b = body_of(event)
          need(b, "key", "version_id")
          r = s3.copy_object(Bucket=BUCKET, Key=b["key"], CopySource={"Bucket": BUCKET, "Key": b["key"], "VersionId": b["version_id"]})
          return resp(200, {"key": b["key"], "new_version_id": r.get("VersionId")})

      ROUTES = {
          "GET /list": list_objects,
          "GET /download": download,
          "POST /upload": upload,
          "POST /multipart/start": mp_start,
          "POST /multipart/parts": mp_parts,
          "POST /multipart/complete": mp_complete,
          "POST /multipart/abort": mp_abort,
          "DELETE /object": delete_object,
          "GET /versions": versions,
          "GET /download-version": download_version,
          "POST /restore": restore,
          "POST /restore-version": restore_version,
      }

      def handler(event, context):
          fn = ROUTES.get(event.get("routeKey"))
          if not fn:
              return resp(404, {"error": "unknown route"})
          try:
              return fn(event)
          except ValueError as e:
              return resp(400, {"error": str(e)})
          except ClientError as e:
              return resp(400, {"error": e.response["Error"]["Code"]})
          except Exception as e:
              print("error", repr(e))
              return resp(500, {"error": "internal error"})
    PY
  }
}

resource "aws_cloudwatch_log_group" "api" {
  for_each = local.tiers
  name     = "/aws/lambda/s3api-${each.key}"
}

# each lambda role = the same permissions as the matching tier
data "aws_iam_policy_document" "api" {
  for_each                = local.tiers
  source_policy_documents = [data.aws_iam_policy_document.tier[each.key].json]

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.api[each.key].arn}:*"]
  }
}

resource "aws_iam_role" "api" {
  for_each           = local.tiers
  name               = "s3api-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "api" {
  for_each = local.tiers
  name     = "s3api-${each.key}"
  role     = aws_iam_role.api[each.key].id
  policy   = data.aws_iam_policy_document.api[each.key].json
}

resource "aws_lambda_function" "api" {
  for_each         = local.tiers
  function_name    = "s3api-${each.key}"
  role             = aws_iam_role.api[each.key].arn
  runtime          = "python3.12"
  handler          = "index.handler"
  timeout          = 15
  memory_size      = 256
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256

  environment {
    variables = {
      BUCKET  = aws_s3_bucket.main.id
      EXPIRES = "900"
    }
  }

  depends_on = [aws_cloudwatch_log_group.api, aws_iam_role_policy.api]
}

############################ API Gateway (HTTP API + JWT) ############################

resource "aws_apigatewayv2_api" "api" {
  name          = "s3-presign-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id           = aws_apigatewayv2_api.api.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito-jwt"

  jwt_configuration {
    issuer   = "https://cognito-idp.us-east-1.amazonaws.com/${aws_cognito_user_pool.api.id}"
    audience = [for c in aws_cognito_user_pool_client.api : c.id]
  }
}

resource "aws_apigatewayv2_integration" "api" {
  for_each               = local.tiers
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api[each.key].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "api" {
  for_each             = local.api_routes
  api_id               = aws_apigatewayv2_api.api.id
  route_key            = each.key
  target               = "integrations/${aws_apigatewayv2_integration.api[each.value.tier].id}"
  authorization_type   = "JWT"
  authorizer_id        = aws_apigatewayv2_authorizer.jwt.id
  authorization_scopes = [for s in each.value.scopes : "s3api/${s}"]
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 50
    throttling_rate_limit  = 25
  }

  depends_on = [aws_apigatewayv2_route.api]
}

resource "aws_lambda_permission" "api" {
  for_each      = local.tiers
  statement_id  = "AllowApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

############################ Local result files ############################

resource "local_sensitive_file" "result" {
  filename        = "${path.cwd}/tf-result.txt"
  file_permission = "0600"
  content = join("\n", concat(
    ["# S3 keys rotate every 11 min. Current keys per user:"],
    [for u, t in local.user_tier : "${u} (${t}): aws secretsmanager get-secret-value --region us-east-1 --secret-id ${aws_secretsmanager_secret.creds[u].name} --query SecretString --output text"],
    [
      "",
      "bucket=${aws_s3_bucket.main.id}",
      "kms_key=${aws_kms_key.main.arn}",
      "ec2_private_ip=${aws_instance.mc.private_ip}",
      "ec2_user=${var.ec2_username}",
      "ec2_password=${random_password.ec2.result}",
      "web_ui_readonly=http://${aws_instance.mc.private_ip}:8081",
      "web_ui_readwrite=http://${aws_instance.mc.private_ip}:8082",
      "",
      "api_endpoint=${aws_apigatewayv2_api.api.api_endpoint}",
      "token_url=https://${aws_cognito_user_pool_domain.api.domain}.auth.us-east-1.amazoncognito.com/oauth2/token",
      "token_example: curl -u CLIENT_ID:CLIENT_SECRET -d 'grant_type=client_credentials&scope=s3api/read' TOKEN_URL",
    ],
    flatten([for t in local.client_tiers : [
      "client_${t}_id=${aws_cognito_user_pool_client.api[t].id}",
      "client_${t}_secret=${aws_cognito_user_pool_client.api[t].client_secret}",
      "client_${t}_scope=s3api/${t}",
    ]]),
    [""]
  ))
}

resource "local_sensitive_file" "bastion" {
  filename        = "${path.cwd}/tf-bastion-result.txt"
  file_permission = "0600"
  content = join("\n", [
    "bastion_public_ip=${aws_eip.bastion.public_ip}",
    "bastion_key_user=ec2-user",
    "bastion_password_user=${var.bastion_username}",
    "bastion_password=${random_password.bastion.result}",
    "private_ec2_ip=${aws_instance.mc.private_ip}",
    "private_ec2_user=${var.ec2_username}",
    "private_ec2_password=${random_password.ec2.result}",
    "",
    "# save the key below as bastion_key.pem, then: chmod 600 bastion_key.pem",
    "ssh_bastion: ssh -i bastion_key.pem ec2-user@${aws_eip.bastion.public_ip}",
    "ssh_private_ec2: ssh -i bastion_key.pem -J ec2-user@${aws_eip.bastion.public_ip} ${var.ec2_username}@${aws_instance.mc.private_ip}",
    "web_ui_tunnel: ssh -i bastion_key.pem -L 8081:${aws_instance.mc.private_ip}:8081 -L 8082:${aws_instance.mc.private_ip}:8082 ec2-user@${aws_eip.bastion.public_ip}",
    "",
    "# private key (plain text):",
    tls_private_key.bastion.private_key_openssh,
    ""
  ])
}

######################## 
#  CloudWatch logs
#  SOURCE logGroups(namePrefix: [], class: "STANDARD") START=-1h END=0s |
#  filter errorCode = "AccessDenied"
#  | fields @timestamp, @message, eventName, errorCode, sourceIPAddress, userIdentity.arn
#  | sort @timestamp desc
#  | limit 30

# S3 keys rotate every 11 min. Current keys are:

# s3-readonly-user (readonly): aws secretsmanager get-secret-value --region us-east-1 --secret-id s3-creds-s3-readonly-user --query SecretString --output text

# s3-readwrite-user (readwrite): aws secretsmanager get-secret-value --region us-east-1 --secret-id s3-creds-s3-readwrite-user --query SecretString --output text

# s3-restore-user (restore): aws secretsmanager get-secret-value --region us-east-1 --secret-id s3-creds-s3-restore-user --query SecretString --output text

########################
