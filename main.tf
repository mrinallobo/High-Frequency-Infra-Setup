provider "aws" {
  region  = "ap-southeast-1"
  profile = "new-trading-account"
}

data "aws_availability_zones" "available" {
  filter {
    name   = "zone-id"
    values = ["apse1-az3"]
  }
}

resource "aws_vpc" "trading_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.resource_prefix}-trading-vpc" }
}

resource "aws_subnet" "trading_subnet" {
  vpc_id            = aws_vpc.trading_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "${var.resource_prefix}-trading-subnet" }
}

resource "aws_internet_gateway" "trading_igw" {
  vpc_id = aws_vpc.trading_vpc.id
  tags   = { Name = "${var.resource_prefix}-trading-igw" }
}

resource "aws_route_table" "trading_rt" {
  vpc_id = aws_vpc.trading_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.trading_igw.id
  }
  tags = { Name = "${var.resource_prefix}-trading-rt" }
}

resource "aws_route_table_association" "trading_rta" {
  subnet_id      = aws_subnet.trading_subnet.id
  route_table_id = aws_route_table.trading_rt.id
}

resource "aws_security_group" "trading_sg" {
  name        = "${var.resource_prefix}-trading-sg"
  description = "Low-cost trading security group"
  vpc_id      = aws_vpc.trading_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.resource_prefix}-trading-sg" }
}

resource "aws_placement_group" "trading_pg" {
  name     = "${var.resource_prefix}-trading-pg-ubuntu"
  strategy = "cluster"
}

