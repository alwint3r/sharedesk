#!/usr/bin/env python3
"""Reproduce pre-login verification in a disposable Ubuntu ARM64 QEMU/HVF VM.

run: create/provision a VM, then verify. verify: restore its baseline and test
current host sources offline. stop/clean: stop or delete only the owned VM.
No Mac packages are installed. No real viewer, Ubuntu laptop or tailnet is used.
"""

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = Path(__file__).resolve().parent
CLOUD = "https://cloud-images.ubuntu.com/jammy/current"
IMAGE = "jammy-server-cloudimg-arm64.img"
CLOUD_KEY = "D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81"
SOURCES = ["CMakeLists.txt", "host/CMakeLists.txt", "host/host.c", "host/login-service.c",
           "host/libvncserver-clipboard.patch", "host/patch-vnc-clipboard.cmake",
           "host/sharedesk-host.service.in", "host/scripts/install-autostart.py",
           "host/scripts/install-login-service.py"]


def execute(args, *, log=None, timeout=60, check=True, **kwargs):
    if log is None:
        return subprocess.run(args, check=check, timeout=timeout, capture_output=True, text=True, **kwargs)
    with log.open("a") as stream:
        stream.write("\n$ " + shlex.join(map(str, args)) + "\n")
        stream.flush()
        return subprocess.run(args, check=check, timeout=timeout, stdout=stream,
                              stderr=subprocess.STDOUT, **kwargs)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            result.update(block)
    return result.hexdigest()


def unused_port():
    with socket.socket() as connection:
        connection.bind(("127.0.0.1", 0))
        return connection.getsockname()[1]


def ssh(work, command, *, log=None, timeout=60, check=True):
    return execute(["ssh", "-F", str(work / "ssh-config"), "vm", command],
                   log=log, timeout=timeout, check=check)


def qmp(work, command):
    """One bounded QMP request; the UUID ties the socket to this workspace."""
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(str(work / "qmp.sock"))
        with connection.makefile("rwb", buffering=0) as stream:
            json.loads(stream.readline())
            for request in ("qmp_capabilities", "query-uuid", command):
                stream.write(json.dumps({"execute": request}).encode() + b"\n")
                while True:
                    line = stream.readline()
                    if not line:
                        raise RuntimeError("QMP closed unexpectedly")
                    response = json.loads(line)
                    if "error" in response:
                        raise RuntimeError(str(response["error"]))
                    if "return" in response:
                        break
                if request == "query-uuid":
                    state = json.loads((work / "state.json").read_text())
                    if response["return"]["UUID"].lower() != state["uuid"]:
                        raise RuntimeError("QMP socket belongs to a different VM")
            return response["return"]


def vm_running(work):
    path = work / "qemu.pid"
    if not path.exists():
        return False
    pid = int(path.read_text())
    result = execute(["ps", "-p", str(pid), "-o", "command="], check=False)
    if result.returncode:
        return False
    state = json.loads((work / "state.json").read_text())
    # Never signal a reused PID or a QEMU process started for another task.
    if state["uuid"] not in result.stdout or str(work / "guest.qcow2") not in result.stdout:
        raise RuntimeError("Saved PID is not this workspace's QEMU process")
    return True


def stop(work):
    if not vm_running(work):
        return
    qmp(work, "system_powerdown")
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if not vm_running(work):
            return
        time.sleep(1)
    # A failed fixture must not keep consuming RAM. QMP quit affects only the
    # UUID-checked VM. No arbitrary process/port owner is ever killed.
    qmp(work, "quit")
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if not vm_running(work):
            return
        time.sleep(0.2)
    raise RuntimeError("Owned QEMU process did not exit; workspace was not removed")


