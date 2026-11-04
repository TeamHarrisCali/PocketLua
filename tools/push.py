#!/usr/bin/env python3
"""Talk to a LiveOS device over USB serial (enable Serial port + Lua console in
Settings > USB first). Standard library only.

  push.py put userland/apps/foo.lua apps/foo.lua [--run foo]
  push.py get apps/foo.lua local_copy.lua
  push.py eval "sys.heap()"
  push.py run foo | reload | ls apps
"""
import argparse, base64, os, sys, termios, time


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    attrs = termios.tcgetattr(fd)
    attrs[0] = attrs[1] = attrs[3] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[4] = attrs[5] = termios.B115200
    attrs[6][termios.VMIN], attrs[6][termios.VTIME] = 0, 1
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return fd


def read_line(fd, timeout=3.0):
    buf, end = b"", time.time() + timeout
    while time.time() < end:
        c = os.read(fd, 1)
        if c == b"\n":
            return buf.decode(errors="replace").strip()
        buf += c
    raise TimeoutError("no reply from the device (is the Lua console on?)")


def send(fd, line):
    os.write(fd, (line + "\n").encode())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default="/dev/ttyACM0")
    ap.add_argument("cmd", choices=["put", "get", "eval", "run", "reload", "ls"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--run", help="launch this app after put")
    a = ap.parse_args()
    fd = open_port(a.port)
    send(fd, "")  # flush any half-typed line

    if a.cmd == "put":
        local, remote = a.args
        data = open(local, "rb").read()
        send(fd, "!begin " + remote)
        print(read_line(fd))
        for i in range(0, len(data), 768):
            send(fd, "!data " + base64.b64encode(data[i:i + 768]).decode())
            read_line(fd)
        send(fd, "!end")
        print(read_line(fd))
        if a.run:
            send(fd, "!run " + a.run)
            print(read_line(fd))
    elif a.cmd == "get":
        remote, local = a.args
        send(fd, "!get " + remote)
        out = b""
        while True:
            line = read_line(fd)
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
        print(read_line(fd))


if __name__ == "__main__":
    main()
