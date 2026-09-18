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
macOS are not HID features; they come from fields on the `CGEvent` itself
(`IsContinuous`, `ScrollPhase`, `MomentumPhase`). No HID or DriverKit driver can set them.
The only real fix is userspace: read the reports, rescale, and post continuous scroll events
with the right phases. That is what bowheel does.

## Requirements

- macOS 14 or later (tested on 26.3), Apple Silicon or Intel
- If you use Karabiner-Elements: disable the dial there (see below)

## Install

### From a release

Download `bowheel-<version>.zip` from [Releases](../../releases), then:

```sh
unzip bowheel-*.zip && cd bowheel-*/
./install.sh
```

That copies `Bowheel.app` to `/Applications` and launches it. On first launch macOS asks for
two permissions and Bowheel shows a setup window that tracks them:

1. **Input Monitoring** — to read the dial
2. **Accessibility** — to post scroll events

Enable **Bowheel** in each list. It relaunches itself once both are granted. Then turn on
**Start at login** in its menu.

The app is not notarized (that needs a paid Apple developer account), so a copy downloaded
through a browser is quarantined and Gatekeeper refuses to open it. `install.sh` clears
that flag, which is why it exists; `xattr -dr com.apple.quarantine Bowheel.app` does the
same by hand.

**Upgrading from 0.1.x:** `install.sh` removes the old root daemon (asks for your
password). The old `bowheel` entries in Input Monitoring and Accessibility can be deleted.

### From source

```sh
./build-gui.sh      # Bowheel.app   (universal, macOS >= 14)
./build.sh          # bowheel CLI, for diagnostics
./install.sh
```

`./release.sh <version>` builds both and produces `dist/bowheel-<version>.zip` plus a SHA-256.

**Upgrading a source build:** the app is ad-hoc signed, so every build has a new code
hash and macOS treats it as a new app: it will ask for both permissions again.

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
- **Scroll the focused window** — off: the dial scrolls whatever is under the cursor, like
  a real wheel (events go in at the HID tap and macOS routes them). On: it scrolls the
  window you're working in wherever the mouse is parked. Events are posted at the session
  tap located inside the frontmost window, and because WindowServer warps the cursor to any
  located event, the cursor is warped straight back — both happen inside one frame, so it
  never visibly moves. (`postToPid` was tried first: it delivers but never scrolls.)
- **Acceleration** — gain rises with rotation speed. Below *Kicks in at* the gain is exactly
  1, so slow, deliberate turns stay precise; above it the gain ramps toward *Max gain*.
  `gain = min(max, 1 + strength × ((speed − start) / 10)^1.5)` with speed in detents/s.
- **Hide menu bar icon** — Bowheel keeps running without an icon (it stays hidden across
  login too). To get it back, open Bowheel again from Applications or Spotlight: the
  running copy notices and shows the icon.
- **Software momentum** — off by default. The dial is a physical flywheel and already
  free-spins; turn this on if you stop the dial by hand and want the page to coast.
  **Glide** sets how long (friction time constant). The glide picks up at the speed you were
  actually going, ~40 ms after the dial stops, and touching the dial cancels it.

Settings apply immediately and persist across launches.

The status line shows whether the dial is attached, reports per second while you turn it,
and what is wrong when something is (a missing permission, or another app holding the dial).

## How it works

Everything runs inside `Bowheel.app`, in your login session — no daemon, no root:

```
Bowheel.app
  ├─ IOHIDManager, seized, matched on 0xFEED:0xBEEF
  ├─ report ID 3: [03][wheel lo][wheel hi][pan lo][pan hi]  int16 LE
  ├─ ÷120 → pixels, × acceleration gain, fractional carry
  └─ CGEvent scroll, pixel units, IsContinuous=1, phase began→changed→ended
```

Three gates have to be open before it receives anything, and two of them fail *silently*:

1. **Exclusive access** — nothing else may have the dial seized (Karabiner, above). Fails
   loudly with `kIOReturnExclusiveAccess`; the app keeps retrying every 3 s and says so.
2. **Input Monitoring** — without it a seizing open fails with `kIOReturnNotPermitted`, and
   a shared open succeeds but the report queue stays empty forever.