def start(work, *, internet=False):
    if vm_running(work):
        raise RuntimeError("VM already running")
    state = json.loads((work / "state.json").read_text())
    for name in ("qmp.sock", "console.sock", "qemu.pid"):
        (work / name).unlink(missing_ok=True)
    network = f"user,id=net0,hostfwd=tcp:127.0.0.1:{state['ssh_port']}-:22"
    if not internet:
        network += ",restrict=on"
    args = ["qemu-system-aarch64", "-name", "sharedesk-disposable-" + state["uuid"],
            "-uuid", state["uuid"], "-machine", "virt,accel=hvf", "-cpu", "host",
            "-smp", "4", "-m", "6144",
            "-drive", f"if=pflash,format=raw,readonly=on,file={work / 'code.fd'}",
            "-drive", f"if=pflash,format=raw,file={work / 'vars.fd'}",
            "-drive", f"if=virtio,format=qcow2,file={work / 'guest.qcow2'}",
            "-drive", f"if=virtio,format=raw,readonly=on,file={work / 'seed.iso'}",
            "-device", "virtio-gpu-pci,xres=1280,yres=800", "-device", "qemu-xhci",
            "-device", "usb-kbd", "-device", "usb-tablet",
            "-netdev", network, "-device", "virtio-net-pci,netdev=net0",
            "-display", "none", "-vnc", f"unix:{work / 'console.sock'}",
            "-qmp", f"unix:{work / 'qmp.sock'},server=on,wait=off",
            "-serial", f"file:{work / 'serial.log'}", "-monitor", "none",
            "-pidfile", str(work / "qemu.pid"), "-daemonize"]
    (work / "qemu-args.json").write_text(json.dumps(args, indent=2) + "\n")
    execute(args, log=work / "qemu.log")
    qmp(work, "query-status")
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        result = ssh(work, "true", timeout=12, check=False)
        if result.returncode == 0:
            return
        if not vm_running(work):
            raise RuntimeError("VM exited during boot; see qemu.log and serial.log")
        time.sleep(2)
    raise RuntimeError("SSH boot deadline expired; see serial.log")


def cycle(work):
    stop(work)
    start(work)
    wait_for_greeter(work)


def wait_for_greeter(work):
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        result = ssh(work, 'sid=$(loginctl show-seat seat0 -p ActiveSession --value); '
                     'test -n "$sid" && loginctl show-session "$sid" -p Class --value', check=False)
        if result.returncode == 0 and result.stdout.strip() == "greeter":
            time.sleep(3)
            return
        time.sleep(2)
    raise RuntimeError("GDM greeter deadline expired")


def copy_sources(work, report):
    manifest = {name: digest(ROOT / name) for name in SOURCES}
    manifest["host/scripts/qemu-guest-check.py"] = digest(SCRIPTS / "qemu-guest-check.py")
    manifest["host/scripts/qemu-mac-peer.c"] = digest(SCRIPTS / "qemu-mac-peer.c")
    (report / "source-sha256.json").write_text(json.dumps(manifest, indent=2) + "\n")
    with tarfile.open(work / "source.tar", "w") as archive:
        for name in manifest:
            path = ROOT / name
            if not stat.S_ISREG(path.lstat().st_mode):
                raise RuntimeError("Source must be a regular file: " + name)
            archive.add(path, arcname=name, recursive=False)
    execute(["scp", "-F", str(work / "ssh-config"), str(work / "source.tar"), "vm:source.tar"], log=report / "copy.log")
    ssh(work, "mkdir -p ~/source && tar -xf ~/source.tar -C ~/source --no-same-owner", log=report / "copy.log")
    return manifest


def guest(work, stage, report):
    state = json.loads((work / "state.json").read_text())
    print("Guest stage: " + stage, flush=True)
    command = shlex.join(["sudo", "python3", "/home/vmadmin/source/host/scripts/qemu-guest-check.py",
                          stage, "--fixture", state["uuid"]])
    ssh(work, command, log=report / (stage + ".log"), timeout=3600 if stage == "setup" else 240)


def build(work, report):
    ssh(work, "cmake -S ~/source -B ~/source/build -DCMAKE_BUILD_TYPE=Release "
        "-DCMAKE_C_FLAGS=-Werror -DSHAREDESK_LOGIN_SERVICE=ON && "
        "cmake --build ~/source/build -j4 && "
        "chmod go-w ~/source/build/sharedesk-host ~/source/build/sharedesk-login-service",
        log=report / "build.log", timeout=600)


