#!/bin/bash

# enable_rdp.sh
# Script to enable RDP support on Raspbian for remote desktop connections from Windows
# Features:
# - Installs and configures XRDP and a desktop environment
# - Opens firewall port 3389 (if ufw is active)
# - Logs actions to rdp_install.log
# - Displays IP address and login instructions
# - Suitable for remote execution via SSH

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Log file
LOG_FILE="rdp_install.log"
# Timestamp for log entries
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Function to log messages
log_message() {
    local color=$1
    local level=$2
    local message=$3
    echo -e "${color}[${level}] ${message}${NC}" | tee -a "$LOG_FILE"
}

# Function to check command success
check_status() {
    local status=$1
    local success_msg=$2
    local warn_msg=$3
    local error_msg=$4
    if [ $status -eq 0 ]; then
        log_message "$GREEN" "SUCCESS" "$success_msg"
        return 0
    elif [ -n "$warn_msg" ]; then
        log_message "$YELLOW" "WARNING" "$warn_msg"
        return 1
    else
        log_message "$RED" "ERROR" "$error_msg"
        exit 1
    fi
}

# Initialize log file
echo "[$TIMESTAMP] Starting RDP installation and configuration" > "$LOG_FILE"
log_message "$GREEN" "INFO" "RDP setup script started"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_message "$RED" "ERROR" "This script must be run as root (use sudo)"
    exit 1
fi

# Step 1: Update package lists
log_message "$GREEN" "INFO" "Updating package lists..."
apt update >> "$LOG_FILE" 2>&1
check_status $? "Package lists updated successfully" "" "Failed to update package lists. Check $LOG_FILE for details"

# Step 2: Install desktop environment (if not already installed)
log_message "$GREEN" "INFO" "Checking for desktop environment..."
if ! dpkg -l | grep -q raspberrypi-ui-mods; then
    log_message "$YELLOW" "WARNING" "Desktop environment not found. Installing raspberrypi-ui-mods..."
    apt install -y raspberrypi-ui-mods >> "$LOG_FILE" 2>&1
    check_status $? "Desktop environment installed successfully" "" "Failed to install desktop environment. Check $LOG_FILE for details"
else
    log_message "$GREEN" "SUCCESS" "Desktop environment already installed"
fi

# Step 3: Install XRDP and dependencies
log_message "$GREEN" "INFO" "Installing XRDP and xorgxrdp..."
apt install -y xrdp xorgxrdp >> "$LOG_FILE" 2>&1
check_status $? "XRDP and xorgxrdp installed successfully" "" "Failed to install XRDP. Check $LOG_FILE for details"

# Step 4: Ensure XRDP service is enabled and running
log_message "$GREEN" "INFO" "Configuring XRDP service..."
systemctl enable xrdp >> "$LOG_FILE" 2>&1
systemctl start xrdp >> "$LOG_FILE" 2>&1
check_status $? "XRDP service enabled and started" "" "Failed to enable or start XRDP service. Check $LOG_FILE for details"

# Step 5: Check if ufw is active and open port 3389
log_message "$GREEN" "INFO" "Checking firewall status..."
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    log_message "$YELLOW" "WARNING" "UFW firewall is active. Opening port 3389 for RDP..."
    ufw allow 3389/tcp >> "$LOG_FILE" 2>&1
    check_status $? "Port 3389 opened in UFW" "" "Failed to open port 3389 in UFW. Check $LOG_FILE for details"
else
    log_message "$GREEN" "SUCCESS" "No active UFW firewall detected, skipping port configuration"
fi

# Step 6: Get IP address for RDP connection
log_message "$GREEN" "INFO" "Retrieving IP address..."
IP_ADDRESS=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)
if [ -z "$IP_ADDRESS" ]; then
    log_message "$RED" "ERROR" "Could not determine IP address. Check network configuration."
    exit 1
else
    log_message "$GREEN" "SUCCESS" "IP address found: $IP_ADDRESS"
fi

# Step 7: Verify XRDP is running
log_message "$GREEN" "INFO" "Verifying XRDP status..."
if systemctl is-active --quiet xrdp; then
    log_message "$GREEN" "SUCCESS" "XRDP is running"
else
    log_message "$RED" "ERROR" "XRDP is not running. Check $LOG_FILE for details."
    exit 1
fi

# Final instructions
log_message "$GREEN" "SUCCESS" "RDP setup completed successfully!"
log_message "$GREEN" "INFO" "To connect from Windows:"
log_message "$GREEN" "INFO" "1. Open Remote Desktop Connection (mstsc.exe)"
log_message "$GREEN" "INFO" "2. Enter IP address: $IP_ADDRESS"
log_message "$GREEN" "INFO" "3. Use your Raspbian credentials (e.g., user: pi, password: <your_password>)"
log_message "$GREEN" "INFO" "Note: Ensure port 3389 is open on your network and firewall."
log_message "$GREEN" "INFO" "Logs saved to $LOG_FILE for troubleshooting"
log_message "$YELLOW" "WARNING" "For security, consider changing the default password and securing XRDP with SSL or a VPN."