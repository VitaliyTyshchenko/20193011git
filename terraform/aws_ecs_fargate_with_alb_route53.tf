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



# Compute container

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

#ECS Exec
#Turned on

# aws ecs execute-command --cluster terraform-fargate-cluster --task ID --container app --interactive --command '/bin/sh'
# The Session Manager plugin was installed successfully. Use the AWS CLI to start a session.
# Starting session with SessionId: ecs-execute-command
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
  name = "aws.mydomain"
}

resource "aws_route53_record" "root" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "aws.mydomain"
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "itworks" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "itworks.aws.mydomain"
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

