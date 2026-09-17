# bowheel

Trackpad-style scrolling on macOS for the [Engineer Bo Full Scroll Dial](https://www.youtube.com/watch?v=tzqJ1rJURgs) —
a high-resolution, free-spinning scroll wheel that macOS otherwise ignores.

A root daemon reads the dial's raw HID reports and synthesizes native continuous-scroll
events with proper gesture phases, so every app treats it like a trackpad. A menu bar app
tunes speed and acceleration live.

## Why macOS needs this

The dial implements the HID *Resolution Multiplier* (120 hi-res units per detent). That is a
Microsoft "Enhanced Wheel Support" mechanism: Windows negotiates it and divides by 120.
macOS never negotiates it and does not parse the wheel axis inside the multiplier's logical
collection at all, so on its own macOS gets **nothing** from this dial. If Karabiner-Elements
has the device, it re-emits the wheel — but treats each of the 120 units as a full detent, so
you get roughly 120× overspeed.

Fixing the scale is not enough for trackpad feel. Momentum, inertia and rubber-banding on
macOS are not HID features; they come from private fields on the `CGEvent`
(`IsContinuous`, `ScrollPhase`, `MomentumPhase`). No HID or DriverKit driver can set them.
The only real fix is userspace: read the reports, rescale, and post continuous scroll events
with the right phases. That is what bowheel does.

## Requirements

- macOS 14 or later (tested on 26.3)
- Xcode command line tools (`swiftc`)
- An admin account (the daemon runs as root; the menu bar app needs `admin` group membership
  to write the shared config)
- If you use Karabiner-Elements: disable the dial there (see below)

## Install

### From a release

Download `bowheel-<version>.zip` from [Releases](../../releases), then:

```sh
unzip bowheel-*.zip && cd bowheel-*/
sudo ./install.sh
```

The binaries are universal (Apple Silicon and Intel) and need macOS 14 or later. They are
not Developer-ID signed or notarized — `install.sh` clears the download quarantine on the
files it installs, which is why it needs to be run rather than the app double-clicked out of
the zip. If you'd rather not run the installer, `xattr -dr com.apple.quarantine` on the
files does the same thing by hand.

### From source

```sh
./build.sh          # daemon  -> ./bowheel        (universal, macOS >= 14)
./build-gui.sh      # menu bar app -> ./Bowheel.app
sudo ./install.sh   # root LaunchDaemon + /Applications/Bowheel.app
```

`./release.sh 1.0.0` builds both and produces `dist/bowheel-1.0.0.zip` plus a SHA-256.

Then two settings steps:

1. **Input Monitoring.** `install.sh` opens System Settings → Privacy & Security → Input
   Monitoring; enable **bowheel** there. Root is not exempt from this gate — without it the
   daemon opens the dial and simply never receives a report. The daemon registers itself in
   that list on first run and restarts on its own once ticked.
2. Add **Bowheel** to System Settings → General → Login Items so the menu bar icon is there
   at every login. The daemon itself starts at boot regardless.

`sudo ./uninstall.sh` removes everything.

### Karabiner-Elements

Karabiner seizes pointing devices by default, and while it holds the dial nothing else can
open it (`kIOReturnExclusiveAccess`). In Karabiner-Elements → Settings → Devices, untick
**Full Scroll Dial**. Scrolling goes dead at that moment — expected, since macOS ignores the
dial natively — and bowheel takes over from there. Karabiner keeps working for everything
else.

## Tuning

Click the dial icon in the menu bar:

- **Scroll speed** — pixels per detent
- **Invert direction**
- **Acceleration** — gain rises with rotation speed. Below *Kicks in at* the gain is exactly
  1, so slow, deliberate turns stay precise; above it the gain ramps toward *Max gain*.
  `gain = min(max, 1 + strength × ((speed − start) / 10)^1.5)` with speed in detents/s.
- **Software momentum** — off by default. The dial is a physical flywheel and already
  free-spins; synthetic inertia on top double-counts.

Settings are written to `/Library/Application Support/bowheel/config.json` and the daemon
hot-reloads them within half a second. You can also edit the file directly. Invalid JSON is
rejected and the last good settings stay live; the error shows in the menu.

The status line shows whether the daemon is up, whether the dial is attached, and reports
per second while you turn it.

## How it works

```
Bowheel.app  (your user)   ── atomic write ──▶  config.json     ┐
                                                                 │  root:admin 775
bowheel daemon (root)      ── every 1 s ─────▶  status.json     ┘
        │
        ├─ IOHIDManager, seized, matched on 0xFEED:0xBEEF
        ├─ report ID 3: [03][wheel lo][wheel hi][pan lo][pan hi]  int16 LE
        ├─ ÷120 → pixels, × acceleration gain, fractional carry
        └─ CGEvent scroll, pixel units, IsContinuous=1, phase began→changed→ended
```

Three gates all have to be open before the daemon receives anything, and every one of
them fails *silently* — the device opens, the queue just stays empty:

1. **Exclusive access** — nothing else may have the dial seized (Karabiner, above). This
   one at least reports `kIOReturnExclusiveAccess`.
2. **Root** — needed to seize the device.
3. **Input Monitoring (TCC)** — root is not exempt. The daemon checks with
   `IOHIDCheckAccess`, registers itself with `IOHIDRequestAccess` so it shows up in the
   System Settings list, and exits once granted so launchd restarts it with access. The
   menu bar app shows this state in red with a button to the right settings pane.

Phases matter: browsers (WebKit, Chromium) drop a `changed` stream that never had a `began`,
while AppKit scroll views don't care. `began` is therefore always posted even at zero delta,
exactly as a real trackpad does.

## Command line

`sudo ./bowheel --help` lists everything. Useful ones:

| flag | |
|---|---|
| `--debug --dry-run` | print decoded reports, post no events — the first thing to run if it isn't working |
| `--seize` | force seizing even with `--dry-run` |
| `--probe` / `--reset` | read / restore the dial's Resolution Multiplier feature report |
| `--list` | show matching HID devices |
| `--config <path>` | JSON runtime settings, hot-reloaded |

## Notes for hackers

- Feature report 2 (the Resolution Multiplier) is 2 bytes on the wire: `[02][value]`.
  Factory value is `[02 05]` = wheel hi-res, pan hi-res. Writing it with a bare 1-byte
  payload silently writes the wrong field; the ID byte has to be in the buffer. Writing it
  at all is opt-in (`--multiplier`) — leave it alone.
- `IOReturn` is a signed `Int32`; `String(r, radix: 16)` prints garbage like `-1ffffd3b`
  for `0xE00002C5`. `ioReturnName()` decodes it unsigned and names it.
- The daemon polls `config.json`'s mtime rather than using vnode events because the app
  writes atomically (temp file + `rename`), which replaces the inode every save.
- The device is a composite: CDC-ACM serial on interfaces 0/1 (silent at 115200, with and
  without DTR) and HID on interface 2. Report ID 5 is a plain fallback collection; not seen
  in practice.

## Credits

The dial is by [Engineer Bo](https://www.patreon.com/EngineerBo). This is an independent
host-side tool, not affiliated.

## License

MIT — see [LICENSE](LICENSE).
