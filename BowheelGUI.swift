//
//  Bowheel — menu bar control panel for the bowheel daemon.
//
//  The daemon runs as root (it has to seize the dial), so this app never talks to it
//  directly. It writes /Library/Application Support/bowheel/config.json, which the
//  daemon hot-reloads within half a second, and reads status.json, which the daemon
//  publishes once a second. No XPC, no sockets, no privileged helper.
//
//  Build: ./build-gui.sh
//

import SwiftUI
import AppKit

let kDir    = "/Library/Application Support/bowheel"
let kConfig = kDir + "/config.json"
let kStatus = kDir + "/status.json"
let kLog    = "/var/log/bowheel.log"
let kDaemonPlist = "/Library/LaunchDaemons/org.bowheel.daemon.plist"

// MARK: - Model types

/// Mirrors the daemon's runtime-tunable subset of Config. Keys match its JSON exactly.
struct RuntimeConfig: Codable, Equatable {
    var pixelsPerDetent: Double = 480
    var accel: Double = 10.0
    var accelMax: Double = 6.0
    var accelStart: Double = 2.0
    var invertY = false
    var invertX = false
    var momentum = false
    var momentumDecay: Double = 0.94
    var idleEndMs: Double = 150

    /// Merge from loosely-typed JSON so a file missing keys (or with extras) still loads.
    mutating func merge(_ o: [String: Any]) {
        func d(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        func b(_ k: String) -> Bool?   { (o[k] as? NSNumber)?.boolValue }
        if let v = d("pixelsPerDetent") { pixelsPerDetent = v }
        if let v = d("accel")           { accel = v }
        if let v = d("accelMax")        { accelMax = v }
        if let v = d("accelStart")      { accelStart = v }
        if let v = d("momentumDecay")   { momentumDecay = v }
        if let v = d("idleEndMs")       { idleEndMs = v }
        if let v = b("invertY")         { invertY = v }
        if let v = b("invertX")         { invertX = v }
        if let v = b("momentum")        { momentum = v }
    }
}

struct DaemonStatus {
    var pid = 0
    var ts: Double = 0
    var uptime: Double = 0
    var attached = false
    var seized = false
    var reports = 0
    var lastReportAgo: Double?
    var configError: String?
    var inputMonitoring = "unknown"
    var accessibility = "granted"   // absent in older daemons' status; don't cry wolf

    init?(_ o: [String: Any]) {
        guard let ts = (o["ts"] as? NSNumber)?.doubleValue else { return nil }
        self.ts = ts
        pid = (o["pid"] as? NSNumber)?.intValue ?? 0
        uptime = (o["uptime"] as? NSNumber)?.doubleValue ?? 0
        attached = (o["attached"] as? NSNumber)?.boolValue ?? false
        seized = (o["seized"] as? NSNumber)?.boolValue ?? false
        reports = (o["reports"] as? NSNumber)?.intValue ?? 0
        lastReportAgo = (o["lastReportAgo"] as? NSNumber)?.doubleValue
        configError = o["configError"] as? String
        inputMonitoring = o["inputMonitoring"] as? String ?? "unknown"
        accessibility = o["accessibility"] as? String ?? "granted"
    }
}

// MARK: - Model

final class Model: ObservableObject {
    @Published var cfg = RuntimeConfig()
    @Published var status: DaemonStatus?
    @Published var alive = false
    @Published var installed = false
    @Published var rate: Double = 0          // reports per second, from consecutive polls
    @Published var saveError: String?

    private var lastSample: (reports: Int, ts: Double)?
    private var timer: Timer?
    private var saveTask: Task<Void, Never>?

    init() {
        load()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: config file

    func load() {
        guard let data = FileManager.default.contents(atPath: kConfig),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var c = RuntimeConfig()
        c.merge(obj)
        cfg = c
    }

    /// Sliders fire continuously; coalesce to one write per ~150 ms. The daemon polls
    /// at 500 ms so anything faster is wasted anyway.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(cfg)
            // Atomic replace. rename() needs write permission on the directory (root:admin
            // 775, and this user is admin), not on the existing root-owned file.
            let tmp = kConfig + ".tmp-\(getpid())"
            try data.write(to: URL(fileURLWithPath: tmp))
            if rename(tmp, kConfig) != 0 {
                let e = String(cString: strerror(errno))
                try? FileManager.default.removeItem(atPath: tmp)
                throw NSError(domain: "bowheel", code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: "can't write config: \(e)"])
            }
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: status

