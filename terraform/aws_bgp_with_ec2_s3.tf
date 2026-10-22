
# aws terraform stage 2 
# before that Start with Azure stage 1, since AWS needs the Azure gateway public IP resource "aws_customer_gateway" "azure"


resource "aws_vpc" "v" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_subnet" "a" {
  vpc_id            = aws_vpc.v.id
  cidr_block        = "10.10.1.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "b" {
  vpc_id            = aws_vpc.v.id
  cidr_block        = "10.10.2.0/24"
  availability_zone = "us-east-1b"
}

resource "aws_ec2_transit_gateway" "tgw" {
  amazon_side_asn = 64512
}

resource "aws_ec2_transit_gateway_vpc_attachment" "att" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  vpc_id             = aws_vpc.v.id
  subnet_ids         = [aws_subnet.a.id, aws_subnet.b.id]
}

resource "aws_customer_gateway" "azure" {
  bgp_asn    = 65515
  ip_address = "172.167.39.13"
  type       = "ipsec.1"
}

resource "aws_vpn_connection" "azure" {
  customer_gateway_id = aws_customer_gateway.azure.id
  transit_gateway_id  = aws_ec2_transit_gateway.tgw.id
  type                = "ipsec.1"
  static_routes_only  = false
  tunnel1_inside_cidr = "169.254.21.0/30"
  tunnel2_inside_cidr = "169.254.22.0/30"
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.v.id

  route {
    cidr_block         = "10.20.0.0/16"
    transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  }

  route {
    cidr_block         = "192.168.0.0/16"
    transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  }

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.att]
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.a.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.b.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_security_group" "ep" {
  name   = "s3-ep-dns"
  vpc_id = aws_vpc.v.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8", "192.168.0.0/16"]
  }

  ingress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["10.0.0.0/8", "192.168.0.0/16"]
  }

  ingress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8", "192.168.0.0/16"]
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id             = aws_vpc.v.id
  service_name       = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type  = "Interface"
  subnet_ids         = [aws_subnet.a.id, aws_subnet.b.id]
  security_group_ids = [aws_security_group.ep.id]
  private_dns_enabled = true
}

resource "aws_route53_resolver_endpoint" "in" {
  name               = "inbound"
  direction          = "INBOUND"
  security_group_ids = [aws_security_group.ep.id]

  ip_address {
    subnet_id = aws_subnet.a.id
  }

  ip_address {
    subnet_id = aws_subnet.b.id
  }
}

resource "aws_s3_bucket" "b" {
  bucket        = "1111111111111"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "b" {
  bucket                  = aws_s3_bucket.b.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}






resource "aws_s3_bucket_policy" "b" {
  bucket = aws_s3_bucket.b.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNotFromEndpoint"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.b.arn, "${aws_s3_bucket.b.arn}/*"]
      Condition = {
        StringNotEquals = { "aws:SourceVpce" = aws_vpc_endpoint.s3.id }
        ArnNotLike      = { "aws:PrincipalArn" = "arn:aws:iam::111111111111111" }
      }
    }]
  })
}




data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "vm" {
  name   = "vm-sg"
  vpc_id = aws_vpc.v.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.20.0.0/16", "192.168.0.0/16"]
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.20.0.0/16", "192.168.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "vm" {
  name = "vm-s3-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "vm" {
  role = aws_iam_role.vm.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject"]
      Resource = [aws_s3_bucket.b.arn, "${aws_s3_bucket.b.arn}/*"]
    }]
  })
}

resource "aws_iam_instance_profile" "vm" {
  name = "vm-profile"
  role = aws_iam_role.vm.name
}






resource "aws_instance" "vm" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.a.id
  private_ip                  = "10.10.1.10"
  vpc_security_group_ids      = [aws_security_group.vm.id]
  iam_instance_profile        = aws_iam_instance_profile.vm.name
  user_data_replace_on_change = true

  user_data = <<-EOT
    #!/bin/bash
    echo "ec2-user:11111111111111111" | chpasswd
    echo "PasswordAuthentication yes" > /etc/ssh/sshd_config.d/50-pw.conf
    systemctl restart sshd
  EOT

  tags = {
    Name = "aws-test-vm"
  }
}





resource "local_sensitive_file" "out" {
  filename = "${path.module}/outputs.txt"
  content  = <<-EOT
    t1_ip=${aws_vpn_connection.azure.tunnel1_address}
    t2_ip=${aws_vpn_connection.azure.tunnel2_address}
    t1_psk=${aws_vpn_connection.azure.tunnel1_preshared_key}
    t2_psk=${aws_vpn_connection.azure.tunnel2_preshared_key}
    resolver_ips=${join(",", aws_route53_resolver_endpoint.in.ip_address[*].ip)}
    aws_vm_ip=${aws_instance.vm.private_ip}
  EOT
}

output "t1_ip" {
  value = aws_vpn_connection.azure.tunnel1_address
}

output "t2_ip" {
  value = aws_vpn_connection.azure.tunnel2_address
}

output "t1_psk" {
  value     = aws_vpn_connection.azure.tunnel1_preshared_key
  sensitive = true
}

output "t2_psk" {
  value     = aws_vpn_connection.azure.tunnel2_preshared_key
  sensitive = true
}

output "resolver_ips" {
  value = aws_route53_resolver_endpoint.in.ip_address[*].ip
}

output "aws_vm_ip" {
  value = aws_instance.vm.private_ip
}
