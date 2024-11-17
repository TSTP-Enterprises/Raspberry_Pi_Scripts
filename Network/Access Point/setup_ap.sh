#!/bin/bash

# =============================================================================
# Raspberry Pi Access Point Setup Script
# =============================================================================
# This script automates the setup of a Raspberry Pi as a wireless Access Point
# using hostapd and isc-dhcp-server. It dynamically detects network interfaces,
# configures necessary services, and adapts to different hardware and network
# configurations.
#
# Requirements:
# - Run as root (use sudo)
# - Internet connection for package installation
#
# =============================================================================

# Exit immediately if a command exits with a non-zero status
set -e

# =============================================================================
# Function Definitions
# =============================================================================

# Function to print messages with colors
print_message() {
    local type="$1"
    local message="$2"
    case "$type" in
        "info")
            echo -e "\033[1;34m[INFO]\033[0m $message"
            ;;
        "success")
            echo -e "\033[1;32m[SUCCESS]\033[0m $message"
            ;;
        "warning")
            echo -e "\033[1;33m[WARNING]\033[0m $message"
            ;;
        "error")
            echo -e "\033[1;31m[ERROR]\033[0m $message"
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# Function to detect network interfaces
detect_interfaces() {
    print_message "info" "Detecting network interfaces..."

    # Detect all wired interfaces (eth*, en*)
    WIRED_INTERFACES=($(ls /sys/class/net/ | grep -E '^eth|^en'))
    if [ ${#WIRED_INTERFACES[@]} -eq 0 ]; then
        print_message "warning" "No wired interfaces detected."
    else
        print_message "info" "Wired interfaces detected: ${WIRED_INTERFACES[*]}"
    fi

    # Detect all wireless interfaces (wlan*, wifi*)
    WIFI_INTERFACES=($(ls /sys/class/net/ | grep -E '^wlan|^wifi'))
    if [ ${#WIFI_INTERFACES[@]} -eq 0 ]; then
        print_message "error" "No wireless interfaces detected. Exiting."
        exit 1
    else
        print_message "info" "Wireless interfaces detected: ${WIFI_INTERFACES[*]}"
    fi
}

# Function to determine the active internet-connected wired interface
find_internet_interface() {
    print_message "info" "Checking for active internet connection on wired interfaces..."

    for iface in "${WIRED_INTERFACES[@]}"; do
        if ip link show "$iface" | grep -q "state UP"; then
            if ping -c 1 -I "$iface" 8.8.8.8 &> /dev/null; then
                INTERNET_IFACE="$iface"
                print_message "success" "Internet-connected interface found: $INTERNET_IFACE"
                return
            fi
        fi
    done

    print_message "warning" "No active internet-connected wired interfaces found."
    INTERNET_IFACE=""
}

# Function to select wireless interface for AP
select_wifi_interface() {
    print_message "info" "Selecting wireless interface for Access Point..."

    # Prefer the first wireless interface
    WIFI_IFACE="${WIFI_INTERFACES[0]}"
    print_message "info" "Selected wireless interface: $WIFI_IFACE"
}

# Function to determine subnet for AP
determine_ap_subnet() {
    if [ -n "$INTERNET_IFACE" ]; then
        # Get current subnet of the internet interface
        CURRENT_SUBNET=$(ip -4 addr show "$INTERNET_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')
        if [ -z "$CURRENT_SUBNET" ]; then
            print_message "error" "Could not determine subnet for $INTERNET_IFACE. Exiting."
            exit 1
        fi
        print_message "info" "Current subnet for $INTERNET_IFACE: $CURRENT_SUBNET"

        # Derive AP subnet by incrementing the third octet
        IFS='/' read -r IP CIDR <<< "$CURRENT_SUBNET"
        IFS='.' read -r -a OCTETS <<< "$IP"
        AP_SUBNET="${OCTETS[0]}.${OCTETS[1]}.$((OCTETS[2] + 1)).1/24"
        AP_RANGE_START="${OCTETS[0]}.${OCTETS[1]}.$((OCTETS[2] + 1)).10"
        AP_RANGE_END="${OCTETS[0]}.${OCTETS[1]}.$((OCTETS[2] + 1)).50"
    else
        # Default subnet if no internet-connected interface
        AP_SUBNET="192.168.4.1/24"
        AP_RANGE_START="192.168.4.10"
        AP_RANGE_END="192.168.4.50"
    fi

    print_message "info" "AP subnet set to: ${AP_SUBNET%/*}"
}

# Function to install required packages
install_packages() {
    print_message "info" "Updating package lists and installing required packages..."
    sudo apt update
    sudo apt install -y hostapd isc-dhcp-server iptables-persistent
    sudo systemctl stop hostapd
    sudo systemctl stop isc-dhcp-server
}

# Function to configure static IP for AP interface
configure_static_ip() {
    print_message "info" "Configuring static IP for $WIFI_IFACE..."

    # Backup existing dhcpcd.conf
    sudo cp /etc/dhcpcd.conf /etc/dhcpcd.conf.backup

    # Remove existing static IP configuration for the wireless interface
    sudo sed -i "/interface $WIFI_IFACE/,/^[^ ]/d" /etc/dhcpcd.conf

    # Append new static IP configuration
    sudo bash -c "cat >> /etc/dhcpcd.conf" <<EOL

# Static IP configuration for Access Point
interface $WIFI_IFACE
    static ip_address=${AP_SUBNET%/*}
    nohook wpa_supplicant
EOL

    sudo systemctl restart dhcpcd
    print_message "success" "Static IP configured for $WIFI_IFACE."
}

# Function to configure DHCP server
configure_dhcp_server() {
    print_message "info" "Configuring DHCP server..."

    # Backup existing dhcpd.conf
    sudo cp /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf.backup

    # Create new dhcpd.conf
    sudo bash -c "cat > /etc/dhcp/dhcpd.conf" <<EOL
# DHCP Configuration for Raspberry Pi Access Point

default-lease-time 600;
max-lease-time 7200;

subnet ${AP_SUBNET%/*} netmask 255.255.255.0 {
    range ${AP_RANGE_START} ${AP_RANGE_END};
    option routers ${AP_SUBNET%/*};
    option domain-name-servers 8.8.8.8, 8.8.4.4;
}
EOL

    # Specify the interface for DHCP server
    sudo sed -i "s/INTERFACESv4=\"\"/INTERFACESv4=\"$WIFI_IFACE\"/" /etc/default/isc-dhcp-server

    print_message "success" "DHCP server configured."
}

# Function to configure hostapd
configure_hostapd() {
    print_message "info" "Configuring hostapd..."

    HOSTAPD_CONF="/etc/hostapd/hostapd.conf"

    # Create hostapd configuration
    sudo bash -c "cat > $HOSTAPD_CONF" <<EOL
interface=$WIFI_IFACE
driver=nl80211
ssid=RaspberryPi_AP
hw_mode=g
channel=7
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=raspberry
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOL

    # Point hostapd to the configuration file
    sudo sed -i "s|^#DAEMON_CONF=.*|DAEMON_CONF=\"$HOSTAPD_CONF\"|" /etc/default/hostapd

    print_message "success" "hostapd configured."
}

# Function to enable IP forwarding and configure NAT
configure_ip_forwarding() {
    print_message "info" "Enabling IP forwarding and configuring NAT..."

    # Enable IP forwarding
    sudo sed -i "/^#net.ipv4.ip_forward=1/s/^#//" /etc/sysctl.conf
    sudo sysctl -p

    # Backup existing iptables rules
    sudo cp /etc/iptables/rules.v4 /etc/iptables/rules.v4.backup || true

    # Flush existing NAT rules
    sudo iptables -t nat -F

    # Add NAT rule
    if [ -n "$INTERNET_IFACE" ]; then
        sudo iptables -t nat -A POSTROUTING -o "$INTERNET_IFACE" -j MASQUERADE
        sudo iptables -A FORWARD -i "$INTERNET_IFACE" -o "$WIFI_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
        sudo iptables -A FORWARD -i "$WIFI_IFACE" -o "$INTERNET_IFACE" -j ACCEPT
    else
        # If no internet-connected interface, allow local routing
        sudo iptables -t nat -A POSTROUTING -s "${AP_SUBNET%/*}/24" -o "$WIFI_IFACE" -j MASQUERADE
        sudo iptables -A FORWARD -s "${AP_SUBNET%/*}/24" -j ACCEPT
    fi

    # Save iptables rules
    sudo netfilter-persistent save

    print_message "success" "IP forwarding and NAT configured."
}

# Function to configure system services
configure_services() {
    print_message "info" "Enabling and starting services..."

    # Enable hostapd and isc-dhcp-server to start on boot
    sudo systemctl unmask hostapd
    sudo systemctl enable hostapd
    sudo systemctl enable isc-dhcp-server

    # Start services
    sudo systemctl start hostapd
    sudo systemctl start isc-dhcp-server

    print_message "success" "Services enabled and started."
}

# Function to handle different subnets and avoid conflicts
ensure_subnet_conflict_free() {
    if [ -n "$INTERNET_IFACE" ]; then
        CURRENT_SUBNET_OCTETS=($(echo "$CURRENT_SUBNET" | cut -d'.' -f1-3))
        AP_SUBNET_OCTETS=($(echo "$AP_SUBNET" | cut -d'.' -f1-3))
        if [ "${CURRENT_SUBNET_OCTETS[0]}" = "${AP_SUBNET_OCTETS[0]}" ] && \
           [ "${CURRENT_SUBNET_OCTETS[1]}" = "${AP_SUBNET_OCTETS[1]}" ] && \
           [ "${CURRENT_SUBNET_OCTETS[2]}" = "$((AP_SUBNET_OCTETS[2] - 1))" ]; then
            # If AP subnet is adjacent to current subnet, it's likely conflict-free
            return
        else
            print_message "warning" "AP subnet may conflict with existing network subnets."
            print_message "info" "You may need to manually adjust the AP subnet in /etc/dhcp/dhcpd.conf and /etc/dhcpcd.conf."
        fi
    fi
}

# Function to generate random SSID and password
generate_credentials() {
    print_message "info" "Generating random SSID and password..."

    SSID="RPi_AP_$(tr -dc A-Za-z0-9 </dev/urandom | head -c 6)"
    PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)

    print_message "success" "Generated SSID: $SSID"
    print_message "success" "Generated Password: $PASSWORD"

    # Update hostapd configuration with generated credentials
    sudo sed -i "s/^ssid=.*/ssid=$SSID/" /etc/hostapd/hostapd.conf
    sudo sed -i "s/^wpa_passphrase=.*/wpa_passphrase=$PASSWORD/" /etc/hostapd/hostapd.conf
}

# Function to handle OS compatibility
check_os() {
    print_message "info" "Checking operating system compatibility..."

    OS_NAME=$(lsb_release -si)
    OS_VERSION=$(lsb_release -sr)
    print_message "info" "Detected OS: $OS_NAME $OS_VERSION"

    # Currently supports Debian-based systems
    if [[ "$OS_NAME" != "Raspbian" && "$OS_NAME" != "Debian" && "$OS_NAME" != "Ubuntu" ]]; then
        print_message "warning" "This script is designed for Debian-based systems. Proceed with caution."
    fi
}

# =============================================================================
# Main Script Execution
# =============================================================================

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    print_message "error" "Please run as root (use sudo)."
    exit 1
fi

print_message "info" "Starting Raspberry Pi Access Point Setup Script..."

# Check OS compatibility
check_os

# Detect network interfaces
detect_interfaces

# If no wireless interfaces, exit
if [ ${#WIFI_INTERFACES[@]} -eq 0 ]; then
    print_message "error" "No wireless interfaces available. Exiting."
    exit 1
fi

# Find internet-connected interface
find_internet_interface

# Select wireless interface for AP
select_wifi_interface

# Determine AP subnet
determine_ap_subnet

# Ensure subnet does not conflict
ensure_subnet_conflict_free

# Install required packages
install_packages

# Configure static IP
configure_static_ip

# Configure DHCP server
configure_dhcp_server

# Configure hostapd
configure_hostapd

# Generate random SSID and password
generate_credentials

# Configure IP forwarding and NAT
configure_ip_forwarding

# Enable and start services
configure_services

# Final message
print_message "success" "Raspberry Pi has been configured as an Access Point."
print_message "success" "SSID: $SSID"
print_message "success" "Password: $PASSWORD"
print_message "info" "You can customize SSID and password by editing /etc/hostapd/hostapd.conf and restarting hostapd."

exit 0
