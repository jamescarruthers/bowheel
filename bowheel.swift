//
//  bowheel — trackpad-style scrolling for the Engineer Bo "Full Scroll Dial" on macOS
//
//  Why this exists:
//    The dial implements the HID Resolution Multiplier (120 hi-res units = 1 detent).
//    That is a Microsoft "Enhanced Wheel Support" mechanism. macOS never negotiates it,
//    so IOHIDFamily treats every one of those 120 units as a full scroll detent and you
//    get ~120x overspeed.
//
//    Fixing the scale alone is not enough to feel like a trackpad. Momentum, inertia and
//    rubber-banding on macOS are not HID features at all — they come from private fields
//    on the CGEvent (IsContinuous / ScrollPhase / MomentumPhase). No HID or DriverKit
//    driver can emit those. So the only real fix is userspace: read the raw HID reports,
//    rescale, and synthesize proper continuous scroll events.
//
//  Build:  ./build.sh
//  Run:    sudo ./bowheel --debug        (see raw reports)
//          sudo ./bowheel               (normal)
//

import Foundation
import IOKit
import IOKit.hid
import CoreGraphics

// MARK: - CGEvent scroll fields
//
// These three are the whole trick: AppKit reads them to decide an event is trackpad-style
// continuous scroll rather than a notched mouse wheel. They are public (CGEventTypes.h:
// kCGScrollWheelEventIsContinuous = 88, ScrollPhase = 99, MomentumPhase = 123) — the
// raw values are used only so this compiles against older SDKs where the Swift enum
// cases were missing.

let fIsContinuous   = CGEventField(rawValue: 88)!   // kCGScrollWheelEventIsContinuous
let fScrollPhase    = CGEventField(rawValue: 99)!   // kCGScrollWheelEventScrollPhase
let fMomentumPhase  = CGEventField(rawValue: 123)!  // kCGScrollWheelEventMomentumPhase

// Mirrors NSEvent.Phase
enum Phase: Int64 {
    case none = 0, began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128
}

// Mirrors NSEvent.Phase for momentum
enum Momentum: Int64 {
    case none = 0, begin = 1, cont = 2, end = 3
}


// MARK: - IOReturn decoding
//
// IOReturn is a signed Int32, so String(r, radix: 16) prints nonsense like "-1ffffd3b"
// for what is really 0xE00002C5. Always render it unsigned and name it.

func ioReturnName(_ r: IOReturn) -> String {
    let u = UInt32(bitPattern: r)
    let code = u & 0xFFF
    let names: [UInt32: String] = [
        0x000: "kIOReturnSuccess",
        0x2bc: "kIOReturnError",
        0x2bd: "kIOReturnNoMemory",
        0x2be: "kIOReturnNoResources",
        0x2c0: "kIOReturnNoDevice",
        0x2c1: "kIOReturnNotPrivileged",
        0x2c2: "kIOReturnBadArgument",
        0x2c5: "kIOReturnExclusiveAccess",
        0x2c7: "kIOReturnUnsupported",
        0x2cd: "kIOReturnNotOpen",
        0x2d5: "kIOReturnBusy",
        0x2d6: "kIOReturnTimeout",
        0x2d9: "kIOReturnNotAttached",
        0x2e2: "kIOReturnNotPermitted",
        0x2ed: "kIOReturnNotResponding",
    ]
    let name = (u == 0) ? "kIOReturnSuccess" : (names[code] ?? "unknown")
    return String(format: "0x%08x (%@)", u, name)
}

// MARK: - Config

struct Config {
    var vid: Int = 0xFEED
    var pid: Int = 0xBEEF

    /// Hi-res units the device sends per logical scroll detent. From the report
    /// descriptor's Physical Max on Usage 0x48 (Resolution Multiplier).
    var unitsPerDetent: Double = 120

    /// How many screen pixels one detent should scroll. Tune to taste.
    var pixelsPerDetent: Double = 55

    var invertY = false
    var invertX = false

    /// Software momentum. Off by default: the dial is a free-spinning physical flywheel,
    /// so it keeps emitting real reports after you let go.
    var momentum = false
    /// Glide friction, expressed as the fraction of velocity kept per 1/60 s. Applied
    /// against wall-clock, so it means the same thing at any timer rate.
    /// 0.94 ~ 260 ms time constant (short), 0.96 ~ 410 ms (trackpad-like), 0.98 ~ 825 ms.
    var momentumDecay: Double = 0.96
    /// Glide only starts if the hand-off speed exceeds this (px/s), and stops below
    /// momentumStop (px/s).
    var momentumTrigger: Double = 250
    var momentumStop: Double = 25
    /// When moving fast, reports arrive every 8 ms, so a gap this long already means the
    /// dial stopped. Handing off here instead of at idleEndMs removes the visible stall.
    var momentumHandoffMs: Double = 40
    /// Constant deceleration (px/s^2) on top of the exponential decay. Pure exponential
    /// has an endless crawl at the tail; this makes the glide come to a definite stop the
    /// way a trackpad's does. Negligible at speed, decisive below ~600 px/s.
    var momentumDrag: Double = 1500

