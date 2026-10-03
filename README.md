# Sharedesk

A small private remote-desktop application: an **Ubuntu X11 host** and a **native Mac viewer**. The host captures an already-started desktop and accepts keyboard/mouse input. The viewer uses standard VNC, including opt-in two-way text clipboard sharing. Screen Sharing remains an alternative for desktop access, but its clipboard interoperability has not been established. No relay server or public inbound port is needed.

This is an early VNC application, not an AnyDesk-compatible client. The Ubuntu user must already be logged into an X11 desktop. Do not run it as root or expose its port to the internet. The X11 server must provide the XTEST, XFIXES and XKEYBOARD extensions; Ubuntu's normal Xorg session provides them.

## Repository layout

```text
CMakeLists.txt                 # Root build entry point and platform selection
README.md                     # Shared build and usage documentation
host/
  CMakeLists.txt               # Host target and dependencies
  host.c
  libvncserver-clipboard.patch # Unified safety patch for the private dependency
  patch-vnc-clipboard.cmake    # Apply/check the pinned dependency patch
  scripts/install-autostart.py
viewer/
  CMakeLists.txt               # Viewer target and dependencies
  main.swift                  # Application entry point
  ViewerApplication.swift     # Window, controls and main-thread clipboard
  DesktopView.swift           # Rendering, cursor and input
  VNCSession.swift            # Worker, session state, queues and deadlines
  ConnectionStatistics.swift  # On-demand, content-free session statistics panel
  ConnectionProfiles.swift    # Validated profile settings and private file storage
  ProfileEditor.swift         # Native Add/Edit dialog
  ProfilePasswords.swift      # Optional macOS Keychain credentials
  VNCBridge.c                 # LibVNCClient interop, bounded clipboard codec and buffers
  VNCBridge.h
  module.modulemap            # Swift import of the C bridge
  viewer-Info.plist.in
  sharedesk-viewer.icns        # Packaged macOS app icon
  make-icon.swift             # Editable icon artwork and size generation
  package-app.cmake.in        # Installed-bundle dependencies, notices and signing
  Install.txt                 # Instructions included in the private DMG
```

Run the commands below from the repository root. The application folders own their files and build definitions; they are not standalone CMake projects. Build outputs remain at `build/sharedesk-host` on Ubuntu and `build-mac/sharedesk-viewer.app` on the Mac.

## Build on Ubuntu 22.04

Install build dependencies:

```sh
sudo apt install build-essential cmake pkg-config patch zlib1g-dev libjpeg-dev libpng-dev libx11-dev libxtst-dev libxfixes-dev libxext-dev libxdamage-dev
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

The first configuration downloads a SHA-256-pinned **LibVNCServer 0.9.15** source archive. Ubuntu 22.04's system 0.9.13 has no Unicode clipboard extension. CMake applies `host/libvncserver-clipboard.patch` to validate compressed text lengths, then links the private server library statically into `build/sharedesk-host`. Ubuntu's system VNC library is not replaced, and the autostart installer still copies a single host executable. Compression/image libraries and X11 remain system dependencies. Examples, tests, background-thread support, TLS, WebSockets and file-transfer extensions are disabled in this private library; Tailscale remains the transport security boundary.

For an offline build, provide a writable extracted copy of the pinned 0.9.15 source with `-DFETCHCONTENT_SOURCE_DIR_SHAREDESK_VNC=/path/to/source` on the configure command. The same unified patch is checked and applied there. The private library is GPL-2.0-or-later; review its license and corresponding-source obligations before distributing host binaries.

Build from this directory on Ubuntu, inside or outside the desktop session. The same C source also builds for Linux x86-64 and ARM64 with the corresponding Linux libraries; it is not a macOS host.

## Install the Mac viewer

The private installer is **`build-mac/Sharedesk-0.1-arm64.dmg`**. It contains a self-contained **Sharedesk.app** for **Apple Silicon and macOS 27 or newer**. The destination Mac does not need Homebrew, Xcode or the repository. It still needs Tailscale access to the Ubuntu host.

```sh
open build-mac/Sharedesk-0.1-arm64.dmg
```

Quit an existing viewer when convenient, drag **Sharedesk.app** onto the **Applications** shortcut, eject the disk image, then open Sharedesk from Applications. Installation does not change the Ubuntu host, `~/.sharedesk/profiles.json`, or saved Keychain passwords. macOS may request renewed Keychain access for the installed build.

**This is an ad-hoc signed private build, not an Apple-notarized public release.** If macOS blocks a copy you know and trust, try opening it, then use **System Settings → Privacy & Security → Open Anyway** and confirm. Do not disable Gatekeeper globally. Intel and older macOS versions are not supported by this package; the bundled Homebrew libraries require macOS 27.

To update, quit Sharedesk before replacing its copy in Applications. To uninstall, quit it and move the app to the Trash. Profiles and Keychain items remain unless removed separately.

### Create the private installer

After configuring the Mac build as below, run from the repository root:

```sh
cmake --build build-mac --target package
```

This builds the viewer, stages it as `Sharedesk.app`, embeds LibVNCClient and its non-system library dependencies (including OpenSSL's dynamically loaded legacy provider for VNC authentication), collects their license notices, verifies deployment targets and bundle dependencies, signs the libraries and completed app, and creates the DMG. It does not install into Applications or restart a viewer. A packaging failure stops the command rather than publishing a partially prepared app.

The ordinary `build-mac/sharedesk-viewer.app` remains a development bundle. Packaging changes only a staged copy; macOS supplies the system frameworks and Swift runtime. Third-party notices are in the installed app's `Contents/Resources/ThirdPartyNotices.txt` and `Contents/Resources/Licenses`. LibVNCClient uses GPL-2.0-or-later; review licensing and corresponding-source requirements before redistributing this private package.

## Build the Mac viewer

On the Mac, install LibVNCClient through Homebrew's `libvncserver` package. Xcode or its Command Line Tools must provide a Swift 6 or newer compiler and the macOS SDK. Use Ninja for the Swift build:

```sh
brew install cmake ninja pkg-config libvncserver
cmake -S . -B build-mac -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-mac
open build-mac/sharedesk-viewer.app
```

**Upgrading an existing build:** CMake cannot change an existing build directory from Unix Makefiles to Ninja. Before configuring, move the old `build-mac` directory to an unused backup path, such as `build-mac-objectivec`, then run the commands above. Keep the working app and its source revision until normal use with the Swift viewer confirms the migration. Quit the Swift viewer before opening the fallback app at `build-mac-objectivec/sharedesk-viewer.app`.

CMake builds the viewer on macOS and the host on Linux. The viewer uses Swift and AppKit, with a small plain-C bridge to LibVNCClient. There is no application-owned Objective-C in the active viewer.

Connection controls use native AppKit Liquid Glass in light and dark appearance, with a separate rounded remote-desktop canvas and a connection-state footer. Glass stays off the remote image.

Use **Hide Controls** in the footer to collapse the top panel and give the desktop more space; **Show Controls** restores it. Connect/Disconnect stays available in the footer while collapsed. Fields and clipboard settings are retained, and controls start visible on each launch. Connection validation errors reveal the fields when input is needed.

The ordinary development app requires the Homebrew libraries on the Mac where it runs. Use the [private installer](#install-the-mac-viewer) for a self-contained copy.

One dedicated networking worker owns the C client and writable framebuffer. Swift owns session state, bounded outgoing queues, elapsed-time deadlines and cancellation. A lock transfers the latest immutable frame, cursor and clipboard snapshots to the main thread. AppKit rendering, input handling and pasteboard access stay on the main thread; blocking library calls do not run in Swift Tasks or actors. Clipboard and shortcut behavior are unchanged by the language migration.

Disconnect Screen Sharing first; the host accepts one viewer at a time. Enter Ubuntu's **numeric Tailscale IPv4**, port **5901**, and the same VNC password as the host, then click **Connect**. The viewer also allows loopback IPv4 for local connections. DNS names, public addresses, unauthenticated servers, and IPv6 are not supported. Passwords are cleared from the field when connecting. Manual connections do not save passwords; connection profiles can optionally remember them in macOS Keychain. Reconnects remain manual.

After an unexpected loss, the footer shows **Connection lost** and offers **Reconnect** for the unchanged address and port. A failed connection attempt shows **Connection failed** with **Retry**; an intentional disconnect returns to **Not connected** with **Connect**. The same action stays available when the top controls are collapsed. Nothing retries automatically.

Reconnect retains the current endpoint and clipboard setting. It reads a saved password only from the selected, endpoint-matched profile; otherwise it reveals the controls and asks you to enter the password again. Typed passwords, including overrides, are not retained for recovery. Editing the address/port or selecting, saving or deleting a profile returns the action to **Connect**, so recovery never silently restores a previous endpoint. Each attempt starts with cleared input/cursor/framebuffer state, Fit zoom and a fresh clipboard baseline. An old copy is sent only through **Send Clipboard**.

Recovery uses the existing connection-error and elapsed-timeout detection. It adds no background probes or sleep/wake retries; an idle connection has no framebuffer-based timeout. If an unresponsive connection has not yet reported a failure, use **Disconnect**, then connect again manually.

The viewer uses elapsed-time deadlines: three seconds for TCP connection setup, five seconds per authentication/initialization operation, and twenty seconds per incoming VNC message or outgoing input/clipboard packet. An unchanged desktop has no idle timeout. **Disconnect** cancels pending network I/O. These application deadlines replace LibVNCClient 0.9.15's retry-count timeout, which can reject healthy fragmented transfers too early. Already-buffered messages are processed without waiting for further network traffic.

The desktop starts in **Fit** mode, showing the whole remote image. The footer has **Zoom out**, a middle **Fit/current zoom** button, and **Zoom in**. Zoom steps are **1.25×, 1.5×, 2×, 3× and 4× relative to Fit**, not physical-pixel percentages. Click the middle button to reset to Fit. Zoom is available once a connected framebuffer arrives; each new connection starts in Fit, and zoom is not saved in profiles.

When zoomed, drag the local horizontal/vertical scrollbars to navigate the enlarged image. Mouse-wheel and trackpad scrolling over the desktop still go to Ubuntu, not the local viewport. No pinch-zoom or new keyboard shortcuts are added. Resizing the window, collapsing the controls and host resolution changes retain the chosen zoom and visible region where scroll bounds allow it. Host resolution changes replace the framebuffer without reconnecting. Mouse clicks, dragging and cursor shapes remain supported; Ubuntu cursor-position messages do not move the Mac's global pointer.

Keyboard input initially targets English (US) direct keys, including Shift punctuation, navigation, F1–F12 and shortcuts. **Control maps to Ubuntu Ctrl, Option to Alt, and Command to Super**, not Ctrl. Cmd+Q and Cmd+W stay local. Key-up uses the remembered key-down symbol; Mac repeat events are ignored because the host owns repeat. Losing focus releases held input. IME composition and dead-key text entry are not supported yet.

For clipboard sharing, enable **`--clipboard` on the Ubuntu host** and check **Share text clipboard** in the viewer. Copy text on the Mac, return to Sharedesk, then paste in Ubuntu using that application's paste action. New Mac text is checked while Sharedesk is active and before keyboard or mouse-button events, so clipboard messages are queued before paste actions. New Ubuntu copies update the Mac clipboard while sharing is enabled. Neither side exports an old clipboard automatically on connection; use **Send Clipboard** to send text already copied on the Mac. Enabling the checkbox also starts from the current clipboard change count, without sending an old copy.

Clipboard sharing is off by default in both programs. UTF-8 is negotiated when both sides support the standard Extended Clipboard extension. Older peers retain lossless Latin-1 sharing; unsupported Unicode is rejected with a status message. The checkbox tooltip shows whether UTF-8 was negotiated. NUL-containing text and transfers over the encoded byte limit are rejected without shortening them. It keeps clipboard data in memory only. See [Text clipboard sharing](#text-clipboard-sharing) for host setup and privacy details. Successful local protocol checks do not replace normal use against your actual Ubuntu desktop.

### Viewer connection statistics

Click **Stats** in the footer to open the non-modal **Connection Statistics** window. It is available with the top controls shown or hidden, and starts closed each launch. Opening it releases held remote keys/buttons but does not pause the connection. Closing it stops statistics sampling without disconnecting.

The panel refreshes about once per second using the existing UI timer. It shows:

| Field | Meaning |
| --- | --- |
| Remote resolution | The most recently reported framebuffer dimensions in remote pixels, independent of local zoom. |
| Received updates | Successfully processed VNC framebuffer-update messages per second, including empty, cursor-only and resize updates. Multiple rectangles in one message count once. This is **not displayed FPS**; quiet desktops can show zero. |
| Incoming VNC (TCP) | macOS's received TCP payload-byte counter for this connection, expressed in **KiB/s** (1 KiB = 1024 bytes). Includes framebuffer, clipboard and control messages, and may include TCP retransmissions. Excludes TCP/IP headers and Tailscale overhead. Bytes can arrive before a complete message is decoded. This is traffic rate, not link capacity. |
| Clipboard mode | Negotiated UTF-8 or Latin-1 fallback, plus the viewer's sharing setting. Capability negotiation does not prove that the host imported or pasted text. |
| Connected duration | Time since connection setup completed, using the session's monotonic clock. Excludes setup time and freezes when the session ends. |
| Last disconnect | The reason for the latest ended connection attempt, including deliberate disconnects and failed setup. Retained during a new attempt, for this app launch only. |

Rates start with **Sampling…** on opening or reconnecting, then use the actual time between samples. **Unavailable** means the operating-system byte counter could not be read; it is not a zero-traffic reading. Ended sessions show no live rates. The latest session's resolution, mode and duration remain available after disconnect; no session history is saved.

These are content-free, in-memory counters. There are no statistics logs, exports, background probes or latency estimates. Opening Stats never reads the clipboard or Keychain and does not change profiles. The Ubuntu host's separate `--stats` option is not required.

### Connection profiles

Use **Add…** beside the profile selector to save a name, Tailscale/loopback IPv4, port and clipboard setting. Profile names must be unique, ignoring case. Select a saved profile to fill the connection fields, then click **Connect**. Selecting a profile never connects automatically. The viewer starts with **Manual connection** selected; that option remains available for connections you do not want to save.

**Remember password in macOS Keychain** is off by default for new profiles. Enable it and enter the VNC password to connect without typing it again. macOS may ask for Keychain access; a new development build may need renewed permission. The password field stays empty when a profile is selected. An entered password overrides the saved password for that connection only; it does not silently update Keychain.

Use **Edit…** to rename a profile or change its settings. Leave the saved-password field blank to keep its existing password. Changing the address or port requires entering a new password if you want to keep Keychain storage enabled. Temporarily changing the main connection fields does not change the profile, and a saved password is never automatically reused for a different address or port. Profile editing is disabled while connecting or connected.

Disable **Remember password** in the editor to remove its Keychain item. **Delete…** removes the profile and attempts to remove its saved password, without changing the remote host. If Keychain removal fails, Sharedesk reports the partial success; remove the remaining **Sharedesk VNC** item through Keychain Access. The Keychain service is `net.sharedesk.viewer.vnc-password`. Long status messages are available in full by hovering over the status text.

Settings live in `~/.sharedesk/profiles.json` on the Mac, with permission 600 inside a directory with permission 700. The JSON contains settings and optional credential references, never passwords. Writes replace the file atomically. Invalid, unreadable, oversized or externally changed files are not silently overwritten. Manual connections remain available if saved profiles cannot be loaded. Reopen the viewer after resolving a file error to reload its profiles.

A profile can remember that clipboard sharing is enabled, but neither selecting it nor connecting sends an old clipboard snapshot. Clipboard privacy and opt-in behaviour remain unchanged; encoding is negotiated per connection.

### Regenerate the viewer icon

The build packages `viewer/sharedesk-viewer.icns` for Finder and the Dock. Its artwork is defined in `viewer/make-icon.swift`; normal builds do not run the artwork generator. To regenerate the icon on macOS after editing that script:

```sh
icon_tmp=$(mktemp -d /tmp/sharedesk-icon.XXXXXX)
swift viewer/make-icon.swift "$icon_tmp/Sharedesk.iconset"
iconutil -c icns "$icon_tmp/Sharedesk.iconset" -o viewer/sharedesk-viewer.icns
rm -r "$icon_tmp"
cmake --build build-mac
```

The icon includes standard 1x and 2x representations from 16 to 1024 pixels, with simplified small-size geometry. Quit and reopen the viewer when convenient to load an updated icon; rebuilding does not restart a running connection. Finder or the Dock may retain a cached icon temporarily.

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

Port 5901 lets the existing `x11vnc` server keep port 5900 during comparison. Connect with the [Sharedesk viewer](#build-the-mac-viewer), or open `vnc://<Ubuntu Tailscale IPv4>:5901` using Screen Sharing and enter the new VNC password. After comparison, stop `x11vnc` and remove any access-policy rule for its port. Stop this host with Ctrl+C; it releases any input held by the viewer. If it cannot bind, check whether another process already uses that port.

The host follows Ubuntu desktop-size changes without restarting. Viewers that support VNC desktop resizing receive the new size and a full repaint. A viewer without resize support is disconnected and can reconnect at the new size; the host keeps listening.

Capture automatically uses the X11 MIT-SHM extension (`xshm`) when available. Xorg and the host share a private image buffer instead of transferring every image through the X11 socket. The buffer is rebuilt after desktop-size changes and released on shutdown. Its SysV shared-memory segment has mode 600 and is marked for automatic removal after both processes detach. If the extension, allocation, attachment or image read fails, the host releases the shared buffer and uses `XGetImage` (`xgetimage`) until restart. No capture-method flag is required; the Mac viewer is unchanged.

Screen-change detection automatically uses XDamage when available. It coalesces drawing notifications and captures at up to `--fps`, skipping unchanged screens between notifications. A full safety refresh still runs about once per second while connected, for applications/drivers that omit notifications. Without XDamage, or if tracking fails, the host returns to polling until restart. Connecting a viewer and resizing always request a fresh capture. Cursor position, cursor shape and input processing remain independent; screen-drawn cursor updates use a clean cached image, without requiring a new pixel read.

Ubuntu's cursor shape, hotspot (the pixel used for clicks) and position are tracked through X11's XFIXES extension and pointer queries. Viewers that support both cursor-shape and cursor-position updates render it locally. For shape-only viewers, the host hides the viewer cursor and draws Ubuntu's cursor into the screen stream instead, including local mouse movement. This fallback updates at `--fps`; try `--fps 30` if cursor motion feels slow. Viewers without cursor-shape support use LibVNCServer's screen-drawn cursor. If the cursor image is temporarily unavailable, the host keeps listening and retries the read.

Keyboard input uses the Ubuntu session's XKB map and active layout group. The host selects a key and the Shift/AltGr state needed for the requested character, rather than assuming a physical key position. It temporarily adjusts layout modifiers when needed and restores them; Control, Alt and Super shortcut modifiers remain unchanged. Mapping and repeat-setting changes are tracked through XKB notifications. Ordinary matching keys use native X11 repeat. Characters needing temporary modifier changes use complete taps and a host-driven repeat timer with Ubuntu's configured delay/rate, so they do not repeat under the restored modifier state. Duplicate viewer key-downs do not create a second repeat source. Viewer lock-key events do not toggle Ubuntu's Caps/Num/Scroll Lock settings. The host does not rewrite the server keymap or change its global repeat settings.

Optional flags: `--port` (1–65535, default 5900) and `--fps` (1–30, default 10). These set the TCP listening port and the maximum screen-capture rate. When run manually, the host stays in the foreground. Add `--stats` for performance summaries; see below. Ubuntu must remain awake for remote access, but its screen may be locked.

## Start automatically with the Ubuntu X11 desktop

After the manual connection works, install per-user graphical-session autostart **on Ubuntu** (not on the Mac). Use the same password file and port that worked manually:

```sh
python3 host/scripts/install-autostart.py --password-file "$HOME/.sharedesk/vnc-password" --port 5901
```

