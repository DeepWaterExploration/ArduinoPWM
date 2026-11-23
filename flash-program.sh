#!/usr/bin/env bash
# ==============================================================================
# flash-program.sh - Autodetect Sync Board (FTDI 0403:6001) and flash sketch
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
TARGET_VID="0403"
TARGET_PID="6001"
TIMEOUT_SECS=30
MONITOR_ONLY=false
FLASH_AND_MONITOR=false
PORT_OVERRIDE=""

# Paths
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKETCH_DIR="$REPO_DIR/dweos_arduino"

usage() {
  cat << EOF
Usage: $0 [OPTIONS] [PORT]

Autodetects the Sync Board (FTDI 0403:6001) and compiles/uploads the sketch.

Options:
  -p, --port PORT          Specify serial port manually (e.g. /dev/ttyUSB0)
  -b, --board FQBN         Specify board FQBN (default: arduino:avr:uno)
  -m, --monitor, -monitor  Open serial monitor (9600 baud) directly without flashing
  --flash-and-monitor      Flash sketch and then open serial monitor
  -t, --timeout SEC        Timeout in seconds waiting for device (default: 30)
  -h, --help               Show this help message

Examples:
  $0                       # Autodetect port and flash sketch
  $0 -monitor              # Autodetect port and open serial monitor (no flashing)
  $0 /dev/ttyUSB0          # Flash to specific port
  $0 -monitor /dev/ttyUSB0 # Open monitor on specific port
EOF
  exit 0
}