    /// Acceleration. Gain applied to each delta as a function of rotation speed:
    ///   gain = min(accelMax, 1 + accel * ((speed - accelStart) / 10)^1.5)
    /// with speed in detents/sec. Below accelStart the gain is exactly 1, so slow,
    /// deliberate turns stay 1:1 for precision. 0 disables.
    var accel: Double = 1.0
    var accelMax: Double = 4.0
    var accelStart: Double = 2.0

    /// Idle gap after which we close the gesture with a phase=ended event.
    var idleEndMs: Double = 150

    /// Seize the device so macOS does not also deliver its own 120x-too-fast events.
    /// Requires root. Without it you get double scrolling.
    var seize = true

    var debug = false
    var dryRun = false
    var listOnly = false
    var simulate = false

    /// JSON file of runtime settings, hot-reloaded on change. Written by the menu bar
    /// app. CLI flags are the defaults; the file overrides them.
    var configPath: String? = nil
    /// Where the daemon publishes live state for the GUI. Defaults next to the config.
    var statusPath: String? = nil

    /// Value to write to feature report 2 (Resolution Multiplier).
    /// nil means DO NOT TOUCH IT — writing changes persistent device state, so it is
    /// strictly opt-in. Forcing hi-res mode can leave the dial emitting sub-detent
    /// deltas that macOS rounds to zero, i.e. no scrolling at all.
    var multiplier: Int? = nil

    /// Attach, write/read feature report 2, print, exit. For rescuing device state.
    var resetOnly = false
}

func parseArgs() -> Config {
    var c = Config()
    var resetRequested = false
    var seizeRequested = false
    var it = CommandLine.arguments.dropFirst().makeIterator()

    func nextVal(_ flag: String) -> String {
        guard let v = it.next() else {
            FileHandle.standardError.write("bowheel: \(flag) needs a value\n".data(using: .utf8)!)
            exit(2)
        }
        return v
    }

    while let a = it.next() {
        switch a {
        case "--vid":              c.vid = Int(nextVal(a).replacingOccurrences(of: "0x", with: ""), radix: 16) ?? c.vid
        case "--pid":              c.pid = Int(nextVal(a).replacingOccurrences(of: "0x", with: ""), radix: 16) ?? c.pid
        case "--units-per-detent": c.unitsPerDetent = Double(nextVal(a)) ?? c.unitsPerDetent
        case "--pixels", "--pixels-per-detent":
                                   c.pixelsPerDetent = Double(nextVal(a)) ?? c.pixelsPerDetent
        case "--idle-ms":          c.idleEndMs = Double(nextVal(a)) ?? c.idleEndMs
        case "--accel":            c.accel = Double(nextVal(a)) ?? c.accel
        case "--accel-max":        c.accelMax = Double(nextVal(a)) ?? c.accelMax
        case "--accel-start":      c.accelStart = Double(nextVal(a)) ?? c.accelStart
        case "--decay":            c.momentumDecay = Double(nextVal(a)) ?? c.momentumDecay
        case "--invert":           c.invertY = true
        case "--invert-x":         c.invertX = true
        case "--momentum":         c.momentum = true
        case "--no-seize":         c.seize = false
        case "--seize":            seizeRequested = true
        case "--debug":            c.debug = true
        case "--dry-run":          c.dryRun = true; c.seize = false
        case "--list":             c.listOnly = true; c.seize = false
        case "--simulate-flick":
            // Feeds a ramping flick through the real engine with no hardware and posts
            // nothing. For measuring hand-off gap and velocity continuity.
            c.simulate = true; c.dryRun = true; c.seize = false; c.momentum = true
        case "--check-post":
            // Child-process probe for Accessibility; see checkPostAccess().
            let ok = CGPreflightPostEventAccess()
            print(ok ? "granted" : "denied")
            exit(ok ? 0 : 1)
        case "--check-access":
            // Used by the daemon itself, from a child process. See freshInputMonitoringState().
            let st = inputMonitoringState()
            print(st)
            exit(st == "granted" ? 0 : 1)
        case "--config":           c.configPath = nextVal(a)
        case "--status":           c.statusPath = nextVal(a)
        case "--multiplier":       c.multiplier = Int(nextVal(a))
        case "--reset":            resetRequested = true; c.seize = false
        case "--probe":            c.resetOnly = true; c.seize = false
        case "-h", "--help":
            print("""
            bowheel — trackpad-style scrolling for the Full Scroll Dial

            USAGE
              sudo bowheel [options]

            OPTIONS
              --pixels <n>            pixels scrolled per detent (default 55)
              --units-per-detent <n>  hi-res units per detent (default 120)
              --accel <k>             acceleration strength (default 1.0; 0 = off)
              --accel-max <g>         gain cap (default 4.0)
              --accel-start <d/s>     speed in detents/sec where gain starts (default 2.0)
              --invert                flip vertical scroll direction
              --invert-x              flip horizontal scroll direction
              --momentum              add synthetic inertia after release (off by default;
                                      the dial already free-spins in hardware)
              --decay <0..1>          glide: velocity kept per 1/60 s (default 0.96; higher = longer)
              --idle-ms <n>           idle gap that ends a gesture (default 150)
              --no-seize              do not grab the device (expect double scrolling)
              --seize                 force seizing even with --dry-run (needs root)
              --dry-run               decode and print, post no events
              --debug                 print raw reports and decoded deltas
              --config <path>         JSON runtime settings, hot-reloaded (GUI writes this)
              --status <path>         where to publish live status JSON (default: beside config)
              --check-access          print Input Monitoring state (granted/denied/unknown) and exit
              --list                  list matching HID devices and exit
              --probe                 read feature report 2 (resolution multiplier) and exit
              --reset                 restore the factory multiplier ([02 05]) and exit
              --multiplier <n>        write resolution multiplier (default: leave alone)
              --vid / --pid <hex>     override device match (default feed/beef)

            NOTES
              Run as root so the device can be seized; otherwise macOS delivers its own
              120x-too-fast events alongside ours.
              Karabiner-Elements must not have the dial grabbed — uncheck it under Devices.
            """)
            exit(0)
        default:
            FileHandle.standardError.write("bowheel: unknown option \(a)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    // --seize wins over the implicit no-seize of --dry-run, so seize+dry-run is testable.
    if seizeRequested { c.seize = true }
    // Resolve --reset last so an explicit --multiplier wins whatever the arg order.
    if resetRequested {
        c.resetOnly = true
        if c.multiplier == nil { c.multiplier = 1 }   // 1 => [02 05], the factory value
    }
    return c
}

// MARK: - Engine

final class Engine {
    private(set) var cfg: Config
    private var source: CGEventSource?

    /// Set by DialWatcher; surfaced in the status file.
    var attached = false

    /// Replace runtime settings in place. Only the tunables — device match, seize,
    /// debug and paths are fixed for the life of the process.
    func update(_ n: Config) {
        cfg.pixelsPerDetent = n.pixelsPerDetent
        cfg.accel = n.accel; cfg.accelMax = n.accelMax; cfg.accelStart = n.accelStart
        cfg.invertY = n.invertY; cfg.invertX = n.invertX
        cfg.momentum = n.momentum; cfg.momentumDecay = n.momentumDecay
        cfg.momentumTrigger = n.momentumTrigger
        cfg.idleEndMs = n.idleEndMs
    }

    // Fractional pixel carry, so slow rotation is not lost to integer truncation.
    private var carryY: Double = 0
    private var carryX: Double = 0

    // Gesture state
    private var inGesture = false
    private(set) var lastReportAt: CFAbsoluteTime = 0

    // Recent output deltas with timestamps. Hand-off velocity is measured over the last
    // 60 ms of wall-clock — an EMA lags a flick that is still speeding up, and a
    // per-report figure is meaningless once replayed at a different timer rate.
    private var samples: [(t: CFAbsoluteTime, dy: Double, dx: Double)] = []
    private var velY: Double = 0      // px/s, only meaningful while gliding
    private var velX: Double = 0
    private var gliding = false
    private var lastGlideAt: CFAbsoluteTime = 0
    private let t0 = CFAbsoluteTimeGetCurrent()

    // Rotation speed in detents/sec, exponentially smoothed (acceleration)
    private var speed: Double = 0

    private var momentumTimer: DispatchSourceTimer?
    private var reportCount = 0

    init(cfg: Config) {
        self.cfg = cfg
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    // MARK: Report decode

    /// Reports of interest, per the decoded descriptor:
    ///   ID 3 -> [Wheel int16 LE][AC Pan int16 LE]   (hi-res collection)
    ///   ID 5 -> [Wheel int16 LE][AC Pan int16 LE]   (fallback collection)
    /// Buttons/X/Y (IDs 1 and 4) are deliberately passed through untouched.
    func handleReport(id: UInt32, bytes: UnsafeMutablePointer<UInt8>, len: Int) {
        reportCount += 1
        let buf = UnsafeBufferPointer(start: bytes, count: max(0, len))
        var b = Array(buf)

        if cfg.debug {
            let hex = b.map { String(format: "%02x", $0) }.joined(separator: " ")
            FileHandle.standardError.write(String(format: "rpt %9.1fms id=%d len=%d [%@]\n",
                (CFAbsoluteTimeGetCurrent() - t0) * 1000, id, len, hex).data(using: .utf8)!)
        }

        guard id == 3 || id == 5 else { return }

        // macOS sometimes includes the leading report-ID byte in the buffer and sometimes
        // does not, depending on the transport. Detect and strip it rather than guess.
        if b.count == 5, UInt32(b[0]) == id {
            b.removeFirst()
        }
        guard b.count >= 4 else { return }

        let wheelUnits = Double(Int16(bitPattern: UInt16(b[0]) | (UInt16(b[1]) << 8)))
        let panUnits   = Double(Int16(bitPattern: UInt16(b[2]) | (UInt16(b[3]) << 8)))

        let now = CFAbsoluteTimeGetCurrent()

        // Speed must come from wall-clock, not report count: the dial only reports
        // while moving, so the interval between reports is itself part of the signal.
        var gain = 1.0
        if cfg.accel > 0 {
            if inGesture {
                let dt = min(max(now - lastReportAt, 0.004), 0.2)
                let inst = (abs(wheelUnits) + abs(panUnits)) / cfg.unitsPerDetent / dt
                speed = speed * 0.7 + inst * 0.3
            } else {
                speed = 0
            }
            let over = max(0, speed - cfg.accelStart)
            gain = min(cfg.accelMax, 1 + cfg.accel * pow(over / 10.0, 1.5))
        }

        let scale = cfg.pixelsPerDetent / cfg.unitsPerDetent * gain
        var dy = wheelUnits * scale
        var dx = panUnits * scale
        if cfg.invertY { dy = -dy }
        if cfg.invertX { dx = -dx }

        if cfg.debug {
            FileHandle.standardError.write(
                String(format: "   wheel=%+.0fu pan=%+.0fu speed=%.1fd/s gain=%.2f -> dy=%+.2fpx dx=%+.2fpx\n",
                       wheelUnits, panUnits, speed, gain, dy, dx).data(using: .utf8)!)
        }

        guard dy != 0 || dx != 0 else { return }

        stopMomentum()
        lastReportAt = now

        samples.append((now, dy, dx))
        if samples.count > 32 { samples.removeFirst(samples.count - 32) }

        let posted = emit(dy: dy, dx: dx, phase: inGesture ? .changed : .began, momentum: .none)
        if posted { inGesture = true }
    }

    // MARK: Emission

    @discardableResult
    private func emit(dy: Double, dx: Double, phase: Phase, momentum: Momentum) -> Bool {
        carryY += dy
        carryX += dx

        // Truncate toward zero and keep the remainder for the next report.
        let py = Int32(carryY.rounded(.towardZero))
        let px = Int32(carryX.rounded(.towardZero))
        carryY -= Double(py)
        carryX -= Double(px)

        // Phase boundaries must always go out, delta or not. Browsers enforce the
        // began -> changed -> ended sequence strictly and drop a `changed` stream that
        // never had a `began`. A slow start (1 unit = <1 px, truncates to 0) used to
        // swallow the began here while the caller still flipped into the gesture,
        // which is exactly why Terminal scrolled and Safari/Chrome went dead.
        let boundary = (phase == .began || phase == .ended || momentum == .end)
        guard py != 0 || px != 0 || boundary else { return false }

        // --debug logs every post as well, so a live (non-dry) run can be traced.
        if cfg.dryRun || cfg.debug {
            FileHandle.standardError.write(
                String(format: "   %7.1fms post dy=%d dx=%d phase=%@ momentum=%@\n",
                       (CFAbsoluteTimeGetCurrent() - t0) * 1000, py, px,
                       String(describing: phase), String(describing: momentum)).data(using: .utf8)!)
            if cfg.dryRun { return true }
        }

        guard let ev = CGEvent(scrollWheelEvent2Source: source,
                               units: .pixel,
                               wheelCount: 2,
                               wheel1: py,
                               wheel2: px,
                               wheel3: 0) else { return false }

        ev.setIntegerValueField(fIsContinuous, value: 1)
        ev.setIntegerValueField(fScrollPhase, value: phase.rawValue)
        ev.setIntegerValueField(fMomentumPhase, value: momentum.rawValue)
        ev.post(tap: .cghidEventTap)
        return true
    }

    // MARK: Gesture close-out / momentum

    /// Velocity in px/s over the last 60 ms before the final report. Needs a few samples:
    /// a lone blip is not a flick. Grabbing the dial to stop it shows up here as a run of
    /// shrinking deltas, so the measured speed is low and no glide starts — which is right.
    private func handoffVelocity() -> (Double, Double) {
        guard let last = samples.last else { return (0, 0) }
        let win = samples.filter { last.t - $0.t <= 0.060 }
        guard win.count >= 3 else { return (0, 0) }
        // +8 ms: each sample covers the report interval that preceded it.
        let span = (last.t - win[0].t) + 0.008
        return (win.reduce(0) { $0 + $1.dy } / span, win.reduce(0) { $0 + $1.dx } / span)
    }

    /// Called from a repeating timer. Ends the gesture once reports stop arriving.
    func tick() {
        guard inGesture else { return }
        let idleMs = (CFAbsoluteTimeGetCurrent() - lastReportAt) * 1000

        var (vy, vx) = (0.0, 0.0)
        var glide = false
        if cfg.momentum {
            (vy, vx) = handoffVelocity()
            glide = max(abs(vy), abs(vx)) >= cfg.momentumTrigger
        }
        guard idleMs >= (glide ? cfg.momentumHandoffMs : cfg.idleEndMs) else { return }

        inGesture = false
        speed = 0
        samples.removeAll(keepingCapacity: true)
        emit(dy: 0, dx: 0, phase: .ended, momentum: .none)

        if glide {
            velY = vy; velX = vx
            startMomentum()
        }
    }

    private func startMomentum() {
        var first = true
        gliding = true
        lastGlideAt = CFAbsoluteTimeGetCurrent()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let dt = min(max(now - self.lastGlideAt, 0.001), 0.05)
            self.lastGlideAt = now

            // Distance first at the current speed, then friction — so the very first
            // frame continues at exactly the hand-off velocity.
            let dy = self.velY * dt, dx = self.velX * dt
            let k = pow(self.cfg.momentumDecay, dt * 60.0)
            self.velY *= k; self.velX *= k
            let drag = self.cfg.momentumDrag * dt
            self.velY = abs(self.velY) <= drag ? 0 : self.velY - (self.velY > 0 ? drag : -drag)
            self.velX = abs(self.velX) <= drag ? 0 : self.velX - (self.velX > 0 ? drag : -drag)

            if max(abs(self.velY), abs(self.velX)) < self.cfg.momentumStop {
                self.stopMomentum()
                return
            }
            if self.emit(dy: dy, dx: dx, phase: .none, momentum: first ? .begin : .cont) {
                first = false
            }
        }
        momentumTimer = t
        t.resume()
    }

    /// Always closes the glide with momentum=end. Touching the dial mid-glide lands here
    /// too; without the end event apps see a new gesture inside a dangling momentum one.
    private func stopMomentum() {
        momentumTimer?.cancel()
        momentumTimer = nil
        guard gliding else { return }
        gliding = false
        velY = 0; velX = 0
        emit(dy: 0, dx: 0, phase: .none, momentum: .end)
    }

    var reportsSeen: Int { reportCount }
}

// MARK: - HID plumbing

final class DialWatcher {
    private let cfg: Config
    private let engine: Engine
    private var manager: IOHIDManager!
    private var buffers: [ObjectIdentifier: UnsafeMutablePointer<UInt8>] = [:]

    init(cfg: Config, engine: Engine) {
        self.cfg = cfg
        self.engine = engine
    }

    func start() {
        let opts: IOOptionBits = cfg.seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
                                           : IOOptionBits(kIOHIDOptionsTypeNone)
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: cfg.vid,
            kIOHIDProductIDKey as String: cfg.pid,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<DialWatcher>.fromOpaque(ctx).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<DialWatcher>.fromOpaque(ctx).takeUnretainedValue().detach(device)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let r = IOHIDManagerOpen(manager, opts)
        if r != kIOReturnSuccess {
            let u = UInt32(bitPattern: r) & 0xFFF
            var hint = "bowheel: could not open the dial — IOReturn \(ioReturnName(r))\n"

            switch u {
            case 0x2c5:  // kIOReturnExclusiveAccess
                hint += """
                        Another process has the device seized exclusively. On this machine that
                        is almost always Karabiner-Elements. Release it there:
                          Karabiner-Elements > Settings > Devices > uncheck "Full Scroll Dial"
                        Scrolling will go dead once Karabiner lets go — macOS ignores this dial's
                        wheel on its own. That is expected; bowheel takes over from there.
                        Check the current owner with:
                          ioreg -c IOHIDDevice -r -l | grep -A80 'Full Scroll Dial' | grep IOUserClientCreator

                        """
            case 0x2c1, 0x2e2:  // NotPrivileged / NotPermitted
                hint += """
                        Permission denied reading input reports. Either run under sudo, or grant
                        Input Monitoring to this binary:
                          System Settings > Privacy & Security > Input Monitoring > + > \(CommandLine.arguments[0])

                        """
            case 0x2c0, 0x2d9:  // NoDevice / NotAttached
                hint += "Device not attached. Check with: bowheel --list\n"
            default:
                hint += "Unexpected failure. Try --list to confirm the device is visible.\n"
            }

            if cfg.seize {
                hint += "Seizing was requested; --no-seize will open shared instead (expect double scrolling).\n"
            }
            FileHandle.standardError.write(hint.data(using: .utf8)!)
            exit(1)
        }
    }

    private func attach(_ device: IOHIDDevice) {
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
        let maxIn = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? -1

        log("attached: \(name)  maxInputReport=\(maxIn) primaryUsage=\(usage)")
        engine.attached = true

        // Resolution Multiplier (report 2, Usage 0x48). macOS never writes this itself,
        // which is the root of the scaling problem — but writing it changes device state
        // and can stop scrolling entirely, so it is opt-in only.
        if let m = cfg.multiplier {
            // Feature report 2 is 2 bytes on the wire: [reportID][value]. GetReport
            // hands back the ID in byte 0, so SetReport expects it there too — passing
            // a bare 1-byte payload silently writes the wrong field.
            // value bits: [1:0] = wheel multiplier, [3:2] = AC Pan multiplier.
            let n = UInt8(clamping: m) & 0x3
            var buf: [UInt8] = [0x02, n | (n << 2)]
            let r = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 2, &buf, buf.count)
            log(r == kIOReturnSuccess
                ? String(format: "  wrote resolution multiplier = %d (report 2 = [02 %02x])", m, buf[1])
                : "  FAILED to write feature report 2 — \(ioReturnName(r))")
        }

        // Read with the full report size. macOS is inconsistent about whether the
        // leading report-ID byte lives in the buffer, so dump raw bytes and let the
        // hex decide rather than assuming an offset.
        let fcap = (IOHIDDeviceGetProperty(device, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int) ?? 2
        var rb = [UInt8](repeating: 0, count: max(fcap, 2))
        var rbLen: CFIndex = rb.count
        let gr = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 2, &rb, &rbLen)
        if gr == kIOReturnSuccess {
            let hex = rb.prefix(max(Int(rbLen), 1)).map { String(format: "%02x", $0) }.joined(separator: " ")
            log("  feature report 2 raw = [\(hex)] len=\(rbLen) (cap \(fcap))")
        } else {
            log("  could not read feature report 2 — \(ioReturnName(gr))")
        }

        if cfg.resetOnly {
            log("done. If scrolling is still dead, unplug and replug the dial.")
            exit(0)
        }

        let cap = max(maxIn, 8)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        buf.initialize(repeating: 0, count: cap)
        buffers[ObjectIdentifier(device)] = buf

        let ctx = Unmanaged.passUnretained(engine).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buf, cap, { ctx, _, _, _, reportID, report, len in
            guard let ctx else { return }
            Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue()
                .handleReport(id: reportID, bytes: report, len: len)
        }, ctx)
    }

    private func detach(_ device: IOHIDDevice) {
        let key = ObjectIdentifier(device)
        if let buf = buffers.removeValue(forKey: key) { buf.deallocate() }
        engine.attached = false
        log("detached")
    }

    private func log(_ s: String) {
        FileHandle.standardError.write("bowheel: \(s)\n".data(using: .utf8)!)
    }
}

// MARK: - Runtime config file (hot reload) and status file

/// Keys the GUI may set. Anything else in the file is ignored.
func applyRuntimeJSON(_ obj: [String: Any], to c: inout Config) {
    func d(_ k: String) -> Double? { (obj[k] as? NSNumber)?.doubleValue }
    func b(_ k: String) -> Bool?   { (obj[k] as? NSNumber)?.boolValue }
    if let v = d("pixelsPerDetent"), v > 0      { c.pixelsPerDetent = v }
    if let v = d("accel"), v >= 0               { c.accel = v }
    if let v = d("accelMax"), v >= 1            { c.accelMax = v }
    if let v = d("accelStart"), v >= 0          { c.accelStart = v }
    if let v = d("idleEndMs"), v >= 20          { c.idleEndMs = v }
    if let v = d("momentumDecay"), v > 0, v < 1 { c.momentumDecay = v }
    if let v = d("momentumTrigger"), v >= 0     { c.momentumTrigger = v }
    if let v = b("invertY")                     { c.invertY = v }
    if let v = b("invertX")                     { c.invertX = v }
    if let v = b("momentum")                    { c.momentum = v }
}

func runtimeJSON(_ c: Config) -> [String: Any] {
    [
        "pixelsPerDetent": c.pixelsPerDetent,
        "accel": c.accel, "accelMax": c.accelMax, "accelStart": c.accelStart,
        "invertY": c.invertY, "invertX": c.invertX,
        "momentum": c.momentum, "momentumDecay": c.momentumDecay,
        "momentumTrigger": c.momentumTrigger,
        "idleEndMs": c.idleEndMs,
    ]
}

/// Polls the config file's mtime. Polling beats vnode watching here because the GUI
/// writes atomically (temp file + rename), which replaces the inode every save.
final class ConfigWatcher {
    private let path: String
    private let engine: Engine
    private var lastMTime: Date?
    private var lastError: String?

    init(path: String, engine: Engine) {
        self.path = path
        self.engine = engine
    }

    func start() {
        reload(initial: true)
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.reload(initial: false) }
        RunLoop.main.add(t, forMode: .common)
    }

    var error: String? { lastError }

    private func reload(initial: Bool) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let m = attrs[.modificationDate] as? Date else {
            if initial { log("no config file at \(path); using CLI defaults") }
            return
        }
        if let l = lastMTime, l == m { return }
        lastMTime = m

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "bowheel", code: 1, userInfo: [NSLocalizedDescriptionKey: "top level is not an object"])
            }
            var c = engine.cfg
            applyRuntimeJSON(obj, to: &c)
            engine.update(c)
            lastError = nil
            log(String(format: "config %@: %.0fpx/detent accel=%.2f max=%.1fx start=%.1fd/s%@%@%@",
                       initial ? "loaded" : "reloaded",
                       c.pixelsPerDetent, c.accel, c.accelMax, c.accelStart,
                       c.invertY ? " invert" : "", c.invertX ? " invert-x" : "", c.momentum ? " momentum" : ""))
        } catch {
            lastError = error.localizedDescription
            log("config parse failed, keeping last good: \(error.localizedDescription)")
        }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write("bowheel: \(s)\n".data(using: .utf8)!)
    }
}