resource "aws_key_pair" "trading_keypair" {
  key_name   = "${var.resource_prefix}-trading-keypair"
  public_key = file(var.ssh_public_key_path)
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "trading_instance" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  associate_public_ip_address = true
  subnet_id                   = aws_subnet.trading_subnet.id
  vpc_security_group_ids      = [aws_security_group.trading_sg.id]
  placement_group             = aws_placement_group.trading_pg.id
  key_name                    = aws_key_pair.trading_keypair.key_name

  user_data = base64encode(<<-EOF
    #!/bin/bash

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y build-essential git curl wget htop iotop sysstat linux-tools-common linux-tools-generic

    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="isolcpus=1 nohz_full=1 rcu_nocbs=1 /' /etc/default/grub
    update-grub

    cat > /etc/sysctl.d/99-trading-network.conf << 'NETEOF'
    net.core.rmem_max=16777216
    net.core.wmem_max=16777216
    net.core.rmem_default=1000000
    net.core.wmem_default=1000000
    net.ipv4.tcp_rmem=4096 1000000 16777216
    net.ipv4.tcp_wmem=4096 1000000 16777216
    net.ipv4.tcp_low_latency=1
    net.ipv4.tcp_timestamps=0
    net.ipv4.tcp_min_rtt_wlen=1024
    net.ipv4.tcp_fastopen=3
    net.ipv4.tcp_mtu_probing=1
    NETEOF
    sysctl -p /etc/sysctl.d/99-trading-network.conf

    if [ -f /sys/devices/system/cpu/smt/control ]; then
      echo off > /sys/devices/system/cpu/smt/control
    fi

    apt-get install -y cpufrequtils
    systemctl stop cpufrequtils || true
    systemctl disable cpufrequtils || true
    echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
    for CPUFREQ in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -f $CPUFREQ ] || continue; echo -n performance > $CPUFREQ; done

    apt-get install -y irqbalance
    echo 'IRQBALANCE_BANNED_CPULIST="1"' > /etc/default/irqbalance
    systemctl restart irqbalance

    swapoff -a
    sed -i '/swap/d' /etc/fstab

    cat > /etc/sysctl.d/99-trading-sched.conf << 'SCHEDEOF'
    kernel.sched_min_granularity_ns = 10000000
    kernel.sched_wakeup_granularity_ns = 15000000
    kernel.sched_migration_cost_ns = 5000000
    SCHEDEOF
    sysctl -p /etc/sysctl.d/99-trading-sched.conf

    apt-get install -y apt-transport-https ca-certificates curl software-properties-common
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    usermod -aG docker ubuntu

    su - ubuntu -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain nightly'

    su - ubuntu -c 'mkdir -p ~/.cargo'
    su - ubuntu -c 'cat > ~/.cargo/config.toml << RUSTCONF
    [build]
    rustflags = ["-C", "target-cpu=native", "-C", "link-arg=-fuse-ld=lld"]
    RUSTCONF'

    su - ubuntu -c 'source $HOME/.cargo/env && rustup component add rust-src llvm-tools-preview'

    apt-get install -y lld

    cat > /etc/udev/rules.d/60-scheduler.rules << 'SCHEDEOF'
    ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/scheduler}="deadline"
    ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="deadline"
    SCHEDEOF

    udevadm trigger --type=devices --action=change
    sleep 5
    for disk in $(lsblk -d -o name | tail -n +2); do
      if [ -e /sys/block/$disk/queue/scheduler ]; then
        current_scheduler=$(cat /sys/block/$disk/queue/scheduler)
        if [[ "$current_scheduler" != *"[deadline]"* ]]; then
            echo deadline > /sys/block/$disk/queue/scheduler || echo "Failed to set deadline for $disk"
        fi
      fi
    done

    cat > /etc/sysctl.d/99-trading-vm.conf << 'VMCONF'
    vm.swappiness = 0
    vm.vfs_cache_pressure = 50
    VMCONF
    sysctl -p /etc/sysctl.d/99-trading-vm.conf

    cat > /etc/sysctl.d/99-trading-numa.conf << 'NUMACONF'
    kernel.numa_balancing = 0
    NUMACONF
    sysctl -p /etc/sysctl.d/99-trading-numa.conf

    apt-get install -y ethtool

    PRIMARY_INTERFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

    if [ -n "$PRIMARY_INTERFACE" ]; then
      ethtool -K $PRIMARY_INTERFACE tso off || echo "Failed: TSO off"
      ethtool -K $PRIMARY_INTERFACE gso off || echo "Failed: GSO off"
      ethtool -K $PRIMARY_INTERFACE gro off || echo "Failed: GRO off"

      mkdir -p /etc/networkd-dispatcher/routable.d
      cat > /etc/networkd-dispatcher/routable.d/50-low-latency << ETHEOF
    #!/bin/sh
    if [ "\$IFACE" = "$PRIMARY_INTERFACE" ]; then
        /usr/sbin/ethtool -K \$IFACE tso off || logger "Failed to set TSO off for \$IFACE"
        /usr/sbin/ethtool -K \$IFACE gso off || logger "Failed to set GSO off for \$IFACE"
        /usr/sbin/ethtool -K \$IFACE gro off || logger "Failed to set GRO off for \$IFACE"
    fi
    ETHEOF
      chmod +x /etc/networkd-dispatcher/routable.d/50-low-latency
    else
      echo "Could not determine primary network interface."
    fi

    cat > /usr/local/bin/check-trading-optimizations << 'CHECKEOF'
    #!/bin/bash

    echo "=== Trading Optimizations Check ==="

    echo -e "\n[+] CPU Isolation status (cmdline):"
    cat /proc/cmdline | grep -E 'isolcpus|nohz_full|rcu_nocbs' || echo "  Not set or not found."

    echo -e "\n[+] CPU Governor:"
    cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || echo "  Could not read governors."

    echo -e "\n[+] Network Parameters (Selected):"
    sysctl net.core.rmem_max net.core.wmem_max net.ipv4.tcp_low_latency net.ipv4.tcp_timestamps net.ipv4.tcp_mtu_probing

    echo -e "\n[+] Hyper-Threading status:"
    if [ -f /sys/devices/system/cpu/smt/control ]; then
      cat /sys/devices/system/cpu/smt/control
    else
      echo "  SMT control file not found."
    fi

    echo -e "\n[+] Swap status:"
    free -h | grep Swap

    echo -e "\n[+] Docker status:"
    systemctl is-active docker
    systemctl is-enabled docker

    echo -e "\n[+] Rust version:"
    if command -v su &> /dev/null && id -u ubuntu &> /dev/null; then
      su - ubuntu -c 'source $HOME/.cargo/env && rustc --version' || echo "  Failed to get Rust version for user ubuntu."
    else
      echo "  Cannot check Rust for user ubuntu (su or user missing)."
    fi

    echo -e "\n[+] Disk Scheduler:"
    for disk in $(lsblk -d -o name | tail -n +2); do
      if [ -e /sys/block/$disk/queue/scheduler ]; then
        echo "  $disk: $(cat /sys/block/$disk/queue/scheduler)"
      fi
    done

    echo -e "\n[+] NIC Offloading Settings (Primary Interface):"
    PRIMARY_INTERFACE_CHECK=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    if [ -n "$PRIMARY_INTERFACE_CHECK" ]; then
      echo "  Interface: $PRIMARY_INTERFACE_CHECK"
      ethtool -k $PRIMARY_INTERFACE_CHECK | grep -E 'tcp-segmentation-offload:|generic-segmentation-offload:|generic-receive-offload:' || echo "  Could not get ethtool settings."
    else
      echo "  Could not determine primary interface."
    fi

    echo -e "\n=== Check Complete ==="
    echo "NOTE: A REBOOT is required for kernel cmdline (isolcpus etc) changes to take effect!"

    CHECKEOF

    chmod +x /usr/local/bin/check-trading-optimizations

    echo "Trading optimization script finished at $(date)" > /var/log/trading-optimizations.log
    echo "IMPORTANT: Reboot required for kernel GRUB parameters (isolcpus etc) to take full effect." >> /var/log/trading-optimizations.log

  EOF
  )

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 60
    delete_on_termination = true
  }

  tags = {
    Name = "${var.resource_prefix}-hft-instance-ubuntu"
  }
}

output "instance_public_ip" {
  value = aws_instance.trading_instance.public_ip
}

output "ssh_command" {
  value = "ssh -i ${var.ssh_private_key_path} ubuntu@${aws_instance.trading_instance.public_ip}"
}

output "optimization_check_command" {
  value = "ssh -i ${var.ssh_private_key_path} ubuntu@${aws_instance.trading_instance.public_ip} 'sudo /usr/local/bin/check-trading-optimizations'"
}

output "reboot_command" {
  value       = "ssh -i ${var.ssh_private_key_path} ubuntu@${aws_instance.trading_instance.public_ip} 'sudo reboot'"
  description = "Run this command after initial setup to apply kernel parameter changes."
}