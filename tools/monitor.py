#!/usr/bin/env python3
"""Print the PocketLua device log from the USB serial port (stdlib only).

  monitor.py                 follow the log until Ctrl+C
  monitor.py --seconds 15    capture for 15 seconds, then exit

The device sends its log as lines starting with "# ", including everything
logged before you connected. Serial + log is on by default (Settings > USB).
"""
import argparse, fcntl, glob, os, struct, sys, termios, time


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default=None, help="default: first /dev/ttyACM*")
    ap.add_argument("--seconds", type=float, default=None)
    a = ap.parse_args()
    port = a.port or (sorted(glob.glob("/dev/ttyACM*")) or [None])[0]
    if not port:
        sys.exit("no /dev/ttyACM* device found (is the Cardputer plugged in and running PocketLua?)")
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
    attrs = termios.tcgetattr(fd)
    attrs[0] = attrs[1] = attrs[3] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL | termios.HUPCL  # drop DTR on close
    attrs[4] = attrs[5] = termios.B115200
    attrs[6][termios.VMIN], attrs[6][termios.VTIME] = 0, 2
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    # Drop and raise DTR/RTS: the device sees a fresh connection and resends its
    # log backlog (more reliable than the ENQ request alone).
    bits = struct.pack('I', termios.TIOCM_DTR | termios.TIOCM_RTS)
    fcntl.ioctl(fd, termios.TIOCMBIC, bits)
    time.sleep(0.5)
    fcntl.ioctl(fd, termios.TIOCMBIS, bits)
    time.sleep(0.2)
    os.write(fd, b"\x05")
    end = time.time() + a.seconds if a.seconds else None
    buf = b""
    print(f"reading {port} ...", file=sys.stderr)
    try:
        while end is None or time.time() < end:
            chunk = os.read(fd, 1024)
            if not chunk:
                continue
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                print(line.decode(errors="replace").rstrip("\r"), flush=True)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