/// Publishes live state once a second for the GUI. Atomic write, world-readable.
final class StatusWriter {
    private let path: String
    private let engine: Engine
    private let watcher: ConfigWatcher?
    private let started = Date()

    init(path: String, engine: Engine, watcher: ConfigWatcher?) {
        self.path = path
        self.engine = engine
        self.watcher = watcher
    }

    func start() {
        write()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.write() }
        RunLoop.main.add(t, forMode: .common)
    }

    private func write() {
        let now = CFAbsoluteTimeGetCurrent()
        let ago: Double? = engine.lastReportAt > 0 ? now - engine.lastReportAt : nil
        var obj: [String: Any] = [
            "pid": Int(getpid()),
            "ts": Date().timeIntervalSince1970,
            "uptime": Date().timeIntervalSince(started),
            "attached": engine.attached,
            "seized": engine.cfg.seize,
            "reports": engine.reportsSeen,
            "inputMonitoring": tccState,
            "accessibility": postState,
            "config": runtimeJSON(engine.cfg),
        ]
        if let a = ago { obj["lastReportAgo"] = a }
        if let e = watcher?.error { obj["configError"] = e }

        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        let tmp = path + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp))
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp)
            _ = rename(tmp, path)
        } catch {
            // Status is best-effort; never let it take the daemon down.
        }
    }
}