    func refresh() {
        installed = FileManager.default.fileExists(atPath: kDaemonPlist)
            && FileManager.default.fileExists(atPath: kDir)

        guard let data = FileManager.default.contents(atPath: kStatus),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let st = DaemonStatus(obj) else {
            status = nil; alive = false; rate = 0; lastSample = nil
            return
        }
        status = st
        alive = Date().timeIntervalSince1970 - st.ts < 3.5

        if let l = lastSample, st.ts > l.ts {
            rate = max(0, Double(st.reports - l.reports) / (st.ts - l.ts))
        }
        lastSample = (st.reports, st.ts)
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()

            sliderRow("Scroll speed", value: $m.cfg.pixelsPerDetent, in: 20...1000, step: 10,
                      format: { String(format: "%.0f px / detent", $0) })
            Toggle("Invert direction", isOn: $m.cfg.invertY)

            Divider()

            Toggle("Acceleration", isOn: Binding(
                get: { m.cfg.accel > 0 },
                set: { m.cfg.accel = $0 ? 1.0 : 0 }))
            if m.cfg.accel > 0 {
                sliderRow("Strength", value: $m.cfg.accel, in: 0.5...20, step: 0.5,
                          format: { String(format: "%.1f", $0) })
                sliderRow("Max gain", value: $m.cfg.accelMax, in: 1...12, step: 0.5,
                          format: { String(format: "%.1f×", $0) })
                sliderRow("Kicks in at", value: $m.cfg.accelStart, in: 0...10, step: 0.5,
                          format: { String(format: "%.1f detents / s", $0) })
            }

            Divider()
            Toggle("Software momentum", isOn: $m.cfg.momentum)
                .help("Off by default — the dial is a physical flywheel and already free-spins.")

            if needsInputMonitoring {
                Button("Grant Input Monitoring…") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
                .help("Enable \"bowheel\" in the list. The daemon restarts itself once granted.")
            }

            if needsAccessibility {
                Button("Grant Accessibility…") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                .help("Enable \"bowheel\" in the list, then restart the daemon.")
            }

            if let e = m.saveError ?? m.status?.configError {
                Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("Open log") { NSWorkspace.shared.open(URL(fileURLWithPath: kLog)) }
                    .disabled(!FileManager.default.fileExists(atPath: kLog))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 290)
        .onChange(of: m.cfg) { m.scheduleSave() }
    }

    // MARK: header / status line

    private var needsInputMonitoring: Bool {
        m.alive && m.status?.inputMonitoring != "granted"
    }

    private var needsAccessibility: Bool {
        m.alive && m.status?.accessibility == "denied"
    }

    private var dot: Color {
        if !m.installed { return .gray }
        if !m.alive { return .red }
        if needsInputMonitoring || needsAccessibility { return .red }
        return m.status?.attached == true ? .green : .orange
    }

    private var subtitle: String {
        if !m.installed { return "not installed — run sudo ./install.sh" }
        guard m.alive, let s = m.status else { return "daemon not running" }
        if needsInputMonitoring { return "Input Monitoring not granted — no scrolling until it is" }
        if needsAccessibility { return "Accessibility not granted — scroll events are being dropped" }
        if !s.attached { return "dial not connected" }
        let mode = s.seized ? "seized" : "shared"
        if m.rate > 0.5 { return String(format: "%.0f reports / s · %@", m.rate, mode) }
        if let ago = s.lastReportAgo, ago < 60 { return String(format: "idle %.0fs · %@", ago, mode) }
        return "ready · \(mode)"
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(dot).frame(width: 9, height: 9).padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text("bowheel").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>,
                           step: Double, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: value, in: range, step: step)
        }
    }
}

// MARK: - App

@main
struct BowheelApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra("bowheel", systemImage: "dial.medium") {
            ContentView().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
