#!/usr/bin/env python3
"""Talk to a PocketLua device over USB serial (Serial port on in Settings > USB;
eval also needs the Lua console). Standard library only.

  push.py send dist/PocketLua.bin PocketLua.bin    (large files, streamed to the card)
  push.py put userland/apps/foo.lua apps/foo.lua [--run foo]
  push.py get apps/foo.lua local_copy.lua
  push.py eval "sys.heap()"
  push.py run foo | reload | ls apps
"""
import argparse, base64, fcntl, os, struct, sys, termios, time, zlib


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    attrs = termios.tcgetattr(fd)
    attrs[0] = attrs[1] = attrs[3] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[4] = attrs[5] = termios.B115200
    attrs[6][termios.VMIN], attrs[6][termios.VTIME] = 0, 1
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    # the device only talks once DTR and RTS are both up; drop and raise them
    # so it sees a fresh connection (as monitor.py does)
    bits = struct.pack("I", termios.TIOCM_DTR | termios.TIOCM_RTS)
    fcntl.ioctl(fd, termios.TIOCMBIC, bits)
    time.sleep(0.3)
    fcntl.ioctl(fd, termios.TIOCMBIS, bits)
    time.sleep(0.3)
    # Builds before 2026-11-04 could keep a stray NUL in their input buffer,
    # which hid every later command; over 4 KB without a newline clears it.
    os.write(fd, b"x" * 4200)
    time.sleep(0.3)
    os.write(fd, b"\n")
    time.sleep(0.3)
    termios.tcflush(fd, termios.TCIFLUSH)
    return fd


def read_line(fd, timeout=3.0):
    buf, end = b"", time.time() + timeout
    while time.time() < end:
        c = os.read(fd, 1)
        if c == b"\n":
            return buf.decode(errors="replace").strip()
        buf += c
    raise TimeoutError("no reply from the device (is its USB serial port on?)")


def reply_line(fd, timeout=3.0):
    """The next line that is not a "# " log line (or the answer to the flush)."""
    while True:
        line = read_line(fd, timeout)
        if not line.startswith("#") and not line.startswith("Lua console is off"):
            return line


def send(fd, line):
    b = (line + "\n").encode()
    while b:
        b = b[os.write(fd, b):]


def fput(fd, local, remote):
    """Streams a file to the card (!fput): each line is acknowledged and the
    whole file is checked with a CRC, so a short write can't pass as "ok"."""
    data = open(local, "rb").read()
    send(fd, f"!fput {remote} {len(data)}")
    r = reply_line(fd)
    # the USB link can drop a byte of the reply ("rady"); errors are longer
    # messages, and the CRC at the end catches anything that went wrong
    if r != "ready" and not (3 <= len(r) <= 5 and r.endswith("dy")):
        sys.exit(r)
    # The device answers each line with "+" once it is on the card; wait for
    # that, since its USB serial drops bytes when its queue is full. Builds
    # without the "+" get smaller lines with a pause after each instead.
    step, acked, i = 1536, None, 0  # 1536 bytes = 2048 base64 characters
    t0, shown = time.time(), -1
    while i < len(data):
        send(fd, base64.b64encode(data[i:i + step]).decode())
        i += step
        if acked is not False:
            try:
                r = reply_line(fd, 1.0 if acked is None else 5.0)
            except TimeoutError:
                if acked:
                    sys.exit("\nthe device stopped answering")
                acked, step = False, 768
                print("(older build on the device: sending slowly)")
                continue
            if r != "+":
                sys.exit("\n" + r)
            acked = True
        else:
            time.sleep(0.03)
        pct = 100 * min(i, len(data)) // len(data)
        if pct != shown:
            print(f"\r{pct}%", end="", flush=True)
            shown = pct
    r = reply_line(fd, 30)
    expect = f"ok {remote} {len(data)} {zlib.crc32(data):x}"
    print(f"\r{r} ({time.time() - t0:.0f} s)")
    if r != expect:
        sys.exit("transfer check failed, expected: " + expect)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default="/dev/ttyACM0")
    ap.add_argument("cmd", choices=["send", "put", "get", "eval", "run", "reload", "ls"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--run", help="launch this app after put")
    a = ap.parse_args()
    fd = open_port(a.port)
    send(fd, "")  # flush any half-typed line

    if a.cmd == "send":
        fput(fd, *a.args)
    elif a.cmd == "put":
        # !begin/!data/!end built the file in one RAM string and wrote whatever
        # fitted: files over the largest free block (~20 KB) came out cut short
        # with an "ok". It streams through !fput like send now.
        local, remote = a.args
        fput(fd, local, remote)
        if a.run:
            send(fd, "!run " + a.run)
            print(reply_line(fd))
    elif a.cmd == "get":
        remote, local = a.args
        send(fd, "!get " + remote)
        out = b""
        while True:
            line = reply_line(fd)
            if line.startswith("!data "):
                out += base64.b64decode(line[6:])
            elif line == "!end":
                break
            else:
                sys.exit(line)
        open(local, "wb").write(out)
        print(f"saved {len(out)} bytes to {local}")
    elif a.cmd == "eval":
        send(fd, a.args[0])
        time.sleep(0.3)
        print(os.read(fd, 4096).decode(errors="replace"), end="")
    elif a.cmd == "ls":
        send(fd, "!ls " + (a.args[0] if a.args else ""))
        time.sleep(0.3)
        print(os.read(fd, 4096).decode(errors="replace"), end="")
    else:
        send(fd, "!" + a.cmd + (" " + a.args[0] if a.args else ""))
        print(reply_line(fd))


if __name__ == "__main__":
    main()
