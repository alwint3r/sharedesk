#!/usr/bin/env python3
"""Install opt-in GDM/Xorg pre-login access on Ubuntu 22.04; never start or restart it."""

import argparse
import configparser
import hashlib
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import sys
import tempfile


UNIT_NAME = "sharedesk-host.service"
UNIT_MARKER = b"# Managed by Sharedesk's opt-in login-service installer.\n"
UNIT = Path("/etc/systemd/system") / UNIT_NAME
INSTALL = Path("/usr/local/libexec/sharedesk")
CONFIG = Path("/etc/sharedesk")
GDM = Path("/etc/gdm3/custom.conf")
GDM_BACKUP = CONFIG / "gdm-custom.conf.before-sharedesk"
GDM_DIGEST = CONFIG / "gdm-custom.conf.sharedesk.sha256"
ROOT = Path(__file__).resolve().parents[2]


def read_regular(path: Path, owners: set[int], limit: int) -> tuple[bytes, int]:
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        details = os.fstat(fd)
        if (not stat.S_ISREG(details.st_mode) or details.st_uid not in owners
                or details.st_mode & 0o022 or details.st_size > limit):
            raise ValueError(f"Unsafe owner, type, permissions or size: {path}")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError(f"File grew beyond its allowed size: {path}")
        return data, stat.S_IMODE(details.st_mode)
    finally:
        os.close(fd)


def systemctl(*arguments: str) -> subprocess.CompletedProcess:
    return subprocess.run(["/usr/bin/systemctl", *arguments], capture_output=True, text=True, timeout=20)


def trusted_directory(path: Path, mode: int = 0o755) -> None:
    # Check every component without resolving symlinks, before creating files
    # as root. No user-owned installation directory is trusted by the service.
    for directory in reversed([path, *path.parents]):
        if directory == Path("/"):
            continue
        try:
            details = directory.lstat()
        except FileNotFoundError:
            directory.mkdir(mode=mode if directory == path else 0o755)
            details = directory.lstat()
        if (not stat.S_ISDIR(details.st_mode) or details.st_uid != 0
                or details.st_mode & 0o022):
            raise ValueError(f"System directory must be root-owned and not writable by others: {directory}")
    if mode == 0o700 and path.stat().st_mode & 0o077:
        raise ValueError(f"Private configuration directory requires chmod 700: {path}")


