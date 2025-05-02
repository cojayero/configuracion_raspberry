#!/bin/bash

# install_scanner.sh
# Script to install dependencies for network_scanner_advanced.py on Raspbian with Python 3.11
# Features:
# - Installs system and Python dependencies
# - Colored output: Green (success), Yellow (warning), Red (error)
# - Logs to scanner_install.log for troubleshooting
# - Uses onvif-zeep-async for ONVIF support

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Log file
LOG_FILE="scanner_install.log"
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
echo "[$TIMESTAMP] Starting installation for network_scanner_advanced.py" > "$LOG_FILE"
log_message "$GREEN" "INFO" "Installation script started"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_message "$RED" "ERROR" "This script must be run as root (use sudo)"
    exit 1
fi

# Check if requirements.txt exists
if [ ! -f "requirements.txt" ]; then
    log_message "$RED" "ERROR" "requirements.txt not found in current directory"
    exit 1
fi

# Step 1: Update package lists
log_message "$GREEN" "INFO" "Updating package lists..."
apt update >> "$LOG_FILE" 2>&1
check_status $? "Package lists updated successfully" "" "Failed to update package lists. Check $LOG_FILE for details"

# Step 2: Install system dependencies
log_message "$GREEN" "INFO" "Installing system dependencies (python3-pip, python3-tk, nmap, libxml2-dev, libxslt1-dev)..."
apt install -y python3-pip python3-tk nmap libxml2-dev libxslt1-dev >> "$LOG_FILE" 2>&1
check_status $? "System dependencies installed successfully" "" "Failed to install system dependencies. Check $LOG_FILE for details"

# Step 3: Install build tools for compilation
log_message "$GREEN" "INFO" "Installing build tools for compiling Python libraries..."
apt install -y build-essential gcc make python3-dev >> "$LOG_FILE" 2>&1
check_status $? "Build tools installed successfully" "" "Failed to install build tools. Check $LOG_FILE for details"

# Step 4: Verify Python 3.11
log_message "$GREEN" "INFO" "Checking Python 3.11 installation..."
if command -v python3.11 >/dev/null 2>&1; then
    PYTHON_VERSION=$(python3.11 --version 2>&1)
    log_message "$GREEN" "SUCCESS" "Python 3.11 found: $PYTHON_VERSION"
else
    log_message "$YELLOW" "WARNING" "Python 3.11 not found. Attempting to install..."
    apt install -y python3.11 >> "$LOG_FILE" 2>&1
    check_status $? "Python 3.11 installed successfully" "" "Failed to install Python 3.11. Check $LOG_FILE for details"
fi

# Step 5: Upgrade pip
#log_message "$GREEN" "INFO" "Upgrading pip..."
#pip3 install --upgrade pip >> "$LOG_FILE" 2>&1
#check_status $? "pip upgraded successfully" "" "Failed to upgrade pip. Check $LOG_FILE for details"

# Step 6: Install Python dependencies from requirements.txt
log_message "$GREEN" "INFO" "Installing Python dependencies from requirements.txt..."
pip3 install -r requirements.txt >> "$LOG_FILE" 2>&1
check_status $? "Python dependencies installed successfully" "" "Failed to install Python dependencies. Check $LOG_FILE for details"

# Step 7: Verify installed Python libraries
log_message "$GREEN" "INFO" "Verifying installed Python libraries..."
REQUIRED_LIBS=("scapy" "requests" "python-nmap" "tabulate" "ssdpy" "dnspython" "onvif-zeep-async" "zeep" "lxml")
MISSING_LIBS=()
for lib in "${REQUIRED_LIBS[@]}"; do
    if pip3 show "$lib" >/dev/null 2>&1; then
        log_message "$GREEN" "SUCCESS" "Library $lib is installed"
    else
        MISSING_LIBS+=("$lib")
    fi
done

if [ ${#MISSING_LIBS[@]} -eq 0 ]; then
    log_message "$GREEN" "SUCCESS" "All required Python libraries are installed"
else
    log_message "$RED" "ERROR" "Missing libraries: ${MISSING_LIBS[*]}. Check $LOG_FILE for details"
    exit 1
fi

# Step 8: Create default files if they don't exist
log_message "$GREEN" "INFO" "Checking for known_devices.txt and onvif_credentials.txt..."
if [ ! -f "known_devices.txt" ]; then
    echo "# Example MAC addresses" > known_devices.txt
    echo "b8:27:eb:12:34:56 # Raspberry Pi" >> known_devices.txt
    echo "ac:22:0b:84:e8:42 # Samsung Smart TV" >> known_devices.txt
    echo "f0:7b:cb:89:ca:36 # Router Movistar" >> known_devices.txt
    log_message "$GREEN" "SUCCESS" "Created default known_devices.txt"
else
    log_message "$YELLOW" "WARNING" "known_devices.txt already exists, skipping creation"
fi

if [ ! -f "onvif_credentials.txt" ]; then
    echo "# Format: username:password" > onvif_credentials.txt
    echo "# Example: admin:password123" >> onvif_credentials.txt
    log_message "$GREEN" "SUCCESS" "Created default onvif_credentials.txt"
else
    log_message "$YELLOW" "WARNING" "onvif_credentials.txt already exists, skipping creation"
fi

# Final message
log_message "$GREEN" "SUCCESS" "Installation completed successfully! You can now run the script with:"
log_message "$GREEN" "INFO" "sudo python3 network_scanner_advanced.py -i wlan0 -r 192.168.1.0/24"
log_message "$GREEN" "INFO" "For faster scans, use: sudo python3 network_scanner_advanced.py -i wlan0 -r 192.168.1.0/24 --fast"
log_message "$GREEN" "INFO" "Logs saved to $LOG_FILE for troubleshooting"