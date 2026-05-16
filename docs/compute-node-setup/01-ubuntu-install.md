# Step 1: Install Ubuntu 22.04 on hpg9-cp2

## Prerequisites

- USB drive with Ubuntu 22.04 Server ISO
- Network connectivity (192.168.30.x subnet)
- Static IP assignment ready

## Installation Steps

1. Boot from Ubuntu 22.04 Server USB
2. Choose "Install Ubuntu Server"
3. Configure network:
   - Static IP: `192.168.30.14` (or your preferred IP)
   - Gateway: `192.168.30.1`
   - DNS: `192.168.30.1` or `8.8.8.8`
4. Hostname: `hpg9-compute`
5. Create user: `ubuntu` (or your preferred username)
6. Enable OpenSSH server
7. Complete installation and reboot

## Post-Installation

SSH into the new node:
```bash
ssh ubuntu@192.168.30.14
```

Run the setup script (Step 2).