def mac_probe(work, report, *, denied=False):
    port = unused_port()
    args = ["ssh", "-F", str(work / "ssh-config"), "-N", "-L",
            f"127.0.0.1:{port}:100.100.100.100:5901", "-o", "ExitOnForwardFailure=yes", "vm"]
    name = "mac-denied" if denied else "mac-framebuffer"
    with (report / (name + "-tunnel.log")).open("w") as log:
        tunnel = subprocess.Popen(args, stdout=log, stderr=log)
        try:
            time.sleep(1)
            if tunnel.poll() is not None:
                raise RuntimeError("Could not create the isolated VNC tunnel")
            environment = dict(os.environ)
            libdir = execute(["pkg-config", "--variable=libdir", "openssl"]).stdout.strip()
            environment["OPENSSL_MODULES"] = str(Path(libdir) / "ossl-modules")
            result = execute([str(work / "mac-peer"), str(port)], log=report / (name + ".log"),
                             timeout=25, check=False, env=environment)
            expected = 3 if denied else 0
            if result.returncode != expected:
                raise RuntimeError(f"Mac probe returned {result.returncode}, expected {expected}")
        finally:
            tunnel.terminate()
            try:
                tunnel.wait(timeout=5)
            except subprocess.TimeoutExpired:
                tunnel.kill()
                tunnel.wait(timeout=5)


def collect(work, report):
    if not vm_running(work):
        return
    ssh(work, "sudo journalctl -u sharedesk-host -b --no-pager; "
        "loginctl list-sessions; systemctl status gdm sharedesk-host --no-pager",
        log=report / "final-diagnostics.log", check=False)
    with (report / "guest-results.tar.gz").open("wb") as stream:
        subprocess.run(["ssh", "-F", str(work / "ssh-config"), "vm",
                        "sudo tar -C /var/tmp/sharedesk-checks -czf - ."], stdout=stream,
                       stderr=subprocess.DEVNULL, timeout=60, check=True)