def atomic_write(path: Path, data: bytes, mode: int) -> None:
    fd, name = tempfile.mkstemp(prefix=".sharedesk-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            os.fchown(stream.fileno(), 0, 0)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", default=os.environ.get("SUDO_USER"), help="only this desktop account may be shared after login")
    parser.add_argument("--password-file", type=Path, help="private VNC password to copy into root-owned service storage")
    parser.add_argument("--binary", type=Path, default=ROOT / "build/sharedesk-host")
    parser.add_argument("--supervisor-binary", type=Path, default=ROOT / "build/sharedesk-login-service")
    parser.add_argument("--port", type=int, default=5901)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--stats", action="store_true")
    parser.add_argument("--clipboard", action="store_true", help="enable text sharing in the configured user's desktop, never the greeter")
    parser.add_argument("--configure-gdm-xorg", action="store_true", help="explicitly permit setting GDM WaylandEnable=false, with a private backup")
    parser.add_argument("--remove", action="store_true", help="remove an inactive service; retain the password and GDM settings by default")
    parser.add_argument("--restore-gdm", action="store_true", help="with --remove, restore GDM only if unchanged since this installer edited it")
    args = parser.parse_args()
    if sys.platform != "linux" or os.geteuid() != 0 or os.getuid() != 0:
        parser.error("run with sudo on Ubuntu 22.04, not on the Mac")
    release = {}
    for line in Path("/etc/os-release").read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            release[key] = value.strip('"')
    if release.get("ID") != "ubuntu" or release.get("VERSION_ID") != "22.04":
        parser.error("this pre-login setup supports Ubuntu 22.04 only")
    if args.restore_gdm and not args.remove:
        parser.error("--restore-gdm requires --remove")
    if args.configure_gdm_xorg and args.remove:
        parser.error("--configure-gdm-xorg cannot be combined with --remove")

    state = systemctl("show", UNIT_NAME, "--property=ActiveState", "--value")
    if state.returncode != 0:
        parser.error("cannot query the system service manager; no installation attempted")
    if state.stdout.strip() not in ("inactive", "failed"):
        parser.error("the login service is active or transitioning. Stop it explicitly when convenient before updating/removing it")
    enabled = systemctl("is-enabled", "--quiet", UNIT_NAME).returncode == 0
    old_unit = None
    if UNIT.exists() or UNIT.is_symlink():
        old_unit, _ = read_regular(UNIT, {0}, 65536)
        if not old_unit.startswith(UNIT_MARKER):
            parser.error(f"refusing to replace an unmanaged unit: {UNIT}")
    elif args.remove:
        parser.error("the managed login service is not installed")
    elif any((INSTALL / name).exists() for name in ("sharedesk-host", "sharedesk-login-service")):
        parser.error("installed binaries exist without the managed unit; review the previous installation before replacing them")

    changes: dict[Path, tuple[bytes, int] | None] = {}
    if args.remove:
        changes[UNIT] = None
        changes[INSTALL / "sharedesk-host"] = None
        changes[INSTALL / "sharedesk-login-service"] = None
        if args.restore_gdm:
            if not GDM_BACKUP.exists() and not GDM_DIGEST.exists():
                print("No saved GDM change to restore.")
            else:
                original, _ = read_regular(GDM_BACKUP, {0}, 65536)
                digest, _ = read_regular(GDM_DIGEST, {0}, 128)
                current, mode = read_regular(GDM, {0}, 65536)
                if hashlib.sha256(current).hexdigest() != digest.decode().strip():
                    parser.error("GDM configuration changed after installation. It was not restored; review the saved backup manually")
                changes[GDM] = (original, mode)
                changes[GDM_BACKUP] = None
                changes[GDM_DIGEST] = None
    else:
        if not args.user or not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", args.user):
            parser.error("supply --user with a normal local Ubuntu desktop account name")
        account = pwd.getpwnam(args.user)
        greeter = pwd.getpwnam("gdm")
        if account.pw_uid < 1000 or account.pw_uid == 65534 or account.pw_uid == greeter.pw_uid:
            parser.error("the desktop account must not be root, gdm or nobody")
        if not 1 <= args.port <= 65535 or not 1 <= args.fps <= 30:
            parser.error("--port must be 1-65535 and --fps must be 1-30")
        manager = Path("/etc/X11/default-display-manager").read_text().strip()
        if manager not in ("/usr/sbin/gdm3", "/usr/sbin/gdm"):
            parser.error("the selected display manager is not GDM; no changes made")
        autostart = Path(account.pw_dir) / ".config/autostart/sharedesk-host.desktop"
        if autostart.exists() or autostart.is_symlink():
            parser.error("remove the old per-user autostart first, as the desktop user: python3 host/scripts/install-autostart.py --remove. This does not stop its running host. Also remove any custom XDG_CONFIG_HOME copy")
        if args.password_file is None:
            parser.error("--password-file is required for installation")
        password, mode = read_regular(args.password_file.expanduser().absolute(), {0, account.pw_uid}, 9)
        plain = password[:-1] if password.endswith(b"\n") else password
        if mode & 0o077 or not 1 <= len(plain) <= 8 or any(byte < 33 or byte > 126 for byte in plain):
            parser.error("password file must be private (chmod 600), with 1-8 non-space printable ASCII characters and an optional final newline")
        changes[CONFIG / "vnc-password"] = (password, 0o600)
        source_owners = {0, account.pw_uid}
        if os.environ.get("SUDO_UID", "").isdigit():
            source_owners.add(int(os.environ["SUDO_UID"]))
        for source, name in ((args.binary, "sharedesk-host"), (args.supervisor_binary, "sharedesk-login-service")):
            executable, mode = read_regular(source.expanduser().absolute(), source_owners, 32 << 20)
            if not executable.startswith(b"\x7fELF") or not mode & 0o111 or mode & 0o6000:
                parser.error(f"build the Linux executable first: {source}")
            changes[INSTALL / name] = (executable, 0o755)

        original, gdm_mode = read_regular(GDM, {0}, 65536)
        text = original.decode("utf-8")
        config = configparser.ConfigParser(interpolation=None, strict=True, delimiters=("=",), comment_prefixes=("#",))
        config.optionxform = str  # GDM keys are case-sensitive, unlike ConfigParser defaults.
        try:
            config.read_string(text)
        except configparser.Error:
            parser.error("cannot parse /etc/gdm3/custom.conf safely; review it manually")
        if config.defaults():
            parser.error("GDM [DEFAULT] values are not supported by this installer; review them manually")
        for option in ("AutomaticLoginEnable", "TimedLoginEnable"):
            if config.get("daemon", option, fallback="false").strip().lower() in ("true", "1", "yes", "on"):
                parser.error("automatic or timed login is already enabled in GDM. Disable it explicitly before installing this password-login setup")
        xorg = config.get("daemon", "WaylandEnable", fallback="").strip() in ("false", "0")
        if not xorg:
            if not args.configure_gdm_xorg:
                parser.error("GDM is not explicitly configured for Xorg. Re-run with --configure-gdm-xorg only if you approve disabling Wayland in GDM; no change has been made")
            if GDM_BACKUP.exists() or GDM_DIGEST.exists():
                parser.error("a previous GDM backup exists; review/restore that configuration before changing it again")
            lines = text.splitlines(keepends=True)
            daemon = None
            end = len(lines)
            for index, line in enumerate(lines):
                section = re.fullmatch(r"\s*\[([^\]]+)\]\s*", line.strip())
                if section and section.group(1) == "daemon":
                    daemon = index
                elif section and daemon is not None:
                    end = index
                    break
            if daemon is None:
                parser.error("GDM configuration has no [daemon] section; review it manually")
            option = None
            for index in range(daemon + 1, end):
                if re.match(r"\s*WaylandEnable\s*=", lines[index], re.IGNORECASE):
                    option = index
                    break
            if option is None:
                if not lines[daemon].endswith("\n"):
                    lines[daemon] += "\n"
                lines.insert(daemon + 1, "# Sharedesk pre-login access requires Xorg.\nWaylandEnable=false\n")
            else:
                lines[option] = "WaylandEnable=false\n"
            configured = "".join(lines).encode("utf-8")
            changes[GDM_BACKUP] = (original, 0o600)
            changes[GDM_DIGEST] = ((hashlib.sha256(configured).hexdigest() + "\n").encode(), 0o600)
            changes[GDM] = (configured, gdm_mode)
        arguments = f"--user {args.user} --port {args.port} --fps {args.fps}"
        if args.stats:
            arguments += " --stats"
        if args.clipboard:
            arguments += " --clipboard"
        template = (ROOT / "host/sharedesk-host.service.in").read_text()
        if not template.startswith(UNIT_MARKER.decode()) or template.count("@ARGUMENTS@") != 1:
            parser.error("invalid service template")
        changes[UNIT] = (template.replace("@ARGUMENTS@", arguments).encode(), 0o644)

    # All semantic checks precede changes. Writes are atomic; on a later failure
    # restore the previous bytes/modes and enabled state rather than leave a
    # partial password, binary or GDM edit. No start/stop/restart command exists
    # here, including rollback. The current per-user host is not touched.
    trusted_directory(INSTALL)
    trusted_directory(CONFIG, 0o700)
    trusted_directory(UNIT.parent)
    if GDM in changes:
        trusted_directory(GDM.parent)
    before: dict[Path, tuple[bytes, int] | None] = {}
    for path in changes:
        try:
            before[path] = read_regular(path, {0}, 32 << 20)
        except FileNotFoundError:
            before[path] = None
    try:
        if args.remove:
            disabled = systemctl("disable", UNIT_NAME)
            if disabled.returncode:
                raise RuntimeError(f"cannot disable the inactive service: {disabled.stderr.strip()}")
        for path, replacement in changes.items():
            if replacement is None:
                path.unlink(missing_ok=True)
            else:
                atomic_write(path, *replacement)
        reloaded = systemctl("daemon-reload")
        if reloaded.returncode:
            raise RuntimeError(f"cannot reload service definitions: {reloaded.stderr.strip()}")
        if not args.remove:
            installed = systemctl("enable", UNIT_NAME)
            if installed.returncode:
                raise RuntimeError(f"cannot enable service for boot: {installed.stderr.strip()}")
    except Exception:
        restoration_errors = []
        for path, saved in reversed(list(before.items())):
            try:
                if saved is None:
                    path.unlink(missing_ok=True)
                else:
                    atomic_write(path, *saved)
            except OSError:
                restoration_errors.append(str(path))
        try:
            systemctl("daemon-reload")
            restored = systemctl("enable" if enabled else "disable", UNIT_NAME)
            if restored.returncode and (enabled or old_unit is not None):
                restoration_errors.append("service enabled state")
        except (OSError, subprocess.TimeoutExpired):
            restoration_errors.append("service manager state")
        if restoration_errors:
            print("Rollback needs manual attention; do not reboot before reviewing: " + ", ".join(restoration_errors), file=sys.stderr)
        raise
    if args.remove:
        print("Removed the inactive login service. Its private VNC password was retained in /etc/sharedesk/vnc-password.")
        print("Per-user autostart was not restored. GDM was not restarted; a restored backend setting takes effect at a later restart/reboot.")
    else:
        print(f"Installed and enabled {UNIT_NAME} for the next boot. It was NOT started; GDM and the running host were NOT restarted.")
        print(f"After a deliberate reboot, connect over Tailscale on port {args.port} to the GDM login screen. Log in as {args.user}, then reconnect manually for the desktop.")
        print("The OS account password is still required. Pre-boot disk unlock is not supported. Other users and Wayland sessions are not shared.")
        print("Logs: sudo journalctl -u sharedesk-host.service -b")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, configparser.Error, subprocess.TimeoutExpired, RuntimeError) as error:
        print(f"Login-service setup failed: {error}", file=sys.stderr)
        sys.exit(1)
