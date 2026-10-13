
# aws pipeline codepipeline initial setup
#Elastic Container Service with ALB Application Load Balancer
#https://registry.terraform.io/modules/cn-terraform/ecs-fargate-task-definition/aws/latest

# ECS Cluster
resource "aws_ecs_cluster" "fargate_cluster" {
  name = "terraform-fargate-cluster"
}

# Task Definition
# cpu memory https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-cpu-memory-error.htm
# For Fargate tasks the only valid network_mode is awsvpc


resource "aws_ecs_task_definition" "fargate_task" {
  family                   = "terraform-fargate-task"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  network_mode             = "awsvpc"

  execution_role_arn = aws_iam_role.ecs_execution_role.arn

  task_role_arn = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "httpd:2.4.69-alpine"
      essential = true
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]
    }
  ])
}



# VPC

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}


# ECS Service
resource "aws_ecs_service" "fargate_service" {
  name            = "terraform-fargate-service"
  cluster         = aws_ecs_cluster.fargate_cluster.id
  task_definition = aws_ecs_task_definition.fargate_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  enable_execute_command = true


  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 80
  }


  network_configuration {
    subnets         = data.aws_subnets.default.ids
    assign_public_ip = true

    security_groups  = [aws_security_group.ecs.id]

  }

}



resource "aws_security_group" "ecs" {
  name   = "terraform-ecs-http"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
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


############# role for exec ###########
# aws ecs execute-command --cluster terraform-fargate-cluster \
# --task 4e0c3055af8040c79820ed9abf99d1bd --container app --interactive --command '/bin/sh'

#ECS Exec
#Turned on

# aws ecs execute-command --cluster terraform-fargate-cluster --task 4e0c3055af8040c79820ed9abf99d1bd --container app --interactive --command '/bin/sh'
# The Session Manager plugin was installed successfully. Use the AWS CLI to start a session.
# Starting session with SessionId: ecs-execute-command-tb289ey6tnlddyilpp6ge3isx8
# /usr/local/apache2 #



resource "aws_iam_role" "ecs_task_role" {
  name = "terraform-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_exec" {
  name = "ecs-exec-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })
}

########################################




############# ALB Application Load Balancer ###########

resource "aws_security_group" "alb" {
  name   = "terraform-alb-http"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
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

resource "aws_lb" "app" {
  name               = "terraform-fargate-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "app" {
  name        = "terraform-fargate-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip" # required for Fargate awsvpc
  vpc_id      = data.aws_vpc.default.id

  health_check {
    path    = "/"
    matcher = "200-399"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

output "alb_dns_name" {
  value = aws_lb.app.dns_name
}


############################################


############# Get ALB DNS name ###########

data "aws_lb" "app_lookup" {
  arn = aws_lb.app.arn
}

resource "terraform_data" "alb_url" {
  triggers_replace = aws_lb.app.dns_name

  provisioner "local-exec" {
    command = "echo ${data.aws_lb.app_lookup.dns_name} > alb_url.txt"
  }
}

output "alb_dns_name_lookup" {
  value = data.aws_lb.app_lookup.dns_name
}

############################################



############# Domain -> ALB ###########

resource "aws_route53_zone" "main" {
  name = "111"
}

resource "aws_route53_record" "root" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "111"
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "itworks" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "itworks.111"
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}

output "name_servers" {
  value = aws_route53_zone.main.name_servers
}

############################################



resource "aws_iam_role" "ecs_execution_role" {
  name = "terraform-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_role" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


###########################################











############# CodePipeline steps pull from GitHub -> CodeBuild -> ECS ###########

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}


#################  import already exist ############

import {
  to = aws_ssm_parameter.releaseversion
  id = "terraform-releaseversion"
}

resource "aws_ssm_parameter" "releaseversion" {
  name        = "terraform-releaseversion"
  description = "terraform-releaseversion"
  type        = "SecureString"
  value       = "0"
  tier        = "Standard"
  tags        = { Name = "terraformautov1" }

  lifecycle {
    ignore_changes = [value]
  }
}


#####################################################





# Git token from SSM Parameter Store
data "aws_ssm_parameter" "git_token" {
  name            = "terraform-gth"
  with_decryption = true
}

resource "aws_ecr_repository" "app" {
  name         = "terraform-fargate-app"
  force_delete = true
}

resource "aws_s3_bucket" "pipeline" {
  bucket        = "terraform-pipeline-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

# --- CodeBuild role ---
resource "aws_iam_role" "codebuild" {
  name = "terraform-codebuild-role"

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
  name = "terraform-codebuild-policy"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.pipeline.arn, "${aws_s3_bucket.pipeline.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = aws_ecr_repository.app.arn
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = aws_ssm_parameter.releaseversion.arn
      }
    ]
  })
}

resource "aws_codebuild_project" "build" {
  name         = "terraform-fargate-build"
  service_role = aws_iam_role.codebuild.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # required for docker build

    environment_variable {
      name  = "REPO_URI"
      value = aws_ecr_repository.app.repository_url
    }
    environment_variable {
      name  = "AWS_REGION"
      value = data.aws_region.current.region
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = <<-EOT
      version: 0.2
      phases:
        pre_build:
          commands:
            - aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $REPO_URI
            - TAG=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c 1-7)
        build:
          commands:
            - echo "FROM httpd:2.4.69-alpine" > Dockerfile
            - echo "COPY itworks /usr/local/apache2/htdocs/index.html" >> Dockerfile
            - docker build -t $REPO_URI:$TAG .
        post_build:
          commands:
            - docker push $REPO_URI:$TAG
            - printf '[{"name":"app","imageUri":"%s"}]' $REPO_URI:$TAG > imagedefinitions.json
            - aws ssm put-parameter --name terraform-releaseversion --type SecureString --region us-east-2 --overwrite --value "$(TZ=Europe/London date '+%Y-%m-%d %H:%M:%S %Z')"
      artifacts:
        files:
          - imagedefinitions.json
    EOT
  }
}

# --- CodePipeline role ---
resource "aws_iam_role" "codepipeline" {
  name = "terraform-codepipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codepipeline" {
  name = "terraform-codepipeline-policy"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning"]
        Resource = [aws_s3_bucket.pipeline.arn, "${aws_s3_bucket.pipeline.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild"]
        Resource = aws_codebuild_project.build.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService",
          "ecs:TagResource"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "*"
        Condition = {
          StringEqualsIfExists = {
            "iam:PassedToService" = ["ecs-tasks.amazonaws.com"]
          }
        }
      }
    ]
  })
}

resource "aws_codepipeline" "deploy" {
  name          = "terraform-fargate-pipeline"
  role_arn      = aws_iam_role.codepipeline.arn
  pipeline_type = "V2"

  artifact_store {
    location = aws_s3_bucket.pipeline.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "GitHub"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        Owner                = "11111"
        Repo                 = "111111"
        Branch               = "11111111"
        OAuthToken           = data.aws_ssm_parameter.git_token.value
        PollForSourceChanges = "true"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "DockerBuild"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "DeployToECS"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      input_artifacts = ["build_output"]

      configuration = {
        ClusterName = aws_ecs_cluster.fargate_cluster.name
        ServiceName = aws_ecs_service.fargate_service.name
        FileName    = "imagedefinitions.json"
      }
    }
  }
}

############################################

