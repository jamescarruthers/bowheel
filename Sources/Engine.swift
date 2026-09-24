//
//  Engine.swift — the shared core of bowheel: device access, report decoding, scroll
//  synthesis, acceleration, momentum, and the two TCC gates. Compiled into both the
//  Bowheel.app menu bar app and the `bowheel` command-line tool.
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

import Foundation
import CoreHID
import IOKit.hid     // Input Monitoring (TCC) checks only; CoreHID has none
import CoreGraphics
import os

// MARK: - Logging
//
// Everything of interest goes to the unified log so it can be read back from a machine
// we don't have a terminal on:   log show --last 1h --predicate 'subsystem == "org.bowheel"'
// It is mirrored to stderr for the CLI. Per-report --debug output stays stderr-only:
// at 125 Hz it would swamp the log store.

let oslog = Logger(subsystem: "org.bowheel", category: "engine")

func blog(_ s: String) {
    oslog.notice("\(s, privacy: .public)")
    FileHandle.standardError.write("bowheel: \(s)\n".data(using: .utf8)!)
}

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


// MARK: - Cursor-warp input suppression
//
// After CGWarpMouseCursorPosition, macOS ignores hardware mouse input for a short interval
// (250 ms by default). Focused-window mode warps on every report, so the real mouse would
// stall for as long as the dial turns — which is exactly what users saw. The globals that
// control this were deprecated in 10.6 and are marked unavailable to Swift, but they are
// still exported and still honoured, so resolve them at runtime.

private typealias SetInterval = @convention(c) (CFTimeInterval) -> CGError
private typealias SetFilter   = @convention(c) (UInt32, UInt32) -> CGError

