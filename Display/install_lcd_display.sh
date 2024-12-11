#!/bin/bash

# Script to setup or repair LCD displays on various Linux distributions
# Includes backup, restore, error handling, and automatic mode

set -e  # Exit immediately if a command exits with a non-zero status

# Define constants
BACKUP_DIR="/backup_lcd_display"
CONFIG_FILE="/boot/config.txt"
BASH_PROFILE_PATH="$HOME/.bash_profile" 
XORG_CONF_DIR="/usr/share/X11/xorg.conf.d"
LOG_FILE="/var/log/Xorg.0.log"

# Detect package manager and set commands accordingly
if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt-get"
    PKG_UPDATE="apt-get update"
    PKG_INSTALL="apt-get install -y"
    PKG_CHECK="dpkg -l"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    PKG_UPDATE="dnf check-update"
    PKG_INSTALL="dnf install -y"
    PKG_CHECK="rpm -q"
elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
    PKG_UPDATE="pacman -Sy"
    PKG_INSTALL="pacman -S --noconfirm"
    PKG_CHECK="pacman -Qi"
else
    echo "Unsupported package manager. Exiting."
    exit 1
fi

# Detect desktop environment and set packages accordingly
if [ -f /etc/debian_version ]; then
    DE_PACKAGES="xserver-xorg xinit lightdm xfce4"
    BROWSER="chromium"
elif [ -f /etc/fedora-release ]; then
    DE_PACKAGES="xorg-x11-server-Xorg xorg-x11-xinit lightdm xfce4-session"
    BROWSER="chromium"
elif [ -f /etc/arch-release ]; then
    DE_PACKAGES="xorg-server xorg-xinit lightdm xfce4"
    BROWSER="chromium"
else
    DE_PACKAGES="xserver-xorg xinit lightdm xfce4"
    BROWSER="chromium"
fi

# Helper function to log messages
log_message() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message"
}

# Function to check if a package is installed
check_package() {
    $PKG_CHECK "$1" &> /dev/null
}

# Function to check required packages and files
check_requirements() {
    local missing_packages=()
    local packages=($DE_PACKAGES $BROWSER "git")
    
    log_message "Checking required packages..."
    for pkg in "${packages[@]}"; do
        if ! check_package "$pkg"; then
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -eq 0 ]; then
        log_message "All required packages are installed."
        return 0
    else
        log_message "Missing packages: ${missing_packages[*]}"
        return 1
    fi
}

# Function to create backups
backup_files() {
    log_message "Creating backups..."
    mkdir -p "$BACKUP_DIR"
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$BACKUP_DIR/config.txt.bak"
    fi
    if [ -f "$BASH_PROFILE_PATH" ]; then
        cp "$BASH_PROFILE_PATH" "$BACKUP_DIR/bash_profile.bak"
    fi
    log_message "Backups completed and stored in $BACKUP_DIR."
}

# Function to restore backups
restore_files() {
    log_message "Restoring backups..."
    if [ -f "$BACKUP_DIR/config.txt.bak" ]; then
        cp "$BACKUP_DIR/config.txt.bak" "$CONFIG_FILE"
    fi
    if [ -f "$BACKUP_DIR/bash_profile.bak" ]; then
        cp "$BACKUP_DIR/bash_profile.bak" "$BASH_PROFILE_PATH"
    fi
    log_message "Restore completed."
}

# Function to install the display
install_display() {
    log_message "Starting installation for the LCD display..."

    # Check requirements first
    if ! check_requirements; then
        # Update the system
        log_message "Updating the system..."
        $PKG_UPDATE

        # Install necessary software
        log_message "Installing required software..."
        $PKG_INSTALL $DE_PACKAGES $BROWSER git
    fi

    # Check if X server is running
    if ! pgrep X >/dev/null; then
        log_message "X server is not running. Starting X server..."
        if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
            # Over SSH, start X detached
            DISPLAY=:0 startx -- :0 &
        else
            # Local, can start normally
            startx &
        fi
        sleep 5
    fi

    # Install LCD drivers if not present
    if [ ! -d "LCD-show" ]; then
        log_message "LCD drivers not found. Installing LCD drivers..."
        git clone https://github.com/goodtft/LCD-show.git
        chmod -R 755 LCD-show
        cd LCD-show
        sudo ./MPI4008-show
    fi

    # Install and configure fbcp
    if ! command -v fbcp &> /dev/null; then
        log_message "Installing fbcp..."
        git clone https://github.com/tasanakorn/rpi-fbcp
        cd rpi-fbcp
        mkdir build
        cd build
        cmake ..
        make
        sudo install fbcp /usr/local/bin/fbcp
    fi

    if ! pgrep fbcp >/dev/null; then
        log_message "Starting fbcp..."
        sudo fbcp &
    fi

    # Create systemd service for fbcp
    if [ ! -f "/etc/systemd/system/fbcp.service" ]; then
        cat > /etc/systemd/system/fbcp.service << EOF
[Unit]
Description=fbcp display mirroring service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/fbcp
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable fbcp.service
        systemctl start fbcp.service
    fi

    log_message "Installation completed successfully."
}

# Main script execution
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

echo "Choose an option:"
echo "1) Install"
echo "2) Restore"
read -rp "Enter your choice (1/2): " choice
case $choice in
    1)
        backup_files
        install_display
        ;;
    2)
        restore_files
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac
