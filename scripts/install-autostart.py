#!/usr/bin/env python3
"""Install Sharedesk for the current user's X11 graphical session."""

import argparse
import os
from pathlib import Path
import shlex
import stat
import sys
import tempfile


def atomic_write(path: Path, contents: bytes, mode: int) -> None:
    # Do not leave a partial executable or .desktop entry if installation fails.
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
        temporary.write(contents)
        temporary_path = Path(temporary.name)
    try:
        temporary_path.chmod(mode)
        temporary_path.replace(path)
    finally:
        temporary_path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--password-file", type=Path, help="existing private VNC password file")
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parent.parent / "build/sharedesk-host")
    parser.add_argument("--port", type=int, default=5901)
    parser.add_argument("--fps", type=int, default=10)
    parser.add_argument("--stats", action="store_true", help="enable performance summaries every five seconds")
    parser.add_argument("--clipboard", action="store_true", help="enable two-way text clipboard sharing")
    parser.add_argument("--remove", action="store_true", help="remove autostart and installed executable")
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("run as the Ubuntu desktop user, not with sudo")

    home = Path.home()
    install_dir = home / ".local/libexec/sharedesk"
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config")).expanduser()
    desktop_file = config_home / "autostart/sharedesk-host.desktop"
    installed_binary = install_dir / "sharedesk-host"
    launcher = install_dir / "sharedesk-host-start"

    if args.remove:
        for path in (desktop_file, launcher, installed_binary):
            path.unlink(missing_ok=True)
        print("Removed Sharedesk autostart files. A host already running will continue until stopped.")
        return 0

    if args.password_file is None:
        parser.error("--password-file is required unless --remove is used")
    if not 1 <= args.port <= 65535 or not 1 <= args.fps <= 30:
        parser.error("--port must be 1-65535 and --fps must be 1-30")

    binary = args.binary.expanduser().resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error(f"build the host first; executable not found: {binary}")
    password_file = args.password_file.expanduser().absolute()
    try:
        details = password_file.lstat()
    except OSError as exc:
        parser.error(f"cannot access password file: {exc}")
    if (not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid()
            or details.st_mode & 0o077):
        parser.error("password file must be owned by you, be a regular file, and have no group/other access (chmod 600)")

    install_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    desktop_file.parent.mkdir(parents=True, exist_ok=True)

    # A .desktop Exec field does not run in a shell. Install a fixed launcher
    # instead of putting user-supplied paths or a shell command into Exec.
    launcher_text = f"""#!/bin/sh
set -eu
umask 077
state_dir="${{XDG_STATE_HOME:-$HOME/.local/state}}/sharedesk"
mkdir -p "$state_dir"
exec >> "$state_dir/host.log" 2>&1

if [ "${{XDG_SESSION_TYPE:-}}" != x11 ] || [ -z "${{DISPLAY:-}}" ]; then
    echo 'Sharedesk requires a logged-in X11 graphical session'
    exit 1
fi
if ! command -v tailscale >/dev/null 2>&1; then
    echo 'tailscale command not found'
    exit 1
fi
printf 'Waiting for Tailscale IPv4 address on %s\\n' "$(date)"
while :; do
    ip=$(tailscale ip -4 2>/dev/null || true)
    if [ -n "$ip" ]; then
        exec {shlex.quote(str(installed_binary))} --listen "$ip" --password-file {shlex.quote(str(password_file))} --port {args.port} --fps {args.fps}{' --stats' if args.stats else ''}{' --clipboard' if args.clipboard else ''}
    fi
    sleep 5
done
"""
    # Desktop Entry quoting: shell quoting does not apply to Exec. The value
    # first passes through the desktop-file string parser, then Exec quoting.
    exec_path = str(launcher)
    if any(char in exec_path for char in "\n\r"):
        parser.error("home directory path cannot contain a newline")
    escaped = exec_path.replace("\\", "\\\\\\\\").replace("%", "%%")
    for character in ('"', "`", "$"):
        escaped = escaped.replace(character, "\\\\" + character)
    desktop_text = ("[Desktop Entry]\n"
                    "Type=Application\n"
                    "Name=Sharedesk Host\n"
                    "Comment=Share the logged-in X11 desktop over Tailscale\n"
                    f'Exec="{escaped}"\n'
                    "Terminal=false\n")

    atomic_write(installed_binary, binary.read_bytes(), 0o700)
    atomic_write(launcher, launcher_text.encode(), 0o700)
    atomic_write(desktop_file, desktop_text.encode(), 0o600)
    print(f"Installed {desktop_file}")
    state_home = Path(os.environ.get("XDG_STATE_HOME", home / ".local/state")).expanduser()
    print(f"Host will start at the next X11 desktop login. Logs: {state_home / 'sharedesk/host.log'}")
    print("Re-run this installer after rebuilding the host to update the installed executable.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