func disableWarpSuppression() {
    guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) else { return }
    if let p = dlsym(h, "CGSetLocalEventsSuppressionInterval") {
        _ = unsafeBitCast(p, to: SetInterval.self)(0)
    }
    if let p = dlsym(h, "CGSetLocalEventsFilterDuringSuppressionState") {
        // kCGEventFilterMaskPermitAllEvents (mouse 1 | keyboard 2 | system 4) during
        // kCGEventSuppressionStateSuppressionInterval (0): belt and braces.
        _ = unsafeBitCast(p, to: SetFilter.self)(7, 0)
    }
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

    /// Where the scroll goes. false: post at the HID tap and let macOS route to the window
    /// under the cursor, like a real wheel. true: post at the session tap with the event
    /// located inside the frontmost window, so the dial scrolls what you are working in
    /// regardless of where the mouse is parked.
    var focusedWindow = false

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
        cfg.focusedWindow = n.focusedWindow
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

    // Frontmost window centre, refreshed at most every 100 ms — the window list query is
    // far too slow to run per report at 125 Hz, and focus does not change that fast.
    private var focusPoint: CGPoint?
    private var focusBounds = CGRect.zero
    private var focusPid: pid_t = 0
    private var focusPointAt: CFAbsoluteTime = 0

    /// Centre of the frontmost ordinary window, in CG global coordinates (top-left origin,
    /// the same space CGEvent.location uses). The on-screen window list comes back
    /// front-to-back; the first entry at layer 0 is the key window of the active app.
    /// Menu bar, Dock and floating panels sit at other layers.
    private func frontmostWindow() -> (centre: CGPoint, bounds: CGRect, pid: pid_t)? {
        let now = CFAbsoluteTimeGetCurrent()
        if now - focusPointAt < 0.1 { return focusPoint.map { ($0, focusBounds, focusPid) } }
        focusPointAt = now
        focusPoint = nil
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"],
                  wd > 50, ht > 50 else { continue }
            focusPoint = CGPoint(x: x + wd / 2, y: y + ht / 2)
            focusBounds = CGRect(x: x, y: y, width: wd, height: ht)
            focusPid = pid
            break
        }
        return focusPoint.map { ($0, focusBounds, focusPid) }
    }

    init(cfg: Config) {
        self.cfg = cfg
        self.source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        disableWarpSuppression()
    }

    // MARK: Report decode

    /// Reports of interest, per the decoded descriptor:
    ///   ID 3 -> [Wheel int16 LE][AC Pan int16 LE]   (hi-res collection)
    ///   ID 5 -> [Wheel int16 LE][AC Pan int16 LE]   (fallback collection)
    /// Buttons/X/Y (IDs 1 and 4) are deliberately passed through untouched.
    func handleReport(id: UInt32, bytes: [UInt8]) {
        reportCount += 1
        var b = bytes

        if cfg.debug {
            let hex = b.map { String(format: "%02x", $0) }.joined(separator: " ")
            FileHandle.standardError.write(String(format: "rpt %9.1fms id=%d len=%d [%@]\n",
                (CFAbsoluteTimeGetCurrent() - t0) * 1000, id, b.count, hex).data(using: .utf8)!)
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

        // At the HID tap the system fills in the cursor location and routes to the window
        // under it. For the focused window the event has to go through WindowServer with
        // a location inside that window (postToPid delivers but never scrolls, window-
        // number fields don't redirect, and disassociating the cursor doesn't stop the
        // warp — all measured). WindowServer treats a located event as real input and
        // warps the cursor there, so warp it straight back: both are processed in order
        // well inside one frame and the cursor is never drawn at the centre.
        if cfg.focusedWindow, let t = frontmostWindow(),
           let cursor = CGEvent(source: nil)?.location, !t.bounds.contains(cursor) {
            // Cursor is outside the focused window: relocate the event and warp back.
            ev.location = t.centre
            ev.post(tap: .cgSessionEventTap)
            CGWarpMouseCursorPosition(cursor)
        } else {
            // Cursor is already over the focused window (it is frontmost, so it is the
            // window under the cursor) or the mode is off: plain routing, no warp.
            ev.post(tap: .cghidEventTap)
        }
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
//
// CoreHID (macOS 15+). Device arrival and removal, and input reports, arrive as async
// streams. Each stream is drained by a main-actor Task, so the engine — which is not
// thread-safe — only ever runs on the main thread, alongside its timers.

final class DialWatcher {
    private let cfg: Config
    private let engine: Engine
    private var managerTask: Task<Void, Never>?

    // The dial speaks USB and Bluetooth LE with the same VID/PID and report layout, so
    // when it is paired *and* plugged in the HID manager reports two devices. We track
    // every match but listen to exactly one, preferring USB, and switch as they come
    // and go — otherwise both streams would feed the engine. Every match is seized, not
    // just the one we listen to: an unseized twin would still feed macOS its own
    // 120x-too-fast wheel events.
    private struct Dial {
        let client: HIDDeviceClient
        let transport: String
        let product: String
        let usage: HIDUsage
    }
    private var known: [HIDDeviceClient.DeviceReference: Dial] = [:]
    private var active: HIDDeviceClient.DeviceReference?
    private var activeTask: Task<Void, Never>?
    /// Transport of the device being listened to ("USB", "Bluetooth Low Energy"), for status.
    private(set) var activeTransport: String?

    init(cfg: Config, engine: Engine) {
        self.cfg = cfg
        self.engine = engine
    }

    /// Human-readable reason the last start() failed, nil when open.
    private(set) var lastError: String?
    /// Short machine-readable reason: "exclusive", "permission", "other".
    private(set) var lastErrorKind: String?
    /// Called when the dial cannot be opened. CoreHID seizes per device, as each one
    /// appears, so a failure arrives after start() has returned rather than from it.
    /// The watcher has already stopped itself when this runs.
    var onError: (@MainActor (String) -> Void)?

    /// Starts watching for the dial. Failures are reported through onError.
    func start() {
        stop()
        lastError = nil
        lastErrorKind = nil
        let match = HIDDeviceManager.DeviceMatchingCriteria(vendorID: UInt32(cfg.vid),
                                                            productID: UInt32(cfg.pid))
        managerTask = Task { @MainActor [weak self] in
            let manager = HIDDeviceManager()
            do {
                for try await n in await manager.monitorNotifications(matchingCriteria: [match]) {
                    guard let self else { return }
                    switch n {
                    case .deviceMatched(let ref): await self.appeared(ref)
                    case .deviceRemoved(let ref): self.disappeared(ref)
                    @unknown default: break
                    }
                }
            } catch {
                if !Task.isCancelled { self?.fail(error) }
            }
        }
    }

    /// Releases the device. Safe to call when not started.
    func stop() {
        managerTask?.cancel()
        managerTask = nil
        unlisten()
        // A seize lasts until its client is deinitialised; dropping ours releases it.
        known.removeAll()
    }

    private static func name(_ t: HIDDeviceTransport?) -> String {
        switch t {
        case .usb?: return "USB"
        case .bluetooth?: return "Bluetooth"
        case .bluetoothLowEnergy?: return "Bluetooth Low Energy"
        case .unknown(let s)?: return s
        case let t?: return "\(t)"
        case nil: return "?"
        }
    }

    /// Higher wins. USB is wired, lower latency and never sleeps; BLE is the fallback.
    private static func rank(_ transport: String) -> Int {
        switch transport {
        case "USB": return 2
        case "Bluetooth", "Bluetooth Low Energy": return 1
        default: return 0
        }
    }

    @MainActor
    private func appeared(_ ref: HIDDeviceClient.DeviceReference) async {
        guard let client = HIDDeviceClient(deviceReference: ref) else {
            log("device appeared but could not be opened")
            return
        }
        let transport = Self.name(await client.transport)
        let product = await client.product ?? "?"
        let usage = await client.primaryUsage
        if cfg.seize {
            // Must happen before any other request on this client.
            do { try await client.seizeDevice() } catch { fail(error); return }
        }
        guard !Task.isCancelled else { return }   // stop() ran while we were waiting
        known[ref] = Dial(client: client, transport: transport, product: product, usage: usage)
        log("device appeared: \(transport)  (\(known.count) present)")
        select()
    }

    private func disappeared(_ ref: HIDDeviceClient.DeviceReference) {
        guard let d = known.removeValue(forKey: ref) else { return }
        log("device disappeared: \(d.transport)  (\(known.count) present)")
        if active == ref { unlisten() }
        select()
    }

    /// Listen to the best-ranked known device; no-op if that is already the active one.
    private func select() {
        guard let best = known.max(by: { Self.rank($0.value.transport) < Self.rank($1.value.transport) }) else {
            engine.attached = false
            return
        }
        if active == best.key { return }
        unlisten()
        listen(best.key, best.value)
    }

    private func listen(_ ref: HIDDeviceClient.DeviceReference, _ dial: Dial) {
        active = ref
        activeTransport = dial.transport
        log("listening: \(dial.product) over \(dial.transport)  primaryUsage=\(dial.usage)")
        engine.attached = true

        let cfg = self.cfg, engine = self.engine, client = dial.client
        let report2 = HIDReportID(rawValue: 2)
        activeTask = Task { @MainActor in
            // Resolution Multiplier (report 2, Usage 0x48). macOS never writes this itself,
            // which is the root of the scaling problem — but writing it changes device state
            // and can stop scrolling entirely, so it is opt-in only.
            if let m = cfg.multiplier {
                // Feature report 2 is 2 bytes on the wire: [reportID][value]. GetReport
                // hands back the ID in byte 0, so SetReport expects it there too — passing
                // a bare 1-byte payload silently writes the wrong field.
                // value bits: [1:0] = wheel multiplier, [3:2] = AC Pan multiplier.
                let n = UInt8(clamping: m) & 0x3
                let buf: [UInt8] = [0x02, n | (n << 2)]
                do {
                    try await client.dispatchSetReportRequest(type: .feature, id: report2,
                                                              data: Data(buf), timeout: .seconds(1))
                    blog(String(format: "  wrote resolution multiplier = %d (report 2 = [02 %02x])", m, buf[1]))
                } catch {
                    blog("  FAILED to write feature report 2 — \(error)")
                }
            }

            // macOS is inconsistent about whether the leading report-ID byte lives in the
            // buffer, so dump raw bytes and let the hex decide rather than assuming an offset.
            do {
                let rb = try await client.dispatchGetReportRequest(type: .feature, id: report2,
                                                                   timeout: .seconds(1))
                let hex = rb.map { String(format: "%02x", $0) }.joined(separator: " ")
                blog("  feature report 2 raw = [\(hex)] len=\(rb.count)")
            } catch {
                blog("  could not read feature report 2 — \(error)")
            }

            if cfg.resetOnly {
                blog("done. If scrolling is still dead, unplug and replug the dial.")
                exit(0)
            }

            do {
                let stream = await client.monitorNotifications(reportIDsToMonitor: [HIDReportID.allReports],
                                                               elementsToMonitor: [])
                for try await n in stream {
                    switch n {
                    case .inputReport(let id, let data, _):
                        engine.handleReport(id: UInt32(id?.rawValue ?? 0), bytes: [UInt8](data))
                    case .deviceSeized:
                        blog("another process seized the dial; no reports until it lets go")
                    case .deviceUnseized:
                        blog("the other process released the dial")
                    case .deviceRemoved:
                        return   // the manager stream does the bookkeeping
                    case .elementUpdates:
                        break
                    @unknown default:
                        break
                    }
                }
            } catch {
                if !Task.isCancelled { blog("input report stream ended — \(error)") }
            }
        }
    }

    private func unlisten() {
        guard active != nil else { return }
        activeTask?.cancel()
        activeTask = nil
        log("stopped listening (\(activeTransport ?? "?"))")
        active = nil
        activeTransport = nil
        engine.attached = false
    }

    @MainActor
    private func fail(_ error: Error) {
        var hint = "bowheel: could not open the dial — \(error)\n"
        switch error as? HIDDeviceError {
        case .exclusiveAccess?:
            lastErrorKind = "exclusive"
            hint += """
                    Another process has the device seized exclusively. On this machine that
                    is almost always Karabiner-Elements. Release it there:
                      Karabiner-Elements > Settings > Devices > uncheck "Full Scroll Dial"
                    Scrolling will go dead once Karabiner lets go — macOS ignores this dial's
                    wheel on its own. That is expected; bowheel takes over from there.
                    Check the current owner with:
                      ioreg -c IOHIDDevice -r -l | grep -A80 'Full Scroll Dial' | grep IOUserClientCreator

                    """
        case .notPrivileged?, .notPermitted?:
            lastErrorKind = "permission"
            hint += """
                    Permission denied reading input reports. Either run under sudo, or grant
                    Input Monitoring to this binary:
                      System Settings > Privacy & Security > Input Monitoring > + > \(CommandLine.arguments[0])

                    """
        default:
            lastErrorKind = "other"
            hint += "Unexpected failure. Try --list to confirm the device is visible.\n"
        }
        if cfg.seize {
            hint += "Seizing was requested; --no-seize will open shared instead (expect double scrolling).\n"
        }
        blog(hint.replacingOccurrences(of: "bowheel: ", with: ""))
        lastError = hint
        stop()
        onError?(hint)
    }

    private func log(_ s: String) { blog(s) }
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
    if let v = b("focusedWindow")               { c.focusedWindow = v }
    if let v = b("momentum")                    { c.momentum = v }
}

func runtimeJSON(_ c: Config) -> [String: Any] {
    [
        "pixelsPerDetent": c.pixelsPerDetent,
        "accel": c.accel, "accelMax": c.accelMax, "accelStart": c.accelStart,
        "invertY": c.invertY, "invertX": c.invertX, "focusedWindow": c.focusedWindow,
        "momentum": c.momentum, "momentumDecay": c.momentumDecay,
        "momentumTrigger": c.momentumTrigger,
        "idleEndMs": c.idleEndMs,
    ]
}

/// Polls the config file's mtime. Polling beats vnode watching here because the GUI
/// writes atomically (temp file + rename), which replaces the inode every save.
// MARK: - Input Monitoring (TCC)
//
// Root is NOT exempt from TCC for HID input. A root daemon that hasn't been granted
// Input Monitoring opens the device fine and simply never receives a report — the same
// silent failure Karabiner's grabber has. IOHIDRequestAccess registers this binary in
// the Input Monitoring list (and prompts, when a GUI session can show one) so the user
// can tick it rather than navigate to /usr/local/bin. Once granted we exit and let
// launchd's KeepAlive restart us with access.

var tccState = "unknown"

/// What to do once Input Monitoring is granted. The device must be (re)opened by a fresh
/// process — the CLI exits and lets launchd or the user restart it; the app relaunches.
var onInputMonitoringGranted: () -> Void = { exit(0) }

func inputMonitoringState() -> String {
    switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
    case kIOHIDAccessTypeGranted: return "granted"
    case kIOHIDAccessTypeDenied:  return "denied"
    default:                      return "unknown"
    }
}

/// Must run BEFORE the device is opened: with seize requested, seizing fails with
/// HIDDeviceError.notPermitted when access is missing, so anything after it never runs
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
    blog("""
        Accessibility is NOT granted — reports are read but scroll events are dropped.
          System Settings > Privacy & Security > Accessibility > enable "bowheel".
          If it is not in the list: click +, press Shift-Cmd-G, enter
          \(CommandLine.arguments[0])
          It takes effect without a restart.

        """)

    // The answer above is cached for the life of this process, but the grant itself is
    // honoured immediately — so without this the status would say "denied" forever while
    // scrolling works. Re-ask from a fresh child until it flips.
    let t = Timer(timeInterval: 3.0, repeats: true) { timer in
        if freshState("--check-post") == "granted" {
            postState = "granted"
            blog("Accessibility granted")
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
        blog("Input Monitoring granted")
        return true
    }
    _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    blog("""
        Input Monitoring is \(tccState) for this binary — no reports will arrive until it is.
          System Settings > Privacy & Security > Input Monitoring > enable "bowheel".
          If it is not in the list, add it by hand: click +, press Shift-Cmd-G, enter
          \(CommandLine.arguments[0])
          Waiting; will restart once granted.

        """)
    let t = Timer(timeInterval: 3.0, repeats: true) { _ in
        let now = freshInputMonitoringState()
        if now != tccState {
            tccState = now
            blog("Input Monitoring now \(now)")
        }
        if now == "granted" {
            blog("Input Monitoring granted — restarting")
            onInputMonitoringGranted()
        }
    }
    RunLoop.main.add(t, forMode: .common)
    return false
}