Do not use `sudo`. The installer copies the current build to `~/.local/libexec/sharedesk/` and creates `~/.config/autostart/sharedesk-host.desktop`. The desktop entry stays under `.config/autostart` because the graphical session looks there; the VNC password remains in `~/.sharedesk`. The installer waits for a Tailscale IPv4 address, then starts the host in the logged-in **X11** session. It does not log in at boot, restart a failed host, or keep the session awake. After rebuilding, run the installer again to copy the new executable.

Stop your manually started host with Ctrl+C before checking autostart at the **next graphical login**; otherwise both processes will try to use port 5901. If it does not connect, check `~/.local/state/sharedesk/host.log` (or `$XDG_STATE_HOME/sharedesk/host.log` if set) and verify the session is X11. Resolution changes do not require restarting the host. To check this, change the resolution in Ubuntu's Display settings while connected, then confirm the viewer follows the new size and mouse input still works.

To disable autostart and remove its installed executable:

```sh
python3 host/scripts/install-autostart.py --remove
```

This does not stop a host that is already running, and it leaves the password file and logs intact. Use `pgrep -a sharedesk-host` to find a running host and `kill <PID>` to stop it if needed.

## Text clipboard sharing

Clipboard sharing is **off by default**. Add `--clipboard` to enable two-way text sharing with the authenticated viewer:

