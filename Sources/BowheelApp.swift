//
//  BowheelApp.swift — menu bar app hosting the bowheel engine in-process.
//
//  No daemon, no root, no config files. Runs in the login session, so macOS can show
//  the two permission prompts itself on first launch (Input Monitoring to read the
//  dial, Accessibility to post scroll events), and the app relaunches once both are
//  granted. Settings live in UserDefaults and apply live.
//

import SwiftUI
import AppKit
import ServiceManagement
import IOKit.hid

// MARK: - Settings

struct Settings: Codable, Equatable {
    var pixelsPerDetent: Double = 480
    var accel: Double = 10
    var accelMax: Double = 6
    var accelStart: Double = 2
    var invertY = false
    var invertX = false
    var focusedWindow = false
    var momentum = false
    var momentumDecay: Double = 0.96
    var idleEndMs: Double = 150

    static let key = "settings"

    static func load() -> Settings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
        return s
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Settings.key) }
    }
    func apply(to c: inout Config) {
        c.pixelsPerDetent = pixelsPerDetent
        c.accel = accel; c.accelMax = accelMax; c.accelStart = accelStart
        c.invertY = invertY; c.invertX = invertX
        c.focusedWindow = focusedWindow
        c.momentum = momentum; c.momentumDecay = momentumDecay
        c.idleEndMs = idleEndMs
    }
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    enum State: Equatable {
        case needsPermissions(inputMonitoring: Bool, accessibility: Bool)
        case blocked(String)          // someone else has the dial (Karabiner)
        case waitingForDevice
        case running
        case failed(String)
    }

    @Published var settings = Settings.load() { didSet { settings.save(); push() } }
    @Published var state: State = .waitingForDevice
    @Published var rate: Double = 0
    @Published var loginItem = SMAppService.mainApp.status == .enabled

    private let engine: Engine
    private let watcher: DialWatcher
    private var lastReports = 0
    private var lastRate = Date()
    private var relaunching = false

    init() {
        var cfg = Config()
        cfg.seize = true
        Settings.load().apply(to: &cfg)
        engine = Engine(cfg: cfg)
        watcher = DialWatcher(cfg: cfg, engine: engine)

        // Engine clock: closes gestures and runs the glide. 8 ms matches the dial.
        let tick = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.tick() }
        }
        RunLoop.main.add(tick, forMode: .common)
        let status = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(status, forMode: .common)

        checkPermissionsAndStart()
    }

    private func push() {
        var c = engine.cfg
        settings.apply(to: &c)
        engine.update(c)
    }

    // MARK: permissions

    private var inputMonitoringGranted: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
    private var accessibilityGranted: Bool { AXIsProcessTrusted() }

    private func checkPermissionsAndStart() {
        let im = inputMonitoringGranted, ax = accessibilityGranted
        if im && ax { start(); return }

        state = .needsPermissions(inputMonitoring: im, accessibility: ax)

        // Both of these register the app in the relevant list and, in a GUI session,
        // put up the system prompt. Ask for both at once so the user doesn't discover
        // the second gate on a later launch.
        if !im { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        if !ax {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        SetupWindow.show(model: self)

        // TCC caches its answer per process, so ask a fresh child. Relaunch when both
        // are granted: the HID manager has to be opened by a process that had access
        // from the start.
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] timer in
            let im = freshState("--check-access") == "granted"
            let ax = freshState("--check-post") == "granted"
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.state = .needsPermissions(inputMonitoring: im, accessibility: ax)
                if im && ax { timer.invalidate(); self.relaunch() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    func relaunch() {
        guard !relaunching else { return }
        relaunching = true
        let bundle = Bundle.main.bundlePath
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "sleep 1; open -n \"\(bundle)\""]
        try? sh.run()
        NSApp.terminate(nil)
    }

    // MARK: device

    private func start() {
        if let err = watcher.start() {
            switch watcher.lastErrorKind {
            case "exclusive":
                state = .blocked("Another app has the dial (usually Karabiner-Elements). Retrying…")
                // Karabiner lets go when the device is unchecked there; keep trying.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
            case "permission":
                // Grant revoked or stale (ad-hoc signing pins the code hash per build).
                checkPermissionsAndStart()
            default:
                state = .failed(err.components(separatedBy: "\n").first ?? err)
            }
            return
        }
        state = engine.attached ? .running : .waitingForDevice
    }

    private func refresh() {
        if case .needsPermissions = state { return }
        if case .blocked = state { return }
        if case .failed = state { return }
        state = engine.attached ? .running : .waitingForDevice

        let now = Date()
        let dt = now.timeIntervalSince(lastRate)
        if dt > 0 {
            rate = Double(engine.reportsSeen - lastReports) / dt
            lastReports = engine.reportsSeen
            lastRate = now
        }
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("login item: \(error)")
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Setup window (first launch)

enum SetupWindow {
    private static var window: NSWindow?

    @MainActor static func show(model: Model) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Bowheel Setup"
            w.contentView = NSHostingView(rootView: SetupView().environmentObject(model))
            w.center()
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @MainActor static func close() { window?.close() }
}

struct SetupView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bowheel needs two permissions").font(.title3.bold())
            Text("macOS ignores the Full Scroll Dial on its own. Bowheel reads the dial directly and posts trackpad-style scroll events, which needs:")
                .fixedSize(horizontal: false, vertical: true)

            if case .needsPermissions(let im, let ax) = m.state {
                row(done: im, "Input Monitoring", "to read the dial",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
                row(done: ax, "Accessibility", "to post scroll events",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }

            Text("Enable **Bowheel** in each list. This window closes and Bowheel relaunches on its own once both are granted.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
        .frame(width: 420)
    }

    private func row(done: Bool, _ title: String, _ why: String, _ url: String) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(title).bold()
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !done {
                Button("Open Settings") { NSWorkspace.shared.open(URL(string: url)!) }
            }
        }
    }
}

// MARK: - Menu

struct MenuView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()

            slider("Scroll speed", $m.settings.pixelsPerDetent, 20...1000, 10) { String(format: "%.0f px / detent", $0) }
            Toggle("Invert direction", isOn: $m.settings.invertY)
            Toggle("Scroll the focused window", isOn: $m.settings.focusedWindow)
                .help("On: scrolls the window you are working in, wherever the mouse is. Off: scrolls whatever is under the cursor, like a real wheel.")

            Divider()
            Toggle("Acceleration", isOn: Binding(get: { m.settings.accel > 0 },
                                                 set: { m.settings.accel = $0 ? 1 : 0 }))
            if m.settings.accel > 0 {
                slider("Strength", $m.settings.accel, 0.5...20, 0.5) { String(format: "%.1f", $0) }
                slider("Max gain", $m.settings.accelMax, 1...12, 0.5) { String(format: "%.1f×", $0) }
                slider("Kicks in at", $m.settings.accelStart, 0...10, 0.5) { String(format: "%.1f detents / s", $0) }
            }

            Divider()
            Toggle("Software momentum", isOn: $m.settings.momentum)
                .help("Off by default — the dial is a physical flywheel and already free-spins.")
            if m.settings.momentum {
                slider("Glide", $m.settings.momentumDecay, 0.90...0.985, 0.005) { String(format: "%.0f ms", -1000.0 / 60.0 / log($0)) }
            }

            Divider()
            Toggle("Start at login", isOn: Binding(get: { m.loginItem }, set: { m.setLoginItem($0) }))

            if case .needsPermissions = m.state {
                Button("Set up permissions…") { SetupWindow.show(model: m) }
            }

            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless).font(.caption)
        }
        .padding(14)
        .frame(width: 290)
    }

    private var dot: Color {
        switch m.state {
        case .running: return .green
        case .waitingForDevice: return .orange
        case .needsPermissions, .blocked, .failed: return .red
        }
    }

    private var subtitle: String {
        switch m.state {
        case .running:
            return m.rate > 0.5 ? String(format: "%.0f reports / s", m.rate) : "ready"
        case .waitingForDevice: return "dial not connected"
        case .needsPermissions(let im, let ax):
            var need: [String] = []
            if !im { need.append("Input Monitoring") }
            if !ax { need.append("Accessibility") }
            return "needs " + need.joined(separator: " + ")
        case .blocked(let s): return s
        case .failed(let s): return s
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(dot).frame(width: 9, height: 9).padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text("bowheel").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ step: Double, _ format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label); Spacer()
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
    @StateObject private var model: Model

    init() {
        // Child-process permission probes (see Model.checkPermissionsAndStart). Must run
        // before any UI so the child exits cleanly and quickly.
        let args = CommandLine.arguments
        if args.contains("--check-access") {
            print(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted ? "granted" : "denied")
            exit(0)
        }
        if args.contains("--check-post") {
            print(AXIsProcessTrusted() ? "granted" : "denied")
            exit(0)
        }
        _model = StateObject(wrappedValue: Model())
    }

    var body: some Scene {
        MenuBarExtra("bowheel", systemImage: "dial.medium") {
            MenuView().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
