variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "repo_url" {
  description = "Git repo URL with your project (Dockerfile, api.py, train_model.py, config.yaml, requirements.txt)"
  type        = string
  default     = "https://github.com/Dilicidum/MLops.git"
}

variable "allow_cidr" {
  description = "CIDR allowed to access API/MLflow (use your IP/CIDR for security)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_type" {
  description = "EC2 size"
  type    = string
  default = "t3.small"
}

variable "api_port" {
  type    = number
  default = 5000
}

variable "mlflow_port" {
  type    = number
  default = 5001
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR"
  type        = string
  default     = "10.0.1.0/24"
}

variable "repo_ref" {
  description = "Branch/tag/commit to checkout"
  type        = string
  default     = "main"
}

variable "availability_zone" {
  description = "AZ for the public subnet (optional)"
  type        = string
  default     = null
  # e.g. "eu-central-1a" if you want to pin it
}