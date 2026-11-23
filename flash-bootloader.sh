#!/usr/bin/env bash
# ==============================================================================
# flash-bootloader.sh - Autodetect USBtiny (1781:0c9f) and burn bootloader
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

# Configuration
BOARD="${BOARD:-arduino:avr:uno}"
PROGRAMMER="${PROGRAMMER:-usbtinyisp}"
TARGET_VID="1781"
TARGET_PID="0c9f"
TIMEOUT_SECS=30
AUTO_CONFIRM=false

usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Autodetects USBtiny ISP programmer (1781:0c9f) and burns the Arduino Uno bootloader.

Options:
  -y, --yes          Skip confirmation prompt and burn immediately
  -b, --board FQBN   Specify board FQBN (default: arduino:avr:uno)
  -P, --programmer P Specify programmer (default: usbtinyisp)
  -t, --timeout SEC  Timeout in seconds waiting for device (default: 30)
  -h, --help         Show this help message

EOF
  exit 0
}

# Parse options
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)
      AUTO_CONFIRM=true
      shift
      ;;
    -b|--board)
      BOARD="$2"
      shift 2
      ;;
    -P|--programmer)
      PROGRAMMER="$2"
      shift 2
      ;;
    -t|--timeout)
      TIMEOUT_SECS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      error "Unknown option: $1"
      usage
      ;;
  esac
done

echo -e "${BOLD}====================================================${NC}"
echo -e "${BOLD}   ArduinoPWM / DWE OS Bootloader Flasher          ${NC}"
echo -e "${BOLD}====================================================${NC}"
echo

# 1. Ensure arduino-cli is accessible
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
if ! command -v arduino-cli >/dev/null 2>&1; then
  error "arduino-cli command not found on PATH."
  echo -e "Please run ${BOLD}./setup.sh${NC} to install all dependencies."
  exit 1
fi

# 2. Check if arduino:avr core is installed
if ! arduino-cli core list 2>/dev/null | grep -q 'arduino:avr'; then
  warn "arduino:avr core does not appear to be installed."
  info "Attempting to install arduino:avr core..."
  if arduino-cli core update-index 2>/dev/null && arduino-cli core install arduino:avr 2>/dev/null; then
    success "arduino:avr core installed."
  else
    warn "Could not install arduino:avr core automatically. Please run ./setup.sh first if compile fails."
  fi
fi

