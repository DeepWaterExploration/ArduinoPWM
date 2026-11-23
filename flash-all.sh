#!/usr/bin/env bash
# ==============================================================================
# flash-all.sh - Automatically burn bootloader and flash sketch in one run
# Fails immediately if USBtiny (1781:0c9f) or Sync Board (FTDI 0403:6001) is missing
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
USBTINY_VID="1781"
USBTINY_PID="0c9f"
FTDI_VID="0403"
FTDI_PID="6001"
MONITOR_ONLY=false
FLASH_AND_MONITOR=false
PORT_OVERRIDE=""

# Paths
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKETCH_DIR="$REPO_DIR/dweos_arduino"

usage() {
  cat << EOF
Usage: $0 [OPTIONS] [PORT]

Fully automated flashing for DWE OS Sync Board:
  1. Verifies both USBtiny (1781:0c9f) and Sync Board FTDI (0403:6001) are connected.
     Fails immediately if either device is missing.
  2. Burns the Arduino Uno bootloader via USBtiny.
  3. Compiles and uploads the sketch via Sync Board FTDI serial port.

Options:
  -p, --port PORT          Specify serial port manually (e.g. /dev/ttyUSB0)
  -b, --board FQBN         Specify board FQBN (default: arduino:avr:uno)
  -P, --programmer P       Specify programmer (default: usbtinyisp)
  -m, --monitor, -monitor  Open serial monitor (9600 baud) directly without flashing
  --flash-and-monitor      Flash all and then open serial monitor
  -h, --help               Show this help message

Examples:
  $0                       # Check connections, burn bootloader, and flash sketch
  $0 -monitor              # Open serial monitor directly without flashing
  $0 /dev/ttyUSB0          # Flash all using a specific serial port
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
    -P|--programmer)
      PROGRAMMER="$2"
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
echo -e "${BOLD}   ArduinoPWM / DWE OS Full Automated Flasher     ${NC}"
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
      error "arduino:avr core is not installed. Please run ./setup.sh first."
      exit 1
    fi
  fi
fi

