#!/usr/bin/env bash
# ==============================================================================
# monitor.sh - Autodetect Sync Board (FTDI 0403:6001) and open serial monitor
# ArduinoPWM / DWE OS Sync Board
# ==============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$REPO_DIR/flash-program.sh" -monitor "$@"