def verify(work):
    stop(work)
    if not (work / "baseline-vars.fd").is_file():
        raise RuntimeError("No completed baseline. Use run to provision a fresh workspace.")
    execute(["qemu-img", "snapshot", "-a", "before-sharedesk", str(work / "guest.qcow2")])
    shutil.copyfile(work / "baseline-vars.fd", work / "vars.fd")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    report = work / "reports" / stamp
    report.mkdir(parents=True)
    print("Results: " + str(report), flush=True)
    summary = {"passed": False, "network": "dummy tailscale0; restricted QEMU networking",
               "controller_sha256": digest(Path(__file__).resolve()),
               "image": json.loads((work / "image.json").read_text())}
    try:
        start(work)
        wait_for_greeter(work)
        summary["sources"] = copy_sources(work, report)
        flags = shlex.split(execute(["pkg-config", "--cflags", "--libs", "libvncclient", "openssl"]).stdout)
        execute(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(SCRIPTS / "qemu-mac-peer.c"),
                 *flags, "-o", str(work / "mac-peer")], log=report / "mac-build.log")
        build(work, report)
        guest(work, "install", report)
        cycle(work)
        guest(work, "sessions", report)
        mac_probe(work, report, denied=True)
        guest(work, "return", report)
        mac_probe(work, report)
        guest(work, "lifecycle", report)
        cycle(work)
        guest(work, "wayland", report)
        cycle(work)
        guest(work, "repeat", report)
        cycle(work)
        guest(work, "removed", report)
        summary["passed"] = True
        print("PASS: all QEMU verification stages completed", flush=True)
    except BaseException as error:
        summary["error"] = str(error)
        raise
    finally:
        (report / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        try:
            collect(work, report)
        finally:
            stop(work)
            print("VM stopped. Workspace retained: " + str(work), flush=True)


def create(work):
    state = {"version": 1, "uuid": str(uuid.uuid4()), "ssh_port": unused_port()}
    (work / "state.json").write_text(json.dumps(state, indent=2) + "\n")
    print("Disposable workspace: " + str(work), flush=True)
    setup = work / "setup"
    setup.mkdir()
    gpg_home = work / "gnupg"
    gpg_home.mkdir(mode=0o700)
    try:
        urls = [("SHA256SUMS", CLOUD + "/SHA256SUMS"), ("SHA256SUMS.gpg", CLOUD + "/SHA256SUMS.gpg"),
                ("cloud-key.asc", "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x" + CLOUD_KEY),
                (IMAGE, CLOUD + "/" + IMAGE)]
        for name, url in urls:
            print("Downloading " + name, flush=True)
            execute(["curl", "--fail", "--show-error", "--location", "--proto", "=https",
                     "--proto-redir", "=https", "--connect-timeout", "30", "--max-time", "1800",
                     "--output", str(work / name), url], log=setup / "downloads.log", timeout=1810)
        execute(["gpg", "--homedir", str(gpg_home), "--batch", "--import", str(work / "cloud-key.asc")],
                log=setup / "signature.log")
        result = execute(["gpg", "--homedir", str(gpg_home), "--batch", "--status-fd", "1",
                          "--verify", str(work / "SHA256SUMS.gpg"), str(work / "SHA256SUMS")])
        (setup / "signature-status.log").write_text(result.stdout + result.stderr)
        valid = [line.split() for line in result.stdout.splitlines() if line.startswith("[GNUPG:] VALIDSIG ")]
        if not any(line[2] == CLOUD_KEY or line[-1] == CLOUD_KEY for line in valid):
            raise RuntimeError("Checksum manifest was not signed by the pinned Ubuntu cloud-image key")
        expected = [line.split()[0] for line in (work / "SHA256SUMS").read_text().splitlines()
                    if line.split()[-1].lstrip("*") == IMAGE]
        actual = digest(work / IMAGE)
        if expected != [actual]:
            raise RuntimeError("Ubuntu image checksum mismatch; a rolling image may have changed. Start a fresh run.")
        (work / "image.json").write_text(json.dumps({"url": CLOUD + "/" + IMAGE, "sha256": actual,
            "signing_key": CLOUD_KEY, "qemu": execute(["qemu-system-aarch64", "--version"]).stdout}, indent=2) + "\n")
    finally:
        execute(["gpgconf", "--homedir", str(gpg_home), "--kill", "all"], check=False)

    qemu = Path(shutil.which("qemu-system-aarch64")).resolve()
    firmware = qemu.parent.parent / "share/qemu"
    shutil.copyfile(firmware / "edk2-aarch64-code.fd", work / "code.fd")
    shutil.copyfile(firmware / "edk2-arm-vars.fd", work / "vars.fd")
    execute(["qemu-img", "create", "-f", "qcow2", "-F", "qcow2", "-b", str(work / IMAGE),
             str(work / "guest.qcow2"), "35G"], log=setup / "disk.log")
    execute(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(work / "ssh-key")])
    seed = work / "seed"
    seed.mkdir()
    key = (work / "ssh-key.pub").read_text().strip()
    userdata = {"users": [{"name": "vmadmin", "shell": "/bin/bash", "lock_passwd": True,
                           "sudo": "ALL=(ALL) NOPASSWD:ALL", "ssh_authorized_keys": [key]}],
                "ssh_pwauth": False, "disable_root": True, "hostname": "sharedesk-test-vm",
                "write_files": [{"path": "/etc/sharedesk-qemu-fixture", "permissions": "0600",
                                 "content": state["uuid"] + "\n"}]}
    (seed / "user-data").write_text("#cloud-config\n" + json.dumps(userdata, indent=2) + "\n")
    (seed / "meta-data").write_text("instance-id: " + state["uuid"] + "\nlocal-hostname: sharedesk-test-vm\n")
    execute(["hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata",
             "-o", str(work / "seed.iso"), str(seed)], log=setup / "seed.log")
    (work / "ssh-config").write_text(
        f"Host vm\n  HostName 127.0.0.1\n  Port {state['ssh_port']}\n  User vmadmin\n"
        f"  IdentityFile {work / 'ssh-key'}\n  UserKnownHostsFile {work / 'known-hosts'}\n"
        "  GlobalKnownHostsFile /dev/null\n  StrictHostKeyChecking accept-new\n"
        "  IdentitiesOnly yes\n  IdentityAgent none\n  BatchMode yes\n  ConnectTimeout 8\n"
        "  ConnectionAttempts 1\n  ServerAliveInterval 10\n  ServerAliveCountMax 3\n"
        "  PasswordAuthentication no\n  KbdInteractiveAuthentication no\n  ForwardAgent no\n")
    try:
        start(work, internet=True)  # Downloads only; no host mounts or real tailnet.
        ssh(work, "sudo cloud-init status --wait", log=setup / "cloud-init.log", timeout=300)
        copy_sources(work, setup)
        guest(work, "setup", setup)
        build(work, setup)  # Fetch the pinned private VNC dependency before isolation.
        cycle(work)  # Every following boot uses restrict=on.
        stop(work)
        execute(["qemu-img", "snapshot", "-c", "before-sharedesk", str(work / "guest.qcow2")])
        shutil.copyfile(work / "vars.fd", work / "baseline-vars.fd")
        print("Reusable pre-installation baseline saved", flush=True)
    finally:
        try:
            collect(work, setup)
        finally:
            stop(work)


