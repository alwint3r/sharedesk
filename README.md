# Sharedesk (first milestone)

A small remote-desktop **host for an already-started Ubuntu X11 session**. It captures the existing desktop and accepts keyboard/mouse input. On the Mac, use the built-in Screen Sharing app as the viewer. No separate server or public inbound port is needed.

This is an early, polling-based VNC host, not an AnyDesk-compatible client. The Ubuntu user must already be logged into an X11 desktop. Do not run it as root or expose its port to the internet.

## Build on Ubuntu 22.04

Install build dependencies:

```sh
sudo apt install build-essential cmake pkg-config libvncserver-dev libx11-dev libxtst-dev
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Build from this directory on Ubuntu, inside or outside the desktop session. The same C source also builds for Linux x86-64 and ARM64 with the corresponding Linux libraries; it is not a macOS host.

## Connect from the Mac

Both devices must be on your Tailscale network. Restrict access to the Ubuntu host's VNC port to the Mac in your Tailscale access policy. Do not forward that port on your router. `--listen` accepts **only a Tailscale IPv4 address (100.64.0.0/10) or a loopback address**. It does not start a public or IPv6 listener.

Create a *new* VNC password file on Ubuntu. VNC authentication uses only **1–8 ASCII characters**; it is not a substitute for Tailscale's device identity and access policy. The file contains the password as plain text, not the format produced by `x11vnc -storepasswd`:

```sh
install -d -m 700 "$HOME/.config/sharedesk"
read -r -s -p 'New VNC password (1-8 ASCII characters): ' pw; printf '\n'
(umask 077; printf '%s\n' "$pw" > "$HOME/.config/sharedesk/vnc-password")
unset pw
```

From a terminal **in the logged-in Ubuntu X11 desktop**, run:

```sh
./build/sharedesk-host --listen "$(tailscale ip -4)" \
  --password-file "$HOME/.config/sharedesk/vnc-password" --port 5901
```

Port 5901 lets the existing `x11vnc` server keep port 5900 during comparison. From the Mac, open `vnc://<Ubuntu Tailscale IPv4>:5901` using Screen Sharing and enter the new VNC password. After comparison, stop `x11vnc` and remove any access-policy rule for its port. Stop this host with Ctrl+C; it releases any input held by the viewer. Restart it if the desktop resolution changes. If it cannot bind, check whether another process already uses that port.

Optional flags: `--port` (1–65535, default 5900) and `--fps` (1–30, default 10). These set the TCP listening port and the maximum screen-capture rate. The host runs in the foreground and starts only when you run it; automatic startup is not part of this milestone. Ubuntu must remain awake for remote access, but its screen may be locked.

## Current limits

- Fixed desktop size per run; resolution changes stop the host with an error.
- While a viewer is connected, polls the full screen and sends changed 64×64 regions; expect more CPU use and less fluid motion than a video-based remote desktop.
- Basic X11 keys, pointer buttons and scrolling. Keyboard mapping depends on the Ubuntu X11 layout; some Mac-specific keys may not map. Local pointer movement and custom cursor shapes may not appear in the video.
- One viewer at a time. No audio, clipboard synchronization, file transfer, or login-screen access.
- Existing X11 session only; after reboot, a user must start a desktop session locally.
