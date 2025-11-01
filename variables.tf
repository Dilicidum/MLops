variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "app_path" {
  description = "Local path to your pricing app (contains Dockerfile, api.py, train_model.py, config.yaml, requirements.txt, etc.)"
  type        = string
  default     = "./"  # set to your current folder or ./app
}

variable "allow_cidr" {
  description = "CIDR allowed to access API/MLflow (use your IP/CIDR for security)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_type" {
  description = "EC2 size"
  type        = string
  default     = "t3.large"
}

variable "api_port" {
  type    = number
  default = 5000
}

variable "mlflow_port" {
  type    = number
  default = 5001
}