def owned_workspace(value):
    path = Path(value).absolute()
    if path.is_symlink():
        raise RuntimeError("Workspace must not be a symlink")
    path = path.resolve()
    if path.parent != Path("/tmp").resolve() or not re.fullmatch(r"sharedesk-qemu\.[A-Za-z0-9_-]+", path.name):
        raise RuntimeError("Use the /tmp/sharedesk-qemu.* workspace printed by run")
    details = path.stat()
    marker = path / "state.json"
    if (details.st_uid != os.getuid() or details.st_mode & 0o077 or marker.is_symlink()
            or not stat.S_ISREG(marker.stat().st_mode) or marker.stat().st_uid != os.getuid()):
        raise RuntimeError("Unsafe workspace ownership, permissions or marker")
    state = json.loads(marker.read_text())
    if state.get("version") != 1 or str(uuid.UUID(state["uuid"])) != state["uuid"]:
        raise RuntimeError("Unrecognized workspace marker")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["run", "verify", "stop", "clean"])
    parser.add_argument("--work", help="existing workspace printed by run; required except for run")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64" or os.geteuid() == 0:
        parser.error("run as a normal user on an Apple Silicon Mac; never use sudo")
    if args.action == "run" and args.work:
        parser.error("run creates a fresh workspace; do not supply --work")
    if args.action != "run" and not args.work:
        parser.error("verify/stop/clean require --work")
    os.umask(0o077)
    if args.action in ("run", "verify"):
        for program in ("qemu-system-aarch64", "qemu-img", "gpg", "gpgconf", "curl", "hdiutil",
                        "ssh", "scp", "ssh-keygen", "cc", "pkg-config"):
            if not shutil.which(program):
                parser.error("missing prerequisite (not installed automatically): " + program)
        execute(["pkg-config", "--exists", "libvncclient", "openssl"])
    if args.action == "run":
        work = Path(tempfile.mkdtemp(prefix="sharedesk-qemu.", dir="/tmp")).resolve()
    else:
        work = owned_workspace(args.work)
    lock = os.open(work / "controller.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("This workspace is busy. Interrupt its active controller before running another command.") from None
        if args.action == "run":
            create(work)
            verify(work)
        elif args.action == "verify":
            verify(work)
        else:
            stop(work)
            if args.action == "clean":
                shutil.rmtree(work)
                print("Removed disposable VM, fixture credentials and results: " + str(work))
            else:
                print("VM stopped; workspace retained: " + str(work))
    finally:
        os.close(lock)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        print("QEMU verification failed: " + str(error), file=sys.stderr)
        print("Inspect the retained workspace logs. No laptop or viewer was changed.", file=sys.stderr)
        sys.exit(1)