```sh
./build/sharedesk-host --listen "$(tailscale ip -4)" \
  --password-file "$HOME/.sharedesk/vnc-password" \
  --port 5901 --fps 30 --stats --clipboard
```

To enable it in the installed autostart copy:

```sh
python3 host/scripts/install-autostart.py \
  --password-file "$HOME/.sharedesk/vnc-password" \
  --port 5901 --fps 30 --stats --clipboard
```

Restart the running host, or log out and back in locally, to load the new executable and options. The installer does not restart an existing process. This host uses standard VNC text messages, not Apple's private clipboard extensions. Use the Sharedesk viewer's clipboard checkbox to send and receive these standard messages. Clipboard interoperability with macOS Screen Sharing is not established; enabling **Edit → Use Shared Clipboard** does not prove that standard messages are being sent.

Only Ubuntu's **CLIPBOARD** selection (normal Copy/Paste) is shared. Selecting text for middle-click paste (**PRIMARY**) is not shared. The host does not send an existing Ubuntu clipboard snapshot when a viewer connects; it exports new clipboard changes while authenticated. Imported viewer text remains available to Ubuntu applications after disconnect, until another application takes ownership or the host stops. Pending exports and the per-connection echo cache are cleared on disconnect.

**Privacy:** enabled clipboard sharing is automatic and can transfer passwords or other sensitive text. Sharedesk keeps its clipboard buffers in memory and does not write their contents to logs or files. Other applications or clipboard managers may store shared text. To disable sharing, reinstall without `--clipboard` and restart the host. Preserve your other options, such as `--fps 30 --stats`.

Updated Sharedesk hosts and viewers negotiate the standard **Extended Clipboard** extension for full **UTF-8** text, including curly quotes, non-Latin scripts, combining characters and emoji. The extension uses CRLF line endings and a terminating NUL on the wire; local UTF-8 imports use LF. The limit is **1 MiB per encoded text format**, including those line endings and the terminator, so UTF-8 content has at most 1 MiB minus one byte. Compressed message buffers and inflated data are both bounded.

Classic peers still use **Latin-1**, up to the original **1 MiB** of text. Sharedesk can use that lossless path even on a Unicode-capable connection if a Latin-1 copy's UTF-8 form is too large. It never guesses UTF-8 in a classic message or replaces unsupported characters. An older host must be rebuilt and its installed copy updated for full Unicode; updating only the viewer retains Latin-1 compatibility.

Invalid UTF-8, embedded NUL bytes, missing extended terminators and unsupported/oversized local copies are rejected rather than corrupted or shortened. Malformed compressed data or oversized wire headers can disconnect the offending peer; the host listener remains available. Images, files and formatted clipboard data are not transferred. Large incremental X11 reads are bounded and time out after two seconds; an unavailable clipboard owner does not stop desktop sharing. Only the latest offered text is retained when needed to answer protocol requests; disabling viewer sharing clears that offer, and connection cleanup frees it. Capability negotiation and re-enabling sharing do not export an old local copy.

For missing clipboard transfers, `--stats` reports the running host's `clipboard=on/off` setting plus content-free counters. During the five-second window containing a Mac copy, `clip_rx=0` means no authenticated standard clipboard message reached the host callback. A positive `clip_rx` with `clip_imports=0` means the message was received but not accepted for import (for example, sharing is off or the text was rejected). Positive `clip_imports` counts accepted X11 ownership requests, not confirmation that a particular application pasted the text. In Ubuntu Terminal, paste with **Ctrl+Shift+V** or right-click → **Paste**, not macOS Cmd+V.

## Performance statistics

Statistics are off by default. Add `--stats` to print one summary to stderr every five seconds, including idle periods:

```sh
./build/sharedesk-host --listen "$(tailscale ip -4)" \
  --password-file "$HOME/.sharedesk/vnc-password" --port 5901 --stats
```

For autostart, enable the same option when updating its installed copy:

```sh
python3 host/scripts/install-autostart.py \
  --password-file "$HOME/.sharedesk/vnc-password" --port 5901 --stats
```

Restart the host to load the updated launcher. Autostart summaries go to `~/.local/state/sharedesk/host.log` (or `$XDG_STATE_HOME/sharedesk/host.log` if set). To disable them, run the installer without `--stats` and restart the host. Enabling statistics needs no additional dependencies beyond those listed in the build instructions.

