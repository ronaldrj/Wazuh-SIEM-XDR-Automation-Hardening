#!/bin/bash

set -e

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "Cannot detect OS."
    exit 1
fi

# Detect interface and IP
if [[ "$OS" == "centos" ]]; then
    echo "Installing iproute if needed..."
    sudo yum install -y iproute || true
fi
 
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
IP_ADDR=$(ip addr show "$DEFAULT_IFACE" | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n1)

echo "Detected Interface: $DEFAULT_IFACE"
echo "Detected IP Address: $IP_ADDR"

# Install Suricata
install_suricata_ubuntu() {
    sudo apt update
    sudo apt install -y software-properties-common
    sudo add-apt-repository -y ppa:oisf/suricata-stable
    sudo apt update
    sudo apt install -y suricata
}

install_suricata_centos() {
    sudo yum install -y epel-release
    sudo yum install -y suricata
    sudo suricata-update enable-source et/open    
    sudo suricata-update update-sources
    sudo suricata-update
}

echo "Installing Suricata..."
case $OS in
    ubuntu)
        install_suricata_ubuntu
        ;;
    centos)
        install_suricata_centos
        ;;
    *)
        echo "Unsupported OS: $OS"
        exit 1
        ;;
esac

# Modify YAML file - NEW IMPROVED VERSION
YAML_FILE="/etc/suricata/suricata.yaml"
BACKUP_FILE="${YAML_FILE}.bak"
sudo cp "$YAML_FILE" "$BACKUP_FILE"

echo "Modifying Suricata config with detected interface: $DEFAULT_IFACE..."

# Now update both af-packet and pcap interfaces
sudo sed -i "/^[[:space:]]*af-packet:/,/^[[:space:]]*$/s/interface:.*/interface: $DEFAULT_IFACE/" "$YAML_FILE"
sudo sed -i "/^[[:space:]]*pcap:/,/^[[:space:]]*[a-zA-Z]/s/interface:.*/interface: $DEFAULT_IFACE/" "$YAML_FILE"

# Update HOME_NET
sudo sed -i "s|^\([[:space:]]*HOME_NET:\).*|\1 \"$IP_ADDR\"|" "$YAML_FILE"

# Enable community-id
sudo sed -i "s/^\([[:space:]]*community-id:[[:space:]]*\)false/\1true/" "$YAML_FILE"

# Verify changes
echo "Verifying changes:"
echo "AF_PACKET interface:"
sudo awk '/af-packet/,/^$/{if(/interface:/) print}' "$YAML_FILE"
echo "PCAP interface:"
sudo awk '/- pcap:/,/^$/{if(/interface:/) print}' "$YAML_FILE"
echo "HOME_NET:"
sudo grep "HOME_NET:" "$YAML_FILE"

sudo suricata-update

# Test configuration
sudo suricata -T -c "$YAML_FILE" -v

# Enable and start Suricata
sudo systemctl daemon-reexec
sudo systemctl enable suricata
sudo systemctl start suricata
sudo systemctl restart wazuh-agent

echo "Waiting 30 seconds for Wazuh agent to fully initialize..."
sleep 30
sudo systemctl restart suricata