// MARK: - Input Monitoring (TCC)
//
// Root is NOT exempt from TCC for HID input. A root daemon that hasn't been granted
// Input Monitoring opens the device fine and simply never receives a report — the same
// silent failure Karabiner's grabber has. IOHIDRequestAccess registers this binary in
// the Input Monitoring list (and prompts, when a GUI session can show one) so the user
// can tick it rather than navigate to /usr/local/bin. Once granted we exit and let
// launchd's KeepAlive restart us with access.

var tccState = "unknown"

func inputMonitoringState() -> String {
    switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
    case kIOHIDAccessTypeGranted: return "granted"
    case kIOHIDAccessTypeDenied:  return "denied"
    default:                      return "unknown"
    }
}

/// Must run BEFORE the device is opened: with seize requested, the open itself fails
/// with kIOReturnNotPermitted when access is missing, so anything after it never runs
/// and the binary never registers in the Input Monitoring list. Returns true if access
/// is already granted; otherwise registers, schedules the poll, and the caller should
/// skip opening the device and just park in the run loop.
/// Second TCC gate, on the output side: posting synthetic events needs Accessibility
/// (kTCCServicePostEvent). Without it CGEvent.post succeeds and the event is silently
/// dropped. Runs started from a terminal inherit the terminal's grant, which hides the
/// problem until the binary runs under launchd with its own identity.
var postState = "unknown"