An example summary with illustrative values:

```text
Stats 5.0s: viewer=active size=1920x1080 capture=xshm changes=xdamage captures=49 fps=9.8 cursor_frames=12 capture_ms(avg/max)=8.20/12.30 grab_ms(avg/max)=5.10/7.40 vnc_bytes=245760 vnc_KiB/s=48.0 cpu=9.2% clipboard=off clip_rx=0 clip_imports=0 clip_tx=0
```

| Field | Meaning |
| --- | --- |
| `viewer` / `size` | Current connection state (`idle`, `auth`, or `active`) and VNC framebuffer size at reporting time. |
| `capture` | Selected capture method at reporting time: `xshm` or `xgetimage`. An interval that includes a fallback can contain timings from both methods. |
| `changes` | Screen-change detection at reporting time: `xdamage` or `poll`. |
| `captures` / `fps` | Successful pixel captures and captures per elapsed second. With XDamage, unchanged screens normally show about 1 fps from safety refreshes; lower rates are expected, not a viewer frame-rate limit. This is not the viewer's displayed frame rate. Startup capture, failed reads and idle geometry checks are excluded. |
| `cursor_frames` | Cached framebuffer recompositions for screen-drawn cursor changes without a new pixel read. Native viewer/LibVNCServer cursor updates are not counted here. |
| `capture_ms(avg/max)` | Average and maximum capture-pipeline time in milliseconds, including the X11 read, conversion, cursor composition, tile comparison and resize work. It does not time the normal framebuffer encoding/send step. |
| `grab_ms(avg/max)` | Average and maximum image-read time in milliseconds (`XShmGetImage` or `XGetImage`). Includes both read attempts if a shared-memory read fails and falls back; excludes buffer setup/cleanup, which is included in `capture_ms`. |
| `vnc_bytes` / `vnc_KiB/s` | LibVNCServer-accounted bytes and estimated encoded VNC traffic per second (1 KiB = 1024 bytes). Counts continue across reconnects within a reporting interval. |
| `cpu` | Process user + system CPU time divided by elapsed time; 100% means one CPU core. Includes all host threads, but not Xorg or Tailscale CPU use. |
| `clipboard` | Runtime text clipboard setting: `on` or `off`. |
| `clip_rx` / `clip_imports` / `clip_tx` | Authenticated standard clipboard messages received / accepted imports / outgoing send attempts during this reporting interval. These count messages, not contents or successful pastes. |

Capture times average only frames that read pixels; cursor-only work is included in CPU use, not those averages. Capture times show `n/a` when no pixels were captured; CPU shows `n/a` if process CPU accounting is unavailable. Each summary covers the actual elapsed interval, including any time before connecting or after disconnecting. An idle resize can still cause a capture. A blocked event loop can delay a summary beyond five seconds.

Traffic is an estimate from the library's counters, not an exact socket or network measurement. It excludes connection-handshake traffic, TCP/Tailscale overhead and retransmissions, and may count prepared data after a failed write. These statistics do not measure end-to-end input latency. Summaries stay in your local output/logs; no telemetry is sent elsewhere.

## Current limits

- Desktop size is limited to 8192×8192 pixels. If a running desktop exceeds that limit, or replacement framebuffers cannot be allocated, the host disconnects the viewer and pauses capture. It keeps listening and retries until the desktop can be captured again.
- Reads full-screen images when needed and sends changed 64×64 regions. XDamage reduces unchanged-screen work, but safety refreshes and the polling fallback still read pixels. This is not video-based streaming; CPU use and motion depend on drawing, capture, encoding and the network.
- X11 keys, pointer buttons and scrolling. Keyboard symbols must be available in the active Ubuntu layout group; unsupported symbols are ignored rather than added to the local keymap. Layout-group switching and locked/latched layout modifiers are not synthesized. Some Mac-specific keys may not map. Local and remote input share the X11 keyboard; they are not isolated devices.
- Standard VNC cursor-shape updates have one-bit transparency, so soft edges are approximate. Screen-drawn cursors preserve alpha blending. Cursor images above 1024×1024 pixels are ignored; cursors too large for LibVNCServer's cursor-update buffer are drawn in the screen stream for shape-capable viewers.
- One viewer at a time. Optional text clipboard sharing only; no audio, file transfer, or login-screen access.
- Existing X11 session only; after reboot, a user must start a desktop session locally.
