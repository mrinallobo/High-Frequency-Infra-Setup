variable "resource_prefix" {
  description = "A unique prefix for naming AWS resources (e.g., 'hft-1')"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the trading server"
  type        = string
  default     = "c7i.large"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key file for instance access"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key file for instance access (used for output commands)"
  type        = string
}