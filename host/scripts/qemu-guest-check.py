#!/usr/bin/env python3
"""Destructive checks inside the owned disposable QEMU guest only.

Use verify-login-qemu.py on the Mac, not this program on a real Ubuntu machine.
The controller supplies the per-VM marker and manages cold boots between stages.
"""

import argparse
import ctypes
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import socket
import struct
import subprocess
import time


SOURCE = Path("/home/vmadmin/source")
OUT = Path("/var/tmp/sharedesk-checks")
GDM = Path("/etc/gdm3/custom.conf")
UNIT = "sharedesk-host.service"
ADDRESS = "100.100.100.100"
OS_PASSWORD = "Sharedesk-VM-Only-2026"
VNC_PASSWORD = b"sdvmtest"
KEYS = {"Enter": 0xff0d, "Escape": 0xff1b, "F2": 0xffbf,
        "Alt": 0xffe9, "Control": 0xffe3, "Shift": 0xffe1}


def run(*args, check=True, timeout=30, **kwargs):
    return subprocess.run(args, check=check, timeout=timeout, text=True,
                          capture_output=True, **kwargs)


def output(*args):
    return run(*args).stdout.strip()


def require(condition, message):
    # Keep checks enabled even when Python is invoked with -O.
    if not condition:
        raise RuntimeError(message)


def passed(message, **details):
    print("PASS: " + message, flush=True)
    with (OUT / "results.jsonl").open("a") as stream:
        stream.write(json.dumps({"check": message, **details}) + "\n")


def wait_for(condition, description, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.2)
    raise RuntimeError("Timed out waiting for " + description)


def properties(*args):
    return dict(line.split("=", 1) for line in output(*args).splitlines() if "=" in line)


def seat():
    session = output("loginctl", "show-seat", "seat0", "-p", "ActiveSession", "--value")
    if not session:
        return {}
    result = properties("loginctl", "show-session", session, "-p", "Name", "-p", "User",
                        "-p", "Class", "-p", "Type", "-p", "LockedHint", "-p", "Service")
    result["id"] = session
    return result


def parent_pid():
    return int(output("systemctl", "show", UNIT, "-p", "MainPID", "--value"))


def children(parent):
    path = Path(f"/proc/{parent}/task/{parent}/children")
    return [int(pid) for pid in path.read_text().split()] if path.exists() else []


def ready(name):
    state = seat()
    return state.get("Name") == name and state.get("Type") == "x11" and bool(children(parent_pid()))


def inspect_worker(name):
    wait_for(lambda: ready(name), name + " Xorg worker")
    state = seat()
    parent = parent_pid()
    workers = children(parent)
    require(len(workers) == 1, "Expected exactly one host worker")
    pid = workers[0]
    status = dict(line.split(":", 1) for line in Path(f"/proc/{pid}/status").read_text().splitlines())
    uid = pwd.getpwnam(name).pw_uid
    require(status["Uid"].split() == [str(uid)] * 4, "Worker did not drop all user IDs")
    require(int(status["CapEff"], 16) == int(status["CapPrm"], 16) == 0, "Worker retained capabilities")
    require(status["NoNewPrivs"].strip() == "1", "Worker may acquire privileges")
    args = [part.decode() for part in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0") if part]
    require(("--clipboard" in args) == (name == "deskuser"), "Wrong clipboard policy")
    require(args[args.index("--listen") + 1] == ADDRESS, "Wrong listener address")
    xorg = int(args[args.index("--x11-server-pid") + 1])
    cgroup = Path(f"/proc/{xorg}/cgroup").read_text()
    require(f"/session-{state['id']}.scope" in cgroup, "Xorg is outside the active logind session")
    require(os.readlink(f"/proc/{pid}/ns/ipc") == os.readlink(f"/proc/{xorg}/ns/ipc"), "Wrong IPC namespace")
    for descriptor in Path(f"/proc/{pid}/fd").iterdir():
        require(os.readlink(descriptor) != "/etc/sharedesk/vnc-password", "Password descriptor was not closed")
    unit = properties("systemctl", "show", UNIT, "-p", "ProtectSystem", "-p", "NoNewPrivileges",
                      "-p", "PrivateIPC", "-p", "PrivateTmp", "-p", "KillMode")
    require(unit == {"ProtectSystem": "strict", "NoNewPrivileges": "yes", "PrivateIPC": "no",
                     "PrivateTmp": "no", "KillMode": "mixed"}, "Unexpected systemd restrictions")
    passed("Unprivileged " + name + " worker under real systemd/logind", session=state,
           parent=parent, worker=pid, xorg=xorg, args=args, unit=unit)
    return pid


def no_listener():
    require(not children(parent_pid()), "Unsupported session still has a worker")
    require("LISTEN" not in output("ss", "-ltn", "sport = :5901"), "VNC listener survived")
    try:
        connection = socket.create_connection((ADDRESS, 5901), timeout=2)
    except ConnectionRefusedError:
        return
    connection.close()
    raise RuntimeError("VNC unexpectedly accepted a connection")


class Peer:
    """Small synchronous RFB 3.8 fixture: raw pixels and bounded complete input."""

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.connection.close()

    def __init__(self):
        from Cryptodome.Cipher import DES
        self.connection = socket.create_connection((ADDRESS, 5901), timeout=5)
        try:
            require(self.read(12) == b"RFB 003.008\n", "Unexpected RFB version")
            self.connection.sendall(b"RFB 003.008\n")
            count = self.read(1)[0]
            require(count > 0 and 2 in self.read(count), "VNC password authentication unavailable")
            self.connection.sendall(b"\x02")
            key = bytes(int(f"{byte:08b}"[::-1], 2) for byte in VNC_PASSWORD)
            self.connection.sendall(DES.new(key, DES.MODE_ECB).encrypt(self.read(16)))
            require(self.read(4) == b"\0\0\0\0", "VNC authentication failed")
            self.connection.sendall(b"\x01")
            header = self.read(24)
            self.width, self.height = struct.unpack("!HH", header[:4])
            name_size = struct.unpack("!I", header[20:])[0]
            require(name_size < 4096, "Oversized desktop name")
            self.read(name_size)
            require((self.width, self.height) == (1280, 800), "GUI fixture needs a 1280x800 framebuffer")
            pixel_format = struct.pack("!BBBBHHHBBBxxx", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
            self.connection.sendall(b"\x00\0\0\0" + pixel_format)
            self.connection.sendall(struct.pack("!BBHi", 2, 0, 1, 0))  # Raw only.
        except BaseException:
            self.connection.close()
            raise

    def read(self, count):
        data = bytearray()
        while len(data) < count:
            chunk = self.connection.recv(count - len(data))
            if not chunk:
                raise RuntimeError("Unexpected VNC disconnect")
            data.extend(chunk)
        return bytes(data)

    def screenshot(self, name):
        from PIL import Image
        self.connection.sendall(struct.pack("!BBHHHH", 3, 0, 0, 0, self.width, self.height))
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            kind = self.read(1)[0]
            if kind == 2:  # Bell.
                continue
            if kind == 3:  # Classic clipboard; never log its contents.
                size = struct.unpack("!I", self.read(7)[3:])[0]
                require(size <= 1 << 20, "Oversized clipboard message")
                self.read(size)
                continue
            require(kind == 0, "Unexpected RFB message")
            count = struct.unpack("!H", self.read(3)[1:])[0]
            image = Image.new("RGB", (self.width, self.height))
            pixels = 0
            for _ in range(count):
                x, y, width, height, encoding = struct.unpack("!HHHHi", self.read(12))
                require(encoding == 0 and x + width <= self.width and y + height <= self.height,
                        "Unexpected rectangle encoding or bounds")
                data = self.read(width * height * 4)
                rectangle = Image.frombytes("RGB", (width, height), data, "raw", "BGRX")
                image.paste(rectangle, (x, y))
                pixels += width * height
            if pixels:
                image.save(OUT / (name + ".png"))
                require(pixels == self.width * self.height, "Full framebuffer request was incomplete")
                return
        raise RuntimeError("Framebuffer deadline expired")

    def key_event(self, key, down):
        code = KEYS.get(key, ord(key) if len(key) == 1 else 0)
        require(code != 0, "Unknown test key")
        self.connection.sendall(struct.pack("!BBHI", 4, int(down), 0, code))
        time.sleep(0.05)

    def key(self, key):
        self.key_event(key, True)
        self.key_event(key, False)

    def text(self, text):
        for character in text:
            self.key("Enter" if character == "\n" else character)

    def click(self, x, y):
        self.connection.sendall(struct.pack("!BBHH", 5, 1, x, y))
        time.sleep(0.08)
        self.connection.sendall(struct.pack("!BBHH", 5, 0, x, y))

    def command(self, command):
        # Pace the shortcut for GNOME's asynchronous keyboard-grab handling.
        # This checks functional handoff, not rapid-input throughput or latency.
        for key, down in (("Alt", True), ("F2", True), ("F2", False), ("Alt", False)):
            self.key_event(key, down)
            time.sleep(0.15)
        time.sleep(2)
        self.screenshot("run-dialog")
        self.text(command + "\n")
        time.sleep(3)

    def clipboard(self, text):
        data = text.encode("ascii")
        self.connection.sendall(struct.pack("!BxxxI", 6, len(data)) + data)
        time.sleep(1)

    def disconnected(self):
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            try:
                if not self.connection.recv(65536):
                    return
            except ConnectionResetError:
                return
            except socket.timeout:
                continue
        raise RuntimeError("Session handoff did not close VNC")

    def login(self, username):
        # Standard Jammy GDM, two visible users, fixed VM display size. Failures
        # retain screenshots for inspection instead of guessing new coordinates.
        self.key("Escape")
        time.sleep(1)
        self.screenshot("before-login-" + username)
        self.click(500, 486)  # Not listed? (vmadmin is a hidden system account.)
        time.sleep(1)
        self.text(username + "\n")
        time.sleep(1)
        self.text(OS_PASSWORD + "\n")
        self.disconnected()


def clipboard_environment():
    worker = children(parent_pid())[0]
    variables = dict(item.split(b"=", 1) for item in Path(f"/proc/{worker}/environ").read_bytes().split(b"\0") if item)
    return {**os.environ, "DISPLAY": variables[b"DISPLAY"].decode(),
            "XAUTHORITY": variables[b"XAUTHORITY"].decode()}


def clipboard_owner(environment):
    # Xlib reads only this disposable guest's authority file. The production
    # supervisor still does not read authority cookies or open an X display.
    os.environ.update({name: environment[name] for name in ("DISPLAY", "XAUTHORITY")})
    library = ctypes.CDLL(ctypes.util.find_library("X11"))
    library.XOpenDisplay.argtypes = [ctypes.c_char_p]
    library.XOpenDisplay.restype = ctypes.c_void_p
    library.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    library.XInternAtom.restype = ctypes.c_ulong
    library.XGetSelectionOwner.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    library.XGetSelectionOwner.restype = ctypes.c_ulong
    library.XCloseDisplay.argtypes = [ctypes.c_void_p]
    display = library.XOpenDisplay(None)
    require(display, "Cannot inspect guest clipboard")
    try:
        return library.XGetSelectionOwner(display, library.XInternAtom(display, b"CLIPBOARD", 0))
    finally:
        library.XCloseDisplay(display)


def installer(*extra, check=True):
    args = ["python3", str(SOURCE / "host/scripts/install-login-service.py")]
    if "--remove" not in extra:
        args += ["--user", "deskuser", "--password-file", "/home/deskuser/.sharedesk/vnc-password",
                 "--port", "5901", "--fps", "30", "--stats", "--clipboard"]
    result = run(*args, *extra, check=check)
    with (OUT / "installer.log").open("a") as stream:
        stream.write(result.stdout + result.stderr)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=["setup", "install", "sessions", "return", "lifecycle", "wayland", "repeat", "removed"])
    parser.add_argument("--fixture", required=True)
    args = parser.parse_args()
    require(os.geteuid() == 0, "Guest checks require root inside the disposable VM")
    require(Path("/etc/sharedesk-qemu-fixture").read_text().strip() == args.fixture,
            "Not the controller's disposable VM")
    require(output("systemd-detect-virt", "--vm") == "qemu", "Not a QEMU virtual machine")
    OUT.mkdir(mode=0o700, exist_ok=True)

    if args.stage == "setup":
        packages = ("ubuntu-desktop-minimal gdm3 xorg xterm xclip dbus-x11 build-essential cmake "
                    "pkg-config patch zlib1g-dev libjpeg-dev libpng-dev libx11-dev libxtst-dev "
                    "libxfixes-dev libxext-dev libxdamage-dev libsystemd-dev python3-pil python3-pycryptodome")
        environment = {**os.environ, "DEBIAN_FRONTEND": "noninteractive"}
        run("debconf-set-selections", input="gdm3 shared/default-x-display-manager select gdm3\n"
            "keyboard-configuration keyboard-configuration/layoutcode string us\n")
        for command in (["apt-get", "update"], ["apt-get", "-y", "--no-install-recommends",
                         "-o", "DPkg::Lock::Timeout=300", "install", *packages.split()]):
            with (OUT / "packages.log").open("a") as log:
                subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT,
                               check=True, timeout=1800)
        Path("/etc/X11/default-display-manager.debconf-update").touch()
        run("dpkg-reconfigure", "-f", "noninteractive", "gdm3", env=environment, timeout=90)
        require(Path("/etc/X11/default-display-manager").read_text().strip() == "/usr/sbin/gdm3",
                "GDM package configuration failed")
        for name, label in (("deskuser", "Sharedesk Test User"), ("otheruser", "Other Test User")):
            run("useradd", "--create-home", "--shell", "/bin/bash", "--comment", label, name)
            run("chpasswd", input=f"{name}:{OS_PASSWORD}\n")
            user = pwd.getpwnam(name)
            config = Path(user.pw_dir) / ".config"
            config.mkdir(mode=0o700)
            marker = config / "gnome-initial-setup-done"
            marker.write_text("yes\n")
            os.chown(config, user.pw_uid, user.pw_gid)
            os.chown(marker, user.pw_uid, user.pw_gid)
        Path("/var/lib/AccountsService/users/vmadmin").write_text("[User]\nSystemAccount=true\n")
        password = Path("/home/deskuser/.sharedesk/vnc-password")
        password.parent.mkdir(mode=0o700)
        password.write_bytes(VNC_PASSWORD + b"\n")
        password.chmod(0o600)
        user = pwd.getpwnam("deskuser")
        os.chown(password.parent, user.pw_uid, user.pw_gid)
        os.chown(password, user.pw_uid, user.pw_gid)
        Path("/etc/systemd/system/sharedesk-test-network.service").write_text(
            "[Unit]\nDescription=Disposable Sharedesk network fixture (not Tailscale)\n"
            "[Service]\nType=oneshot\nRemainAfterExit=yes\n"
            "ExecStart=/usr/sbin/ip link add tailscale0 type dummy\n"
            f"ExecStart=/usr/sbin/ip address add {ADDRESS}/32 dev tailscale0\n"
            "ExecStart=/usr/sbin/ip link set tailscale0 up\n"
            "ExecStop=/usr/sbin/ip link delete tailscale0\n"
            "[Install]\nWantedBy=multi-user.target\n")
        run("systemctl", "daemon-reload")
        run("systemctl", "enable", "sharedesk-test-network.service")
        run("systemctl", "set-default", "graphical.target")
        (OUT / "versions.txt").write_text(output("uname", "-a") + "\n" + output(
            "dpkg-query", "-W", "gdm3", "systemd", "xserver-xorg-core", "ubuntu-desktop-minimal"))
        passed("Guest desktop and dummy network provisioned; no Tailscale node enrolled")
        return

    if args.stage == "install":
        state = seat()
        require(state.get("Name") == "gdm" and state.get("Type") == "wayland", "Baseline is not a Wayland greeter")
        before = GDM.read_bytes()
        gdm_pid = output("systemctl", "show", "gdm", "-p", "MainPID", "--value")
        refusal = installer(check=False)
        require(refusal.returncode != 0 and "--configure-gdm-xorg" in refusal.stderr,
                "Installer did not require explicit Xorg consent")
        require(GDM.read_bytes() == before, "Refused installation changed GDM")
        installer("--configure-gdm-xorg")
        require(parent_pid() == 0, "Installer started the service")
        require(output("systemctl", "show", "gdm", "-p", "MainPID", "--value") == gdm_pid,
                "Installer restarted GDM")
        require(output("systemctl", "is-enabled", UNIT) == "enabled", "Service is not enabled")
        passed("Installation is consent-gated and enable-only; existing GDM stays running")

    elif args.stage == "sessions":
        inspect_worker("gdm")
        with Peer() as peer:
            peer.screenshot("greeter")
            environment = clipboard_environment()
            require(clipboard_owner(environment) == 0, "Unexpected initial GDM clipboard owner")
            peer.clipboard("must-not-import-at-gdm")
            require(clipboard_owner(environment) == 0, "GDM imported VNC clipboard text")
            passed("Greeter clipboard stays disabled")
            peer.login("deskuser")
        worker = inspect_worker("deskuser")
        time.sleep(5)
        with Peer() as peer:
            peer.screenshot("desktop")
            peer.command("xterm")
            peer.screenshot("after-xterm-launch")
            marker = Path("/home/deskuser/vnc-input-confirmed")
            peer.text("printf vnc-input-ok > /home/deskuser/vnc-input-confirmed\n")
            time.sleep(2)
            peer.screenshot("after-input-command")
            wait_for(lambda: marker.exists() and marker.read_text() == "vnc-input-ok", "VNC shell input")
            peer.screenshot("desktop-input")
            peer.clipboard("desktop-clipboard-fixture")
            text = run("xclip", "-o", "-selection", "clipboard", env=clipboard_environment()).stdout
            require(text == "desktop-clipboard-fixture", "Desktop clipboard mismatch")
            passed("VNC password login, desktop reconnect, keyboard and exact clipboard transfer")
            session = seat()["id"]
            run("loginctl", "lock-session", session)
            wait_for(lambda: seat().get("LockedHint") == "yes", "locked desktop")
            peer.screenshot("locked")
            peer.key("Escape")
            time.sleep(2)
            peer.text(OS_PASSWORD + "\n")
            wait_for(lambda: seat().get("LockedHint") == "no", "password unlock")
            require(children(parent_pid()) == [worker], "Lock/unlock changed worker")
            peer.screenshot("unlocked")
            passed("Lock and password unlock preserve the worker and VNC connection")
            peer.command("gdmflexiserver")
            peer.disconnected()
        inspect_worker("gdm")
        time.sleep(3)
        with Peer() as peer:
            peer.login("otheruser")
        wait_for(lambda: seat().get("Name") == "otheruser" and not children(parent_pid()), "excluded other user")
        no_listener()
        passed("Switching to the other account closes VNC and leaves no listener", session=seat())

    elif args.stage == "return":
        user = pwd.getpwnam("otheruser")
        run("runuser", "-u", "otheruser", "--", "env", f"XDG_RUNTIME_DIR=/run/user/{user.pw_uid}",
            f"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{user.pw_uid}/bus",
            "gnome-session-quit", "--logout", "--no-prompt")
        inspect_worker("gdm")
        time.sleep(3)
        with Peer() as peer:
            peer.login("deskuser")
        inspect_worker("deskuser")
        time.sleep(3)
        with Peer() as peer:
            peer.screenshot("returned-desktop")
        passed("Other-user logout returns to GDM; configured desktop resumes after password login")

    elif args.stage == "lifecycle":
        worker = inspect_worker("deskuser")
        parent = parent_pid()
        paths = [GDM, Path("/etc/systemd/system") / UNIT, Path("/usr/local/libexec/sharedesk/sharedesk-host")]
        before = [path.read_bytes() for path in paths]
        with Peer() as peer:
            peer.screenshot("before-update-refusal")
            refusal = installer(check=False)
            require(refusal.returncode != 0 and "active or transitioning" in refusal.stderr, "Active update not refused")
            require([path.read_bytes() for path in paths] == before and parent_pid() == parent
                    and children(parent) == [worker], "Active update changed state")
            peer.screenshot("after-update-refusal")
            passed("Active update refused without changing files, processes or the VNC connection")
            run("ip", "link", "set", "tailscale0", "down")
            try:
                wait_for(lambda: not children(parent), "worker stop after interface loss")
                peer.disconnected()
                no_listener()
            finally:
                run("ip", "link", "set", "tailscale0", "up")
        inspect_worker("deskuser")
        with Peer() as peer:
            peer.screenshot("network-restored")
            passed("Simulated Tailscale-interface loss closes VNC; explicit reconnect works after recovery")
            worker = children(parent)[0]
            run("kill", "-STOP", str(worker))  # No held keys or buttons.
            started = time.monotonic()
            run("systemctl", "stop", UNIT, timeout=8)
            elapsed = time.monotonic() - started
            peer.disconnected()
        require(1.8 < elapsed < 6 and parent_pid() == 0 and not Path(f"/proc/{worker}").exists(),
                "Paused worker was not reaped within the bounded grace period")
        passed("Real systemd stop reaps a paused worker", elapsed_seconds=elapsed)
        run("systemctl", "start", UNIT)
        inspect_worker("deskuser")
        with Peer() as peer:
            peer.screenshot("explicit-restart")
            peer.command("gnome-session-quit --logout --no-prompt")
            peer.disconnected()
        inspect_worker("gdm")
        passed("Explicit service restart and configured-user logout return to a working greeter")
        original = GDM.read_bytes()
        (OUT / "gdm-installed.conf").write_bytes(original)
        changed, count = re.subn(rb"(?m)^WaylandEnable=false$", b"WaylandEnable=true", original)
        require(count == 1, "Cannot make the temporary Wayland fixture change")
        GDM.write_bytes(changed)

    elif args.stage == "wayland":
        wait_for(lambda: seat().get("Type") == "wayland", "Wayland greeter")
        require(seat().get("Name") == "gdm" and parent_pid() > 0, "Supervisor not running at Wayland greeter")
        no_listener()
        passed("Real Wayland greeter is not shared", session=seat())
        run("systemctl", "stop", UNIT)
        changed = GDM.read_bytes()
        refusal = installer("--remove", "--restore-gdm", check=False)
        require(refusal.returncode != 0 and "GDM configuration changed" in refusal.stderr,
                "Restoration overwrote an administrator change")
        require(GDM.read_bytes() == changed and (Path("/etc/systemd/system") / UNIT).exists(),
                "Refused removal changed files")
        GDM.write_bytes((OUT / "gdm-installed.conf").read_bytes())
        passed("GDM fingerprint prevents restoring over later changes")

    elif args.stage == "repeat":
        inspect_worker("gdm")
        with Peer() as peer:
            peer.screenshot("repeated-cold-boot")
        original = Path("/etc/sharedesk/gdm-custom.conf.before-sharedesk").read_bytes()
        gdm_pid = output("systemctl", "show", "gdm", "-p", "MainPID", "--value")
        run("systemctl", "stop", UNIT)
        installer("--remove", "--restore-gdm")
        require(GDM.read_bytes() == original, "GDM restoration was not byte-exact")
        require(output("systemctl", "show", "gdm", "-p", "MainPID", "--value") == gdm_pid,
                "Removal restarted GDM")
        for path in (Path("/etc/systemd/system") / UNIT,
                     Path("/usr/local/libexec/sharedesk/sharedesk-host"),
                     Path("/usr/local/libexec/sharedesk/sharedesk-login-service")):
            require(not path.exists(), "Removal left " + str(path))
        password = Path("/etc/sharedesk/vnc-password")
        require(password.read_bytes() == VNC_PASSWORD + b"\n" and password.stat().st_mode & 0o777 == 0o600,
                "Removal did not retain the private password correctly")
        no_listener()
        passed("Repeated cold boot works; removal restores GDM without restarting it",
               original_gdm_sha256=hashlib.sha256(original).hexdigest())

    elif args.stage == "removed":
        wait_for(lambda: seat().get("Type") == "wayland", "restored Wayland greeter")
        require(output("systemctl", "show", UNIT, "-p", "LoadState", "--value") == "not-found",
                "Service survived removal and reboot")
        no_listener()
        passed("Post-removal cold boot returns to Wayland with no Sharedesk service or listener")

    (OUT / (args.stage + "-journal.txt")).write_text(
        run("journalctl", "-u", UNIT, "-b", "--no-pager", check=False).stdout)


if __name__ == "__main__":
    main()