# 4. Device detection functions
check_usbtiny() {
  # Check via lsusb
  if command -v lsusb >/dev/null 2>&1; then
    if lsusb -d "${USBTINY_VID}:${USBTINY_PID}" >/dev/null 2>&1; then
      return 0
    fi
    if lsusb 2>/dev/null | grep -qiE "${USBTINY_VID}:${USBTINY_PID}|usbtiny"; then
      return 0
    fi
  fi

  # Check via sysfs
  for d in /sys/bus/usb/devices/*; do
    if [ -f "$d/idVendor" ] && [ -f "$d/idProduct" ]; then
      local v p
      v="$(cat "$d/idVendor" 2>/dev/null || true)"
      p="$(cat "$d/idProduct" 2>/dev/null || true)"
      if [ "${v,,}" = "${USBTINY_VID,,}" ] && [ "${p,,}" = "${USBTINY_PID,,}" ]; then
        return 0
      fi
    fi
  done

  return 1
}

find_ftdi_ports() {
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
      if [ "${vid,,}" = "${FTDI_VID,,}" ] && [ "${pid,,}" = "${FTDI_PID,,}" ]; then
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
        if [ "${v,,}" = "${FTDI_VID,,}" ] && [ "${p,,}" = "${FTDI_PID,,}" ]; then
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

# If -monitor was requested, only detect the Sync Board and open serial monitor directly
if [ "$MONITOR_ONLY" = "true" ]; then
  info "Locating Sync Board for serial monitor..."
  PORT=""
  if [ -n "$PORT_OVERRIDE" ]; then
    PORT="$PORT_OVERRIDE"
  else
    ftdi_ports=($(find_ftdi_ports))
    if [ "${#ftdi_ports[@]}" -gt 0 ]; then
      PORT="${ftdi_ports[0]}"
    else
      error "Sync Board (FTDI ${FTDI_VID}:${FTDI_PID}) is NOT connected or no serial port (/dev/ttyUSB*) was found!"
      echo "  -> Please connect the Sync Board to USB via its FTDI cable."
      exit 1
    fi
  fi
  success "Sync Board detected on ${BOLD}$PORT${NC}"
  echo
  info "Opening serial monitor at 9600 baud (Press ${BOLD}Ctrl+C${NC} to exit)..."
  exec arduino-cli monitor -p "$PORT" -c baudrate=9600
fi

# 5. Check hardware connections (FAIL IMMEDIATELY IF MISSING)
info "Verifying hardware connections..."
MISSING_HARDWARE=false

# Check USBtiny
if check_usbtiny; then
  if command -v lsusb >/dev/null 2>&1; then
    USBTINY_INFO="$(lsusb -d "${USBTINY_VID}:${USBTINY_PID}" 2>/dev/null || true)"
    success "USBtiny ISP programmer detected (${USBTINY_VID}:${USBTINY_PID}): ${USBTINY_INFO:-Connected}"
  else
    success "USBtiny ISP programmer detected (${USBTINY_VID}:${USBTINY_PID})"
  fi
else
  error "USBtiny ISP programmer (${USBTINY_VID}:${USBTINY_PID}) is NOT connected!"
  echo "  -> Please connect the USBtiny ISP programmer to USB."
  echo "  -> Ensure the TC2030 pogo pins are held firmly onto the Sync Board pads (red stripe on pin 1)."
  MISSING_HARDWARE=true
fi

# Check FTDI Sync Board
PORT=""
if [ -n "$PORT_OVERRIDE" ]; then
  if [ -c "$PORT_OVERRIDE" ]; then
    PORT="$PORT_OVERRIDE"
    success "Using specified Sync Board serial port: $PORT"
  else
    error "Specified serial port does not exist: $PORT_OVERRIDE"
    MISSING_HARDWARE=true
  fi
else
  ftdi_ports=($(find_ftdi_ports))
  if [ "${#ftdi_ports[@]}" -gt 0 ]; then
    PORT="${ftdi_ports[0]}"
    if [ "${#ftdi_ports[@]}" -eq 1 ]; then
      success "Sync Board detected on ${PORT} (FTDI ${FTDI_VID}:${FTDI_PID})"
    else
      warn "Multiple FTDI devices detected: ${ftdi_ports[*]}"
      info "Auto-selecting first device: $PORT"
    fi
  else
    error "Sync Board (FTDI ${FTDI_VID}:${FTDI_PID}) is NOT connected or no serial port (/dev/ttyUSB*) was found!"
    echo "  -> Please connect the Sync Board to USB via its FTDI cable."
    echo "  -> If device is plugged in, check for 'brltty' conflict or run ./setup.sh."
    MISSING_HARDWARE=true
  fi
fi

# Stop execution if any required hardware is missing
if [ "$MISSING_HARDWARE" = "true" ]; then
  echo
  error "Hardware connection check failed. Both the USBtiny ISP and Sync Board FTDI must be connected."
  exit 1
fi

# Verify port permissions
if [ ! -r "$PORT" ] || [ ! -w "$PORT" ]; then
  warn "Port $PORT is not writable by current user ($USER)."
  warn "You may need to run: sudo chmod 666 $PORT or newgrp dialout"
fi

echo
echo -e "${BOLD}Hardware Configuration Verified:${NC}"
echo "  - Board:             $BOARD"
echo "  - Bootloader via:    $PROGRAMMER (USBtiny ${USBTINY_VID}:${USBTINY_PID})"
echo "  - Sketch via:        $PORT (FTDI ${FTDI_VID}:${FTDI_PID})"
echo "  - Library path:      $REPO_DIR"
echo "  - Sketch path:       $SKETCH_DIR"
echo
warn "Reminder: Because the Sync Board is powered over its USB connection,"
warn "ensure the USBtiny's power jumper is REMOVED to avoid power conflicts."
echo

# 6. Step 1: Burn Bootloader
info "${BOLD}[Step 1/2] Burning bootloader...${NC}"
info "Command: arduino-cli burn-bootloader -b $BOARD -P $PROGRAMMER"

if arduino-cli burn-bootloader -b "$BOARD" -P "$PROGRAMMER"; then
  success "Bootloader burned successfully!"
else
  burn_exit=$?
  echo
  error "Step 1 failed: Could not burn bootloader (exit code $burn_exit)."
  echo -e "${BOLD}Troubleshooting:${NC}"
  echo "  - Ensure TC2030 pogo pins are held firmly on pads (red stripe on pin 1)."
  echo "  - Check that the USBtiny power jumper is removed."
  exit $burn_exit
fi

# Allow MCU and serial bus a moment to reset after bootloader burn
info "Waiting 2 seconds for board initialization..."
sleep 2

# 7. Step 2: Compile & Flash Sketch
info "${BOLD}[Step 2/2] Compiling and flashing sketch...${NC}"
info "Command: arduino-cli compile --upload -b $BOARD -p $PORT --library $REPO_DIR $SKETCH_DIR"

if arduino-cli compile --upload \
  -b "$BOARD" \
  -p "$PORT" \
  --library "$REPO_DIR" \
  "$SKETCH_DIR"; then
  success "Sketch compiled and uploaded successfully!"
else
  flash_exit=$?
  echo
  error "Step 2 failed: Could not upload sketch to $PORT (exit code $flash_exit)."
  echo -e "${BOLD}Troubleshooting:${NC}"
  echo "  - Check USB cable to Sync Board."
  echo "  - Ensure no other program (serial monitor, minicom) is using $PORT."
  exit $flash_exit
fi

echo
echo -e "${GREEN}${BOLD}====================================================${NC}"
echo -e "${GREEN}${BOLD}   All Flashing Completed Successfully!           ${NC}"
echo -e "${GREEN}${BOLD}====================================================${NC}"
echo "  - Board:          $BOARD"
echo "  - Port:           $PORT"
echo "  - PWM Frequency:  60.00 Hz"
echo "  - Duty Cycle:     ~50%"
echo

if [ "$FLASH_AND_MONITOR" = "true" ]; then
  info "Opening serial monitor at 9600 baud (Press Ctrl+C to exit)..."
  arduino-cli monitor -p "$PORT" -c baudrate=9600
else
  echo -e "To verify and control over serial, run:"
  echo -e "  ${BOLD}$0 -monitor${NC} (or: arduino-cli monitor -p $PORT -c baudrate=9600)"
fi