3. **Accessibility** — without it `CGEvent.post` succeeds and the event is silently dropped:
   reports flow in, nothing scrolls. This one hides during development, because a run
   started from a terminal is charged to the terminal, which usually already has it.

The app asks for both permissions on first launch (`IOHIDRequestAccess`,
`AXIsProcessTrustedWithOptions`). macOS caches its answer per process, so the app polls
from a short-lived child (`--check-access` / `--check-post`) and relaunches once both are
granted — the HID manager must be opened by a process that had access from the start.

Phases matter: browsers (WebKit, Chromium) drop a `changed` stream that never had a `began`,
while AppKit scroll views don't care. `began` is therefore always posted even at zero delta,
exactly as a real trackpad does.

## Command line

`bowheel` is the same engine without the menu bar, for diagnostics. It needs the same two
permissions; run from Terminal and it borrows Terminal's. Quit Bowheel.app first — only one
process can hold the dial.

| flag | |
|---|---|
| `--debug --dry-run` | print decoded reports and the events it *would* post; posts nothing |
| `--debug` | same, while scrolling for real |
| `--simulate-flick` | run a synthetic flick through the engine, no hardware, posts nothing |
| `--probe` / `--reset` | read / restore the dial's Resolution Multiplier feature report |
| `--watch` | print every scroll event on the system with its CGEvent fields — pixels, lines, phase, momentum, posting pid — whether from bowheel, a trackpad or a mouse |
| `--list` | show matching HID devices |
| `--config <path>` | headless mode with a hot-reloaded JSON settings file |

`./trace.sh` captures 25 s of live scrolling with a timestamped log of every report and
posted event (`trace.log`), then relaunches the app.

`--watch` is the native counterpart of `scroll-test.html`: browsers hide the phase and
momentum fields, the tap shows them on the actual events.

`scroll-test.html` (open it in a browser) lists every `wheel` event with its pixel delta
and the gap since the previous one, and graphs them — the quickest way to see the phase
sequence, acceleration and glide actually arriving in a page.

## Logs

Everything of interest goes to the unified log under subsystem `org.bowheel` (categories
`app` and `engine`): permission state, device appear/disappear and which transport is
being listened to, open failures with their `IOReturn`, and settings changes.

```sh
/usr/bin/log show --last 1h --predicate 'subsystem == "org.bowheel"' --style compact
```

(`/usr/bin/log` because zsh has a builtin `log` that shadows it.) That's the thing to ask for when it misbehaves on a machine you can't sit at. Per-report
`--debug` output is deliberately kept out of it.

## Bluetooth

The dial speaks USB and Bluetooth LE with the same VID/PID and report layout. Bowheel
tracks every matching device but listens to one at a time, preferring USB, and switches
as they come and go — so a dial that is paired *and* plugged in doesn't feed two streams.
The status line shows which transport is live. The Bluetooth path is written to the
same code and untested: this dial has only ever been on USB here.

## Notes for hackers

- Feature report 2 (the Resolution Multiplier) is 2 bytes on the wire: `[02][value]`.
  Factory value is `[02 05]` = wheel hi-res, pan hi-res. Writing it with a bare 1-byte
  payload silently writes the wrong field; the ID byte has to be in the buffer. Writing it
  at all is opt-in (`--multiplier`) — leave it alone.
- `IOReturn` is a signed `Int32`; `String(r, radix: 16)` prints garbage like `-1ffffd3b`
  for `0xE00002C5`. `ioReturnName()` decodes it unsigned and names it.
- bowheel 0.1.x ran the engine as a root LaunchDaemon with a separate menu bar app talking
  to it through JSON files. That worked but root is not exempt from either TCC gate, a
  daemon can't show the permission prompts, and TCC's per-process cache made "granted but
  still red" a recurring support problem. 0.2 moved the engine into the app — the design
  [BoDial](https://github.com/IanBullard/BoDial) uses — and the CLI keeps `--config` for
  anyone who still wants it headless.
- The device is a composite: CDC-ACM serial on interfaces 0/1 (silent at 115200, with and
  without DTR) and HID on interface 2. Report ID 5 is a plain fallback collection; not seen
  in practice.

## Credits

The dial is by [Engineer Bo](https://www.patreon.com/EngineerBo). This is an independent
host-side tool, not affiliated.

## License

MIT — see [LICENSE](LICENSE).