# 3. Detection functions
check_usbtiny_present() {
  # Check via lsusb if installed
  if command -v lsusb >/dev/null 2>&1; then
    if lsusb -d "${TARGET_VID}:${TARGET_PID}" >/dev/null 2>&1; then
      return 0
    fi
    if lsusb 2>/dev/null | grep -qiE "${TARGET_VID}:${TARGET_PID}|usbtiny"; then
      return 0
    fi
  fi

  # Check via sysfs
  for d in /sys/bus/usb/devices/*; do
    if [ -f "$d/idVendor" ] && [ -f "$d/idProduct" ]; then
      local v p
      v="$(cat "$d/idVendor" 2>/dev/null || true)"
      p="$(cat "$d/idProduct" 2>/dev/null || true)"
      if [ "${v,,}" = "${TARGET_VID,,}" ] && [ "${p,,}" = "${TARGET_PID,,}" ]; then
        return 0
      fi
    fi
  done

  return 1
}

check_ftdi_present() {
  if command -v lsusb >/dev/null 2>&1; then
    if lsusb -d "0403:6001" >/dev/null 2>&1; then
      return 0
    fi
  fi
  for d in /sys/bus/usb/devices/*; do
    if [ -f "$d/idVendor" ] && [ -f "$d/idProduct" ]; then
      local v p
      v="$(cat "$d/idVendor" 2>/dev/null || true)"
      p="$(cat "$d/idProduct" 2>/dev/null || true)"
      if [ "${v,,}" = "0403" ] && [ "${p,,}" = "6001" ]; then
        return 0
      fi
    fi
  done
  return 1
}

# 4. Autodetect USBtiny
info "Checking for USBtiny ISP programmer (${TARGET_VID}:${TARGET_PID})..."

if ! check_usbtiny_present; then
  if check_ftdi_present; then
    warn "Detected Sync Board (FTDI 0403:6001), but bootloader burning requires"
    warn "the USBtiny ISP programmer (1781:0c9f) connected to the TC2030 pogo header."
  fi

  info "USBtiny not immediately detected. Waiting for device to be plugged in..."
  echo -e "  (Waiting up to ${TIMEOUT_SECS}s. Press ${BOLD}Ctrl+C${NC} to abort)"

  waited=0
  while [ "$waited" -lt "$TIMEOUT_SECS" ]; do
    sleep 1
    waited=$((waited + 1))
    if check_usbtiny_present; then
      break
    fi
    echo -n "."
  done
  echo

  if ! check_usbtiny_present; then
    error "USBtiny ISP programmer (${TARGET_VID}:${TARGET_PID}) was not detected within ${TIMEOUT_SECS} seconds."
    echo
    echo -e "${BOLD}Troubleshooting checklist:${NC}"
    echo "  1. Verify the USBtiny is firmly plugged into a working USB port."
    echo "  2. Run 'lsusb' to verify the device is recognized by Linux."
    echo "  3. If permissions fail, ensure udev rules are active: run ./setup.sh"
    exit 1
  fi
fi

# Print device details if lsusb is available
if command -v lsusb >/dev/null 2>&1; then
  DEV_STR="$(lsusb -d "${TARGET_VID}:${TARGET_PID}" 2>/dev/null || true)"
  if [ -n "$DEV_STR" ]; then
    success "Detected USBtiny ISP: ${BOLD}${DEV_STR}${NC}"
  else
    success "Detected USBtiny ISP programmer (${TARGET_VID}:${TARGET_PID})"
  fi
else
  success "Detected USBtiny ISP programmer (${TARGET_VID}:${TARGET_PID})"
fi

# 5. Pre-flash instructions and confirmation
echo
echo -e "${BOLD}Flashing Configuration:${NC}"
echo "  - Board:      $BOARD"
echo "  - Programmer: $PROGRAMMER"
echo
echo -e "${YELLOW}${BOLD}Important steps before proceeding:${NC}"
echo "  1. Plug the TC2030-IDC cable into the USBtiny."
echo "  2. Press and hold the TC2030 pogo head onto the Sync Board pads (red stripe on pin 1)."
echo "  3. If the Sync Board is also powered via USB, remove the USBtiny's power jumper."
echo "  4. Maintain steady contact with the pogo pins throughout burning."
echo

if [ "$AUTO_CONFIRM" != "true" ]; then
  read -r -p "Ready to burn bootloader? Press [Enter] to continue (or Ctrl+C to cancel)... "
  echo
fi

# 6. Execute burn-bootloader
info "Burning bootloader to $BOARD via $PROGRAMMER..."

if arduino-cli burn-bootloader -b "$BOARD" -P "$PROGRAMMER"; then
  echo
  success "${BOLD}Bootloader successfully burned!${NC}"
  echo
  info "Next step:"
  echo "  1. Disconnect the USBtiny ISP programmer."
  echo "  2. Connect the Sync Board via its USB cable."
  echo -e "  3. Flash the sketch: ${BOLD}./flash-program.sh${NC}"
  exit 0
else
  burn_exit=$?
  echo
  error "Failed to burn bootloader (exit code $burn_exit)."
  echo
  echo -e "${BOLD}Common issues:${NC}"
  echo "  - 'initialization failed' / signature error: Re-seat the TC2030 pogo head"
  echo "    firmly on the pads and hold it steady, then run this script again."
  echo "  - Alignment: Ensure the red stripe of the TC2030 cable is on pin 1."
  echo "  - Power conflict: If the board is USB powered, remove the USBtiny power jumper."
  echo "  - Permissions: Ensure udev rules are loaded by running ./setup.sh"
  exit $burn_exit
fi
