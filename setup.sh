#!/usr/bin/env bash
# ==============================================================================
# setup.sh - Dependency installer and environment configuration for Ubuntu
# ArduinoPWM / DWE OS Sync Board
# ==============================================================================

set -euo pipefail

# Text formatting
BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
CYAN="\033[0;36m"
NC="\033[0m" # No Color

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

echo -e "${BOLD}====================================================${NC}"
echo -e "${BOLD}   ArduinoPWM / DWE OS Sync Board Setup (Ubuntu)   ${NC}"
echo -e "${BOLD}====================================================${NC}"
echo

# 1. Determine target user and sudo configuration
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
if [ -z "$REAL_HOME" ]; then
  REAL_HOME="$HOME"
fi

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
  RUN_AS_USER="sudo -u $REAL_USER"
else
  if ! command -v sudo >/dev/null 2>&1; then
    error "sudo is required to install system dependencies and udev rules."
    exit 1
  fi
  SUDO="sudo"
  RUN_AS_USER=""
fi

info "Target user: ${BOLD}$REAL_USER${NC} (home: $REAL_HOME)"

# 2. Update package index and install required system packages
info "Installing system dependencies via apt..."
$SUDO apt-get update -y
$SUDO apt-get install -y --no-install-recommends \
  curl \
  git \
  usbutils \
  udev \
  ca-certificates

success "System packages installed."

# 3. Install arduino-cli if not already available
ensure_arduino_cli() {
  export PATH="$REAL_HOME/.local/bin:/usr/local/bin:$PATH"

  if command -v arduino-cli >/dev/null 2>&1; then
    success "arduino-cli is already installed: $(command -v arduino-cli) ($(arduino-cli version | head -n1))"
    return 0
  fi

  info "Installing arduino-cli to /usr/local/bin..."
  if [ -n "$SUDO" ]; then
    curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | $SUDO BINDIR=/usr/local/bin sh
  else
    curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | BINDIR=/usr/local/bin sh
  fi

  export PATH="/usr/local/bin:$PATH"

  if ! command -v arduino-cli >/dev/null 2>&1; then
    # Fallback to user ~/.local/bin
    info "Installing to $REAL_HOME/.local/bin as fallback..."
    mkdir -p "$REAL_HOME/.local/bin"
    curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | BINDIR="$REAL_HOME/.local/bin" sh
    chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.local"
    export PATH="$REAL_HOME/.local/bin:$PATH"

    # Add to .bashrc if not present
    if [ -f "$REAL_HOME/.bashrc" ] && ! grep -q 'PATH.*\.local/bin' "$REAL_HOME/.bashrc"; then
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$REAL_HOME/.bashrc"
      info "Added ~/.local/bin to $REAL_HOME/.bashrc"
    fi
  fi

  success "arduino-cli installed successfully: $(arduino-cli version | head -n1)"
}

ensure_arduino_cli

# 4. Configure serial port access (dialout group)
info "Checking dialout group membership..."
if id -nG "$REAL_USER" | grep -qw "dialout"; then
  success "User $REAL_USER is already in the 'dialout' group."
else
  info "Adding user $REAL_USER to 'dialout' group for serial port access..."
  $SUDO usermod -aG dialout "$REAL_USER"
  warn "User $REAL_USER added to 'dialout'. Note: you may need to log out and back in,"
  warn "or run 'newgrp dialout' in your current terminal session for changes to take effect."
fi

# 5. Configure udev rules for USBtinyISP (1781:0c9f) and FTDI Sync Board (0403:6001)
info "Setting up udev rules..."

# USBtiny rule (Vendor 1781, Product 0c9f)
$SUDO tee /etc/udev/rules.d/99-usbtiny.rules >/dev/null << 'EOF'
# USBtinyISP programmer rules for ArduinoPWM
SUBSYSTEM=="usb", ATTR{idVendor}=="1781", ATTR{idProduct}=="0c9f", MODE="0666", GROUP="dialout"
EOF

# FTDI Sync Board rule (Vendor 0403, Product 6001)
$SUDO tee /etc/udev/rules.d/99-ftdi-syncboard.rules >/dev/null << 'EOF'
# FTDI FT232 Serial (UART) IC rules for ArduinoPWM Sync Board
SUBSYSTEM=="usb", ATTR{idVendor}=="0403", ATTR{idProduct}=="6001", MODE="0666", GROUP="dialout"
KERNEL=="ttyUSB[0-9]*", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", MODE="0666", GROUP="dialout"
EOF

info "Reloading udev rules..."
$SUDO udevadm control --reload-rules
$SUDO udevadm trigger
success "udev rules installed and applied."

# 6. Check for conflicting brltty service on Ubuntu
if systemctl is-active --quiet brltty 2>/dev/null || systemctl is-enabled --quiet brltty 2>/dev/null; then
  warn "Detected active 'brltty' service. On Ubuntu, brltty frequently seizes"
  warn "FTDI USB serial chips (0403:6001) and disconnects /dev/ttyUSB0 after a few seconds."
  info "Masking brltty service to prevent FTDI disconnection issues..."
  $SUDO systemctl stop brltty-udev.service brltty.service 2>/dev/null || true
  $SUDO systemctl mask brltty-udev.service brltty.service 2>/dev/null || true
  success "brltty service disabled."
fi

# 7. Install Arduino AVR Core
info "Installing Arduino AVR core for $REAL_USER..."
if [ -n "$RUN_AS_USER" ]; then
  $RUN_AS_USER env PATH="$PATH" arduino-cli core update-index
  $RUN_AS_USER env PATH="$PATH" arduino-cli core install arduino:avr
else
  arduino-cli core update-index
  arduino-cli core install arduino:avr
fi
success "Arduino AVR core installed."

# 8. Ensure scripts in repo are executable
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$REPO_DIR"/setup.sh 2>/dev/null || true
chmod +x "$REPO_DIR"/flash-bootloader.sh 2>/dev/null || true
chmod +x "$REPO_DIR"/flash-program.sh 2>/dev/null || true
chmod +x "$REPO_DIR"/flash-all.sh 2>/dev/null || true
chmod +x "$REPO_DIR"/monitor.sh 2>/dev/null || true

echo
echo -e "${GREEN}${BOLD}Setup completed successfully!${NC}"
echo -e "You can now flash and monitor your board using:"
echo -e "  - ${BOLD}./flash-all.sh${NC}        (one-shot: burns bootloader and flashes sketch)"
echo -e "  - ${BOLD}./flash-bootloader.sh${NC} (burn bootloader only using USBtiny / 1781:0c9f)"
echo -e "  - ${BOLD}./flash-program.sh${NC}    (flash sketch only to Sync Board / 0403:6001)"
echo -e "  - ${BOLD}./flash-program.sh -monitor${NC} (or ${BOLD}./monitor.sh${NC} to view serial)"