# Parse options
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--port)
      PORT_OVERRIDE="$2"
      shift 2
      ;;
    -b|--board)
      BOARD="$2"
      shift 2
      ;;
    -m|--monitor|-monitor)
      MONITOR_ONLY=true
      shift
      ;;
    --flash-and-monitor)
      FLASH_AND_MONITOR=true
      shift
      ;;
    -t|--timeout)
      TIMEOUT_SECS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    /dev/*)
      PORT_OVERRIDE="$1"
      shift
      ;;
    *)
      error "Unknown option or argument: $1"
      usage
      ;;
  esac
done

echo -e "${BOLD}====================================================${NC}"
echo -e "${BOLD}   ArduinoPWM / DWE OS Sketch Flasher              ${NC}"
echo -e "${BOLD}====================================================${NC}"
echo

# 1. Ensure arduino-cli is accessible
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
if ! command -v arduino-cli >/dev/null 2>&1; then
  error "arduino-cli command not found on PATH."
  echo -e "Please run ${BOLD}./setup.sh${NC} to install all dependencies."
  exit 1
fi

# 2. Check sketch and core only if flashing
if [ "$MONITOR_ONLY" != "true" ]; then
  if [ ! -f "$SKETCH_DIR/dweos_arduino.ino" ]; then
    error "Sketch file not found at: $SKETCH_DIR/dweos_arduino.ino"
    exit 1
  fi

  if ! arduino-cli core list 2>/dev/null | grep -q 'arduino:avr'; then
    warn "arduino:avr core does not appear to be installed."
    info "Attempting to install arduino:avr core..."
    if arduino-cli core update-index 2>/dev/null && arduino-cli core install arduino:avr 2>/dev/null; then
      success "arduino:avr core installed."
    else
      warn "Could not install arduino:avr core automatically. Please run ./setup.sh first if compile fails."
    fi
  fi
fi

# 4. Port detection helpers
check_usbtiny_present() {
  if command -v lsusb >/dev/null 2>&1; then
    if lsusb -d "1781:0c9f" >/dev/null 2>&1 || lsusb 2>/dev/null | grep -qiE '1781:0c9f|usbtiny'; then
      return 0
    fi
  fi
  for d in /sys/bus/usb/devices/*; do
    if [ -f "$d/idVendor" ] && [ -f "$d/idProduct" ]; then
      local v p
      v="$(cat "$d/idVendor" 2>/dev/null || true)"
      p="$(cat "$d/idProduct" 2>/dev/null || true)"
      if [ "${v,,}" = "1781" ] && [ "${p,,}" = "0c9f" ]; then
        return 0
      fi
    fi
  done
  return 1
}

check_ftdi_usb_present() {
  if command -v lsusb >/dev/null 2>&1; then
    if lsusb -d "${TARGET_VID}:${TARGET_PID}" >/dev/null 2>&1; then
      return 0
    fi
  fi
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

find_candidate_ports() {
  local found_ports=()

  # Search ttyUSB and ttyACM devices
  for tty in /sys/class/tty/ttyUSB* /sys/class/tty/ttyACM*; do
    [ -e "$tty" ] || continue
    local dev_node="/dev/$(basename "$tty")"
    [ -c "$dev_node" ] || continue

    # Method A: udevadm info
    if command -v udevadm >/dev/null 2>&1; then
      local vid pid
      vid="$(udevadm info -q property -n "$dev_node" 2>/dev/null | grep '^ID_VENDOR_ID=' | cut -d= -f2 || true)"
      pid="$(udevadm info -q property -n "$dev_node" 2>/dev/null | grep '^ID_MODEL_ID=' | cut -d= -f2 || true)"
      if [ "${vid,,}" = "${TARGET_VID,,}" ] && [ "${pid,,}" = "${TARGET_PID,,}" ]; then
        found_ports+=("$dev_node")
        continue
      fi
    fi

    # Method B: Traverse sysfs parents for idVendor / idProduct
    local cur="$tty/device"
    while [ "$cur" != "/sys" ] && [ "$cur" != "/" ] && [ -d "$cur" ]; do
      if [ -f "$cur/idVendor" ] && [ -f "$cur/idProduct" ]; then
        local v p
        v="$(cat "$cur/idVendor" 2>/dev/null || true)"
        p="$(cat "$cur/idProduct" 2>/dev/null || true)"
        if [ "${v,,}" = "${TARGET_VID,,}" ] && [ "${p,,}" = "${TARGET_PID,,}" ]; then
          found_ports+=("$dev_node")
          break
        fi
      fi
      cur="$(dirname "$cur")"
    done
  done

  # Method C: Check /dev/serial/by-id symlinks
  if [ -d "/dev/serial/by-id" ]; then
    for link in /dev/serial/by-id/*; do
      [ -L "$link" ] || continue
      local target
      target="$(readlink -f "$link")"
      if [[ "$link" =~ "FTDI" ]] || [[ "$link" =~ "usb-FTDI" ]] || [[ "$link" =~ "0403" ]]; then
        if [ -c "$target" ]; then
          found_ports+=("$target")
        fi
      fi
    done
  fi

  # Deduplicate ports
  local unique_ports=()
  for p in "${found_ports[@]}"; do
    local already=false
    for u in "${unique_ports[@]}"; do
      if [ "$u" = "$p" ]; then
        already=true
        break
      fi
    done
    if [ "$already" = "false" ]; then
      unique_ports+=("$p")
    fi
  done

  echo "${unique_ports[@]}"
}

# 5. Determine port
PORT=""

if [ -n "$PORT_OVERRIDE" ]; then
  PORT="$PORT_OVERRIDE"
  info "Using user-specified serial port: ${BOLD}$PORT${NC}"
else
  info "Scanning for Sync Board (FTDI ${TARGET_VID}:${TARGET_PID})..."

  detected=($(find_candidate_ports))

  if [ "${#detected[@]}" -eq 0 ]; then
    if check_usbtiny_present; then
      warn "Detected USBtiny ISP (1781:0c9f), but flash-program.sh flashes the sketch"
      warn "over the Sync Board's FTDI USB cable (${TARGET_VID}:${TARGET_PID})."
      warn "Do NOT flash the sketch through the USBtiny (it would erase the bootloader)."
    fi

    if check_ftdi_usb_present; then
      warn "FTDI device (${TARGET_VID}:${TARGET_PID}) is detected on USB, but no serial port node"
      warn "(/dev/ttyUSB*) was found. Check if 'brltty' is grabbing the port or run ./setup.sh."
    fi

    info "Sync Board not immediately detected. Waiting for device to be plugged in..."
    echo -e "  (Waiting up to ${TIMEOUT_SECS}s. Press ${BOLD}Ctrl+C${NC} to abort)"

    waited=0
    while [ "$waited" -lt "$TIMEOUT_SECS" ]; do
      sleep 1
      waited=$((waited + 1))
      detected=($(find_candidate_ports))
      if [ "${#detected[@]}" -gt 0 ]; then
        break
      fi
      echo -n "."
    done
    echo

    if [ "${#detected[@]}" -eq 0 ]; then
      error "Sync Board (FTDI ${TARGET_VID}:${TARGET_PID}) was not detected within ${TIMEOUT_SECS} seconds."
      echo
      echo -e "${BOLD}Troubleshooting checklist:${NC}"
      echo "  1. Connect the Sync Board to your computer with a USB cable."
      echo "  2. Run 'lsusb' to verify the FT232 serial chip (0403:6001) is detected."
      echo "  3. Check if 'dmesg | tail -n 20' shows /dev/ttyUSB* being registered."
      echo "  4. Ensure dialout permissions and udev rules are loaded: run ./setup.sh"
      echo "  5. Or specify the port manually: $0 /dev/ttyUSB0"
      exit 1
    fi
  fi

  if [ "${#detected[@]}" -eq 1 ]; then
    PORT="${detected[0]}"
    success "Autodetected Sync Board on ${BOLD}$PORT${NC} (FTDI ${TARGET_VID}:${TARGET_PID})"
  else
    warn "Multiple FTDI serial devices detected:"
    for i in "${!detected[@]}"; do
      echo "  $((i+1))) ${detected[$i]}"
    done

    if [ -t 0 ]; then
      read -r -p "Select port number [1-${#detected[@]}]: " choice
      idx=$((choice - 1))
      if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#detected[@]}" ]; then
        PORT="${detected[$idx]}"
      else
        error "Invalid selection."
        exit 1
      fi
    else
      PORT="${detected[0]}"
      warn "Non-interactive shell: defaulting to $PORT"
    fi
  fi
fi

# 6. Verify port permissions
if [ ! -r "$PORT" ] || [ ! -w "$PORT" ]; then
  warn "Port $PORT is not writable by current user ($USER)."
  warn "You may need to run: sudo chmod 666 $PORT"
  warn "or run: newgrp dialout (if you recently ran setup.sh)"
fi

# If -monitor was requested, open serial monitor directly without flashing
if [ "$MONITOR_ONLY" = "true" ]; then
  echo
  info "Opening serial monitor on ${BOLD}$PORT${NC} at 9600 baud (Press ${BOLD}Ctrl+C${NC} to exit)..."
  exec arduino-cli monitor -p "$PORT" -c baudrate=9600
fi

# 7. Compile and Upload
echo
echo -e "${BOLD}Build & Flash Configuration:${NC}"
echo "  - Board:      $BOARD"
echo "  - Port:       $PORT"
echo "  - Library:    $REPO_DIR"
echo "  - Sketch:     $SKETCH_DIR"
echo

info "Compiling and flashing sketch..."

if arduino-cli compile --upload \
  -b "$BOARD" \
  -p "$PORT" \
  --library "$REPO_DIR" \
  "$SKETCH_DIR"; then
  echo
  success "${BOLD}Successfully flashed Sync Board firmware!${NC}"
  echo
  echo "Default configuration:"
  echo "  - PWM Frequency: 60.00 Hz"
  echo "  - Duty Cycle:    ~50%"
  echo

  if [ "$FLASH_AND_MONITOR" = "true" ]; then
    info "Opening serial monitor at 9600 baud (Press Ctrl+C to exit)..."
    arduino-cli monitor -p "$PORT" -c baudrate=9600
  else
    echo -e "To verify and control over serial, run:"
    echo -e "  ${BOLD}$0 -monitor${NC} (or: arduino-cli monitor -p $PORT -c baudrate=9600)"
  fi
  exit 0
else
  flash_exit=$?
  echo
  error "Failed to flash sketch to $PORT (exit code $flash_exit)."
  echo
  echo -e "${BOLD}Common issues:${NC}"
  echo "  - Has the bootloader been burned? On a new board, you must first run:"
  echo -e "      ${BOLD}./flash-bootloader.sh${NC}"
  echo "  - Is another program (serial monitor, minicom, screen) using $PORT?"
  echo "  - Check cable connection and re-run."
  exit $flash_exit
fi
