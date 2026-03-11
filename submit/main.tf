terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "my_ip" {
  description = "Your public IP for SSH access (e.g., 73.12.11.192/32)"
  type        = string
  default     = "73.12.11.192/32"
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access"
  type        = string
  default     = "ds5220"
}

variable "git_repo_url" {
  description = "HTTPS URL of your forked anomaly-detection repo"
  type        = string
  default     = "https://github.com/nw93929/anomaly-detection-project1.git"
}

# ── Look up latest Ubuntu 24.04 LTS AMI ──────────────────────────────────────

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# ── S3 Bucket ─────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "app_bucket" {
  force_destroy = true
}

resource "aws_s3_bucket_notification" "raw_csv_notification" {
  bucket = aws_s3_bucket.app_bucket.id

  topic {
    topic_arn     = aws_sns_topic.ds5220_dp1.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "raw/"
    filter_suffix = ".csv"
  }

  depends_on = [aws_sns_topic_policy.allow_s3]
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "app_sg" {
  description = "Allow SSH from my IP and API from anywhere"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress {
    from_port   = 8000
    to_port     = 8000
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

# ── IAM Role and Instance Profile ────────────────────────────────────────────

resource "aws_iam_role" "ec2_role" {
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "s3_access" {
  role = aws_iam_role.ec2_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:*"
      Resource = [
        aws_s3_bucket.app_bucket.arn,
        "${aws_s3_bucket.app_bucket.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  role = aws_iam_role.ec2_role.name
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "app_server" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = "t3.micro"
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_size = 16
    volume_type = "gp3"
  }

  user_data = base64encode(templatefile("${path.module}/userdata.sh.tftpl", {
    bucket_name  = aws_s3_bucket.app_bucket.id
    git_repo_url = var.git_repo_url
  }))

  tags = {
    Name = "anomaly-detection-app"
  }
}

# ── Elastic IP ────────────────────────────────────────────────────────────────

resource "aws_eip" "app_eip" {
  instance = aws_instance.app_server.id
}

# ── SNS Topic + Policy ───────────────────────────────────────────────────────

resource "aws_sns_topic" "ds5220_dp1" {
  name = "ds5220-dp1"
}

resource "aws_sns_topic_policy" "allow_s3" {
  arn = aws_sns_topic.ds5220_dp1.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.ds5220_dp1.arn
      Condition = {
        ArnLike = {
          "aws:SourceArn" = aws_s3_bucket.app_bucket.arn
        }
      }
    }]
  })
}

# ── SNS Subscription ─────────────────────────────────────────────────────────

resource "aws_sns_topic_subscription" "http_notify" {
  topic_arn = aws_sns_topic.ds5220_dp1.arn
  protocol  = "http"
  endpoint  = "http://${aws_eip.app_eip.public_ip}:8000/notify"
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "bucket_name" {
  value = aws_s3_bucket.app_bucket.id
}

output "elastic_ip" {
  value = aws_eip.app_eip.public_ip
}

output "api_endpoint" {
  value = "http://${aws_eip.app_eip.public_ip}:8000/health"
}

output "sns_topic_arn" {
  value = aws_sns_topic.ds5220_dp1.arn
}
