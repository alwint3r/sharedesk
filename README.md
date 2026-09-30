# Sharedesk

A small remote-desktop **host for an already-started Ubuntu X11 session**. It captures the existing desktop and accepts keyboard/mouse input. On the Mac, use the built-in Screen Sharing app as the viewer. No separate server or public inbound port is needed.

This is an early, polling-based VNC host, not an AnyDesk-compatible client. The Ubuntu user must already be logged into an X11 desktop. Do not run it as root or expose its port to the internet. The X11 server must provide the XTEST and XFIXES extensions; Ubuntu's normal Xorg session provides both.

## Build on Ubuntu 22.04

Install build dependencies:

```sh
sudo apt install build-essential cmake pkg-config libvncserver-dev libx11-dev libxtst-dev libxfixes-dev
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Build from this directory on Ubuntu, inside or outside the desktop session. The same C source also builds for Linux x86-64 and ARM64 with the corresponding Linux libraries; it is not a macOS host.

## Connect from the Mac

Both devices must be on your Tailscale network. Restrict access to the Ubuntu host's VNC port to the Mac in your Tailscale access policy. Do not forward that port on your router. `--listen` accepts **only a Tailscale IPv4 address (100.64.0.0/10) or a loopback address**. It does not start a public or IPv6 listener.

Create a *new* VNC password file on Ubuntu. VNC authentication uses only **1–8 ASCII characters**; it is not a substitute for Tailscale's device identity and access policy. The file contains the password as plain text, not the format produced by `x11vnc -storepasswd`:

```sh
install -d -m 700 "$HOME/.sharedesk"
read -r -s -p 'New VNC password (1-8 ASCII characters): ' pw; printf '\n'
(umask 077; printf '%s\n' "$pw" > "$HOME/.sharedesk/vnc-password")
unset pw
```

From a terminal **in the logged-in Ubuntu X11 desktop**, run:

```sh
./build/sharedesk-host --listen "$(tailscale ip -4)" \
  --password-file "$HOME/.sharedesk/vnc-password" --port 5901
```

Port 5901 lets the existing `x11vnc` server keep port 5900 during comparison. From the Mac, open `vnc://<Ubuntu Tailscale IPv4>:5901` using Screen Sharing and enter the new VNC password. After comparison, stop `x11vnc` and remove any access-policy rule for its port. Stop this host with Ctrl+C; it releases any input held by the viewer. If it cannot bind, check whether another process already uses that port.

The host follows Ubuntu desktop-size changes without restarting. Viewers that support VNC desktop resizing receive the new size and a full repaint. A viewer without resize support is disconnected and can reconnect at the new size; the host keeps listening.

Ubuntu's cursor shape, hotspot (the pixel used for clicks) and position are tracked through X11's XFIXES extension and pointer queries. Viewers that support both cursor-shape and cursor-position updates render it locally. For shape-only viewers, the host hides the viewer cursor and draws Ubuntu's cursor into the screen stream instead, including local mouse movement. This fallback updates at `--fps`; try `--fps 30` if cursor motion feels slow. Viewers without cursor-shape support use LibVNCServer's screen-drawn cursor. If the cursor image is temporarily unavailable, the host keeps listening and retries the read.

Optional flags: `--port` (1–65535, default 5900) and `--fps` (1–30, default 10). These set the TCP listening port and the maximum screen-capture rate. When run manually, the host stays in the foreground. Ubuntu must remain awake for remote access, but its screen may be locked.

## Start automatically with the Ubuntu X11 desktop

After the manual connection works, install per-user graphical-session autostart **on Ubuntu** (not on the Mac). Use the same password file and port that worked manually:

```sh
python3 scripts/install-autostart.py --password-file "$HOME/.sharedesk/vnc-password" --port 5901
```

Do not use `sudo`. The installer copies the current build to `~/.local/libexec/sharedesk/` and creates `~/.config/autostart/sharedesk-host.desktop`. The desktop entry stays under `.config/autostart` because the graphical session looks there; the VNC password remains in `~/.sharedesk`. The installer waits for a Tailscale IPv4 address, then starts the host in the logged-in **X11** session. It does not log in at boot, restart a failed host, or keep the session awake. After rebuilding, run the installer again to copy the new executable.

Stop your manually started host with Ctrl+C before checking autostart at the **next graphical login**; otherwise both processes will try to use port 5901. If it does not connect, check `~/.local/state/sharedesk/host.log` (or `$XDG_STATE_HOME/sharedesk/host.log` if set) and verify the session is X11. Resolution changes do not require restarting the host. To check this, change the resolution in Ubuntu's Display settings while connected, then confirm the viewer follows the new size and mouse input still works.

To disable autostart and remove its installed executable:

```sh
python3 scripts/install-autostart.py --remove
```

This does not stop a host that is already running, and it leaves the password file and logs intact. Use `pgrep -a sharedesk-host` to find a running host and `kill <PID>` to stop it if needed.

## Current limits

- Desktop size is limited to 8192×8192 pixels. If a running desktop exceeds that limit, or replacement framebuffers cannot be allocated, the host disconnects the viewer and pauses capture. It keeps listening and retries until the desktop can be captured again.
- While a viewer is connected, polls the full screen and sends changed 64×64 regions; expect more CPU use and less fluid motion than a video-based remote desktop.
- Basic X11 keys, pointer buttons and scrolling. Keyboard mapping depends on the Ubuntu X11 layout; some Mac-specific keys may not map.
- Standard VNC cursor-shape updates have one-bit transparency, so soft edges are approximate. Screen-drawn cursors preserve alpha blending. Cursor images above 1024×1024 pixels are ignored; cursors too large for LibVNCServer's cursor-update buffer are drawn in the screen stream for shape-capable viewers.
- One viewer at a time. No audio, clipboard synchronization, file transfer, or login-screen access.
- Existing X11 session only; after reboot, a user must start a desktop session locally.
