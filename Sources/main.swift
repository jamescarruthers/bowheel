//
//  main.swift — the `bowheel` command-line tool: diagnostics (--debug, --dry-run,
//  --simulate-flick, --probe, --list) and a headless daemon mode (--config/--status).
//  The menu bar app is the normal way to run bowheel; this exists for debugging.
//

import Foundation
import IOKit
import IOKit.hid
import CoreGraphics

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
if hasAccess, watcher.start() != nil {
    exit(1)
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