func checkPostAccess() {
    if CGPreflightPostEventAccess() {
        postState = "granted"
        return
    }
    postState = "denied"
    _ = CGRequestPostEventAccess()   // registers the binary in the Accessibility list
    FileHandle.standardError.write("""
        bowheel: Accessibility is NOT granted — reports are read but scroll events are dropped.
          System Settings > Privacy & Security > Accessibility > enable "bowheel".
          If it is not in the list: click +, press Shift-Cmd-G, enter
          \(CommandLine.arguments[0])
          It takes effect without a restart.

        """.data(using: .utf8)!)

    // The answer above is cached for the life of this process, but the grant itself is
    // honoured immediately — so without this the status would say "denied" forever while
    // scrolling works. Re-ask from a fresh child until it flips.
    let t = Timer(timeInterval: 3.0, repeats: true) { timer in
        if freshState("--check-post") == "granted" {
            postState = "granted"
            FileHandle.standardError.write("bowheel: Accessibility granted\n".data(using: .utf8)!)
            timer.invalidate()
        }
    }
    RunLoop.main.add(t, forMode: .common)
}

/// TCC answers are cached per process: once this process has been told "denied", it keeps
/// hearing "denied" even after the user flips the switch. Polling IOHIDCheckAccess in
/// place therefore never notices a grant. A short-lived child of the same binary has the
/// same TCC identity and gets a fresh answer.
func freshInputMonitoringState() -> String { freshState("--check-access") }

