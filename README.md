# ArduinoPWM: DWE OS Sync Board firmware

Firmware for the DWE OS **Sync Board**, an Arduino Uno–based board that outputs a PWM signal with a floating-point frequency. You set the frequency and duty cycle over USB serial.

The sketch is in [`dweos_arduino/`](dweos_arduino/). This repository is also the PWM library the sketch uses. For the original library documentation and credits, see [README-PWM-library.md](README-PWM-library.md).

Everything below runs from a terminal using [`arduino-cli`](https://arduino.github.io/arduino-cli/). The Arduino IDE isn't needed.

## What you need

- A **USBtiny ISP programmer** with a TC2030-IDC (Tag-Connect) cable. You only need this to burn the bootloader.
- A USB cable for the Sync Board (it connects through an FTDI USB-serial chip).
- `git`

## 1. Clone the repository

```bash
git clone https://github.com/DeepWaterExploration/ArduinoPWM.git
```

```bash
cd ArduinoPWM
```

Run all the commands below from inside this folder.

## 2. Install the command-line tools

### macOS

```bash
brew install arduino-cli
```

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | BINDIR=$HOME/.local/bin sh
```

Make sure `~/.local/bin` is on your `PATH`.

Give your user access to serial ports, then log out and back in:

```bash
sudo usermod -aG dialout $USER
```

Let your user access the USBtiny without `sudo`:

```bash
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="1781", ATTR{idProduct}=="0c9f", MODE="0666"' | sudo tee /etc/udev/rules.d/99-usbtiny.rules
```

```bash
sudo udevadm control --reload-rules && sudo udevadm trigger
```

### Windows (PowerShell)

```powershell
winget install ArduinoSA.CLI
```

Then close and reopen PowerShell so `arduino-cli` is on your `PATH`.

The USBtiny needs a USB driver on Windows. Plug it in, run [Zadig](https://zadig.akeo.ie/), select the USBtiny, and install the **libusb-win32** driver. The Sync Board's FTDI driver normally installs automatically through Windows Update.

### All platforms: install the AVR core

```bash
arduino-cli core update-index
```

```bash
arduino-cli core install arduino:avr
```

## 3. Burn the bootloader (once per board)

You only need to do this on a new board, or if the bootloader has been erased. It also erases any sketch on the board.

### Find the USBtiny (optional)

The USBtiny is found over USB automatically, so you don't need a port for it. If you want to confirm the computer sees it:

| Platform | Command |
|---|---|
| macOS | `system_profiler SPUSBDataType \| grep -i -A3 usbtiny` |
| Linux | `lsusb \| grep 1781:0c9f` |
| Windows | `Get-PnpDevice -PresentOnly \| Where-Object InstanceId -match 'VID_1781'` |

### Flash the bootloader

1. Plug the TC2030-IDC cable into the USBtiny.
2. Press the pogo head onto the Sync Board's TC2030 pads, with the red stripe on pin 1.
3. If the Sync Board is also powered over its own USB, remove the USBtiny's power jumper.
4. Hold the pogo head steady and run:

```bash
arduino-cli burn-bootloader -b arduino:avr:uno -P usbtinyisp
```

It prints nothing if it succeeds. If it fails with `initialization failed` or a signature error, re-seat the pogo head and run it again.

## 4. Flash the sketch

Unplug the USBtiny, then connect the Sync Board over USB.

### Find the Sync Board

```bash
arduino-cli board list
```

The Sync Board is listed as `Serial Port (USB)` with board name `Unknown`. Its port looks like this:

| Platform | Port |
|---|---|
| macOS | `/dev/cu.usbserial-XXXXXXXX` |
| Linux | `/dev/ttyUSB0` |
| Windows | `COM3` (any `COM` number) |

### Flash the sketch

Replace `<PORT>` with the Sync Board's port:

```bash
arduino-cli compile --upload -b arduino:avr:uno -p <PORT> --library . dweos_arduino
```

It prints the sketch size and nothing else if it succeeds.

> **Don't flash the sketch through the USBtiny** (`-P usbtinyisp` on an upload, or "Upload Using Programmer" in the IDE). That erases the bootloader, and you'd have to burn it again.

## 5. Check it

```bash
arduino-cli monitor -p <PORT> -c baudrate=9600
```

You should see `PWM frequency and initial duty cycle set.` (it may print twice when the monitor connects). The board starts at 60 Hz and about 50% duty cycle.

Send `frequency,duty` and press Enter. For example, `60,50`:

```
Set frequency to: 60.00 Hz, duty cycle to: 50%
```

Frequency is in Hz, between 1 and 2,000,000, and can have decimals. Duty cycle is a whole-number percentage from 0 to 100. Press Ctrl+C to exit the monitor.
