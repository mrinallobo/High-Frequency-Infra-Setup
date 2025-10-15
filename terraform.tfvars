
# --- REQUIRED ---
# Set a unique prefix for this deployment to avoid naming conflicts
resource_prefix = "something unique maybe?" # CHANGE THIS to something unique!

# Set the correct paths to your SSH keys on the machine running Terraform
ssh_public_key_path = "your pub key" # UPDATE if needed
ssh_private_key_path = "your private key"    # UPDATE 

# --- OPTIONAL OVERRIDES ---
# Instance type - hardcoded the c7i large due to it being the cheapest available machine that can give sub ms latency
# instance_type = "c7i.large"