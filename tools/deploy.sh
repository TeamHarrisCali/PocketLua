#!/bin/sh
# Builds LiveOS and sends it to the Cardputer over USB, so the SD card can stay
# in the device. It lands at /liveos/LiveOS.bin, ready to install from M5Launcher.
set -e
cd "$(dirname "$0")/.."
~/.local/bin/pio run
cp .pio/build/cardputer-adv/firmware.bin dist/LiveOS.bin
port=$(ls /dev/ttyACM* | head -1)
python3 tools/push.py --port "$port" send dist/LiveOS.bin LiveOS.bin
