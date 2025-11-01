data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

data "archive_file" "app_zip" {
  type        = "zip"
  source_dir  = var.app_path
  output_path = "${path.module}/app.zip"
}

resource "aws_s3_object" "app_bundle" {
  bucket = aws_s3_bucket.ml.bucket
  key    = "deploy/app.zip"
  source = data.archive_file.app_zip.output_path
  etag   = filemd5(data.archive_file.app_zip.output_path)
}

# Unique bucket name
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "ml" {
  bucket = "pricing-artifacts-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_versioning" "ml" {
  bucket = aws_s3_bucket.ml.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "ml" {
  bucket                  = aws_s3_bucket.ml.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM role with S3 + SSM
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "pricing-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "s3_access" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${aws_s3_bucket.ml.bucket}"]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${aws_s3_bucket.ml.bucket}/*"]
  }
}

resource "aws_iam_policy" "s3_access" {
  name   = "pricing-ec2-s3-access"
  policy = data.aws_iam_policy_document.s3_access.json
}

# Attach S3 policy + SSM managed policy
resource "aws_iam_role_policy_attachment" "s3_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_access.arn
}

resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "pricing-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# Security Group
resource "aws_security_group" "sg" {
  name        = "pricing-sg"
  description = "Allow SSH (optional), API, MLflow"
  vpc_id      = data.aws_vpc.default.id

  # SSH optional: leave closed if only SSM is used
  # ingress { from_port = 22 to_port = 22 protocol = "tcp" cidr_blocks = [var.allow_cidr] }

  ingress {
    from_port   = var.api_port
    to_port     = var.api_port
    protocol    = "tcp"
    cidr_blocks = [var.allow_cidr]
    description = "API"
  }

  ingress {
    from_port   = var.mlflow_port
    to_port     = var.mlflow_port
    protocol    = "tcp"
    cidr_blocks = [var.allow_cidr]
    description = "MLflow UI"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 with SSM (no key pair)
resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = element(data.aws_subnet_ids.default.ids, 0)
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

  user_data = templatefile("${path.module}/user_data.sh", {
    repo_url    = var.repo_url
    bucket_name = aws_s3_bucket.ml.bucket
    region      = var.aws_region
    api_port    = var.api_port
    mlflow_port = var.mlflow_port
  })

  tags = { Name = "pricing-ec2" }
}

resource "aws_eip" "ip" {
  instance = aws_instance.app.id
  vpc      = true
}

output "bucket_name" { value = aws_s3_bucket.ml.bucket }
output "public_ip" { value = aws_eip.ip.public_ip }
output "api_url" { value = "http://${aws_eip.ip.public_ip}:${var.api_port}/health" }
output "mlflow_ui_url" { value = "http://${aws_eip.ip.public_ip}:${var.mlflow_port}" }