func freshState(_ flag: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = [flag]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "unknown" }
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let st = out.trimmingCharacters(in: .whitespacesAndNewlines)
    return ["granted", "denied", "unknown"].contains(st) ? st : "unknown"
}

func startInputMonitoringWatch() -> Bool {
    tccState = inputMonitoringState()
    guard tccState != "granted" else {
        FileHandle.standardError.write("bowheel: Input Monitoring granted\n".data(using: .utf8)!)
        return true
    }
    _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    FileHandle.standardError.write("""
        bowheel: Input Monitoring is \(tccState) for this binary — no reports will arrive until it is.
          System Settings > Privacy & Security > Input Monitoring > enable "bowheel".
          If it is not in the list, add it by hand: click +, press Shift-Cmd-G, enter
          \(CommandLine.arguments[0])
          Waiting; will restart once granted.

        """.data(using: .utf8)!)
    let t = Timer(timeInterval: 3.0, repeats: true) { _ in
        let now = freshInputMonitoringState()
        if now != tccState {
            tccState = now
            FileHandle.standardError.write("bowheel: Input Monitoring now \(now)\n".data(using: .utf8)!)
        }
        if now == "granted" {
            FileHandle.standardError.write("bowheel: restarting to pick up Input Monitoring access\n".data(using: .utf8)!)
            exit(0)   // launchd KeepAlive brings us back; a manual run just needs re-running
        }
    }
    RunLoop.main.add(t, forMode: .common)
    return false
}

// MARK: - Device listing

func listDevices(_ cfg: Config) {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, nil)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
        print("no devices (Input Monitoring permission?)"); return
    }
    for d in set {
        let vid = (IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let pid = (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        let name = (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) ?? "?"
        let mark = (vid == cfg.vid && pid == cfg.pid) ? "  <== match" : ""
        print(String(format: "%04x:%04x  %@%@", vid, pid, name, mark))
    }
}

// MARK: - main

let cfg = parseArgs()

if cfg.listOnly {
    listDevices(cfg)
    exit(0)
}

if cfg.simulate {
    let sim = Engine(cfg: cfg)
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 5)
    var n = 0
    let ramp: [Int16] = (0..<40).map { Int16(min(12, 2 + $0 / 3)) }   // 2u -> 12u per 8 ms
    let feed = DispatchSource.makeTimerSource(queue: .main)
    feed.schedule(deadline: .now() + 0.05, repeating: .milliseconds(8), leeway: .milliseconds(1))
    feed.setEventHandler {
        guard n < ramp.count else { feed.cancel(); return }
        let w = UInt16(bitPattern: ramp[n]); n += 1
        buf[0] = 3; buf[1] = UInt8(w & 0xff); buf[2] = UInt8(w >> 8); buf[3] = 0; buf[4] = 0
        sim.handleReport(id: 3, bytes: buf, len: 5)
    }
    feed.resume()
    let tk = Timer(timeInterval: 0.008, repeats: true) { _ in sim.tick() }
    RunLoop.main.add(tk, forMode: .common)
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { exit(0) }
    CFRunLoopRun()
}

let engine = Engine(cfg: cfg)
let watcher = DialWatcher(cfg: cfg, engine: engine)

// Probe/reset only touch feature reports, which are not TCC-gated.
let hasAccess = cfg.resetOnly ? true : startInputMonitoringWatch()
if hasAccess {
    watcher.start()
}
if !cfg.dryRun && !cfg.resetOnly { checkPostAccess() }

var configWatcher: ConfigWatcher? = nil
if let cp = cfg.configPath {
    configWatcher = ConfigWatcher(path: cp, engine: engine)
    configWatcher!.start()
}
// Held in a global on purpose: the writer's timer only holds it weakly.
var statusWriter: StatusWriter? = nil
if let sp = cfg.statusPath ?? cfg.configPath.map({ ($0 as NSString).deletingLastPathComponent + "/status.json" }) {
    statusWriter = StatusWriter(path: sp, engine: engine, watcher: configWatcher)
    statusWriter!.start()
}

FileHandle.standardError.write("""
bowheel: running  \(cfg.pixelsPerDetent)px/detent  \(cfg.unitsPerDetent)units/detent\
\(cfg.accel > 0 ? "  accel=\(cfg.accel) max=\(cfg.accelMax)x from \(cfg.accelStart)d/s" : "  no accel")\
\(cfg.invertY ? "  inverted" : "")\(cfg.momentum ? "  momentum" : "")\
\(cfg.seize ? "  seized" : "  NOT seized (expect double scroll)")\
\(cfg.dryRun ? "  dry-run" : "")
""".data(using: .utf8)! + "\n".data(using: .utf8)!)

if cfg.resetOnly {
    let bail = Timer(timeInterval: 3.0, repeats: false) { _ in
        FileHandle.standardError.write("bowheel: device did not attach within 3s\n".data(using: .utf8)!)
        exit(1)
    }
    RunLoop.main.add(bail, forMode: .common)
}

// Drives gesture close-out. 8 ms matches the dial's 125 Hz report interval.
let ticker = Timer(timeInterval: 0.008, repeats: true) { _ in engine.tick() }
RunLoop.main.add(ticker, forMode: .common)

signal(SIGINT) { _ in
    FileHandle.standardError.write("\nbowheel: stopped\n".data(using: .utf8)!)
    exit(0)
}

CFRunLoopRun()
