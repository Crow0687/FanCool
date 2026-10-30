import AppKit
import SwiftUI
import Combine
import FanCoolCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var statusAnimator: StatusFanAnimator?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var sensorsWindow: NSWindow?
    private var model: FanModel?
    private var subscriptions: Set<AnyCancellable> = []
    private var terminating = false
    private var measuredPanelHeight: CGFloat = 620

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = FanModel(demo: CommandLine.arguments.contains("--demo"))
        self.model = model
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = item
        if let button = item.button {
            statusAnimator = StatusFanAnimator(button: button)
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityIdentifier("fancool-status-item")
            button.setAccessibilityLabel("FanCool")
        }
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = NSHostingController(rootView: ContentView(model: model, onContentHeightChange: { [weak self] height in
            // Defer AppKit resizing until the SwiftUI layout pass has completed.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let height = ceil(height) + 1
                guard abs(self.measuredPanelHeight - height) >= 1 else { return }
                self.measuredPanelHeight = height
                self.resizePanel()
            }
        }))
        configureMenu()
        model.$showSettings.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] show in
            self?.setSettingsVisible(show)
        }.store(in: &subscriptions)
        model.$showSensors.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] show in
            self?.setSensorsVisible(show)
        }.store(in: &subscriptions)
        model.$snapshot.receive(on: RunLoop.main).sink { [weak self] snapshot in
            self?.statusAnimator?.setRunning(snapshot.error == nil && snapshot.fans.contains { $0.actual > 0 })
        }.store(in: &subscriptions)
        model.start()
        // One model owns the session throughout the app lifetime, including while hidden.
        DispatchQueue.main.async { [weak self] in self?.showPanel() }
    }
    @objc private func statusItemClicked() {
        guard !terminating else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            let menu = NSMenu()
            addItem("打开控制面板", action: #selector(showPanel), to: menu)
            addItem("设置…", action: #selector(showSettings), key: ",", to: menu)
            menu.addItem(.separator())
            addItem("全部恢复系统", action: #selector(restore), to: menu)
            menu.addItem(.separator())
            addItem("退出 FanCool", action: #selector(quit), key: "q", to: menu)
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else if popover.isShown { popover.performClose(nil) }
        else { showPanel() }
    }
    private func resizePanel() {
        let available = statusItem?.button?.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 850
        popover.contentSize = NSSize(width: 448, height: min(measuredPanelHeight, max(200, available - 30)))
    }
    @objc private func showPanel() {
        guard let button = statusItem?.button, !terminating else { return }
        let available = button.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 850
        popover.contentSize = NSSize(width: 448, height: min(measuredPanelHeight, max(200, available - 30)))
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    private func addItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
    }
    private func configureMenu() {
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        addItem("关于 FanCool", action: #selector(showAbout), to: appMenu)
        addItem("打开控制面板", action: #selector(showPanel), to: appMenu)
        addItem("设置…", action: #selector(showSettings), key: ",", to: appMenu)
        appMenu.addItem(.separator())
        addItem("全部恢复系统", action: #selector(restore), key: "0", to: appMenu)
        addItem("刷新硬件数据", action: #selector(refresh), key: "r", to: appMenu)
        addItem("导出最近调速日志…", action: #selector(exportWriteLog), to: appMenu)
        addItem("传感器明细", action: #selector(showSensors), key: "s", to: appMenu)
        appMenu.addItem(.separator())
        addItem("退出 FanCool", action: #selector(quit), key: "q", to: appMenu)
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(), editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
    private func auxiliaryWindow(title: String, size: NSSize, content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(Palette.background)
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
    private func setSettingsVisible(_ show: Bool) {
        guard let model else { return }
        guard show else { settingsWindow?.orderOut(nil); return }
        popover.performClose(nil)
        if settingsWindow == nil {
            settingsWindow = auxiliaryWindow(title: "FanCool · 设置", size: NSSize(width: SettingsView.width, height: 710),
                content: NSHostingView(rootView: SettingsView(model: model)))
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    private func setSensorsVisible(_ show: Bool) {
        guard let model else { return }
        guard show else { sensorsWindow?.orderOut(nil); return }
        popover.performClose(nil)
        if sensorsWindow == nil {
            sensorsWindow = auxiliaryWindow(title: "FanCool · 传感器明细", size: NSSize(width: 600, height: 540),
                content: NSHostingView(rootView: SensorDetails(model: model)))
        }
        NSApp.activate(ignoringOtherApps: true)
        sensorsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === settingsWindow { return model?.busy != true }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow { model?.closeSettings() }
        if window === sensorsWindow { model?.showSensors = false }
    }
    @objc private func showAbout() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "FanCool", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.8.7",
            .credits: NSAttributedString(string: "轻巧、清晰的 Mac 风扇监测与控制。\n首次调速需要系统管理员授权。")
        ])
    }
    @objc private func restore() { model?.restore() }
    @objc private func refresh() { Task { await model?.refresh() } }
    @objc private func exportWriteLog() { model?.exportWriteLog() }
    @objc private func showSensors() { model?.showSensors = true }
    @objc private func showSettings() { model?.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel(); return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        statusAnimator?.stop()
        popover.performClose(nil)
        statusItem?.button?.isEnabled = false
        Task {
            await model?.prepareToQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

if CommandLine.arguments.contains("--diagnose") || CommandLine.arguments.contains("--sensors") {
    let semaphore = DispatchSemaphore(value: 0)
    let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    Task.detached {
        let reading = await HardwareMonitor().sample()
        print("FanCool read-only diagnostics")
        print("Chip: \(Machine.chip)")
        print("Model: \(Machine.model)")
        print("Reduce motion: \(reducedMotion)")
        print("Reported fan count: \(reading.reportedFanCount.map(String.init) ?? "unavailable")")
        print("Control admission: \(reading.controlAvailability.allowed ? "allowed" : "read-only") — \(reading.controlAvailability.reason)")
        print("App CDHash: \(HelperIdentity.currentCodeHash() ?? "invalid")")
        print("Helper CDHash: \(HelperIdentity.codeHash(at: AdministratorInstaller.bundledHelper) ?? "invalid")")
        print("Helper installation: \(InstalledAuthorization.load() == nil ? "not authorized" : "present")")
        if let registers = try? SMCHardware() {
            print("Compatibility Ftst: byte=\(registers.isByteRegister("Ftst")), value=\((try? registers.number("Ftst")).map(String.init(describing:)) ?? "unavailable")")
        }
        if let error = reading.error { print("SMC: \(error)") }
        for fan in reading.fans {
            print("Fan \(fan.id): actual=\(fan.actual), min=\(fan.minimum.map(String.init(describing:)) ?? "unavailable"), max=\(fan.maximum.map(String.init(describing:)) ?? "unavailable"), mode=\(fan.mode.map(String.init) ?? "unavailable")")
        }
        print("Chip temperature: \(reading.temperature.map(String.init(describing:)) ?? "unavailable")")
        print("Hottest sensor: \(reading.hottestChipSensor?.key ?? "unavailable")")
        print("Thermal pressure: \(ProcessInfo.processInfo.thermalState.rawValue)")
        print("Competing controller: \(reading.conflictingController ?? "none")")
        for kind in SensorKind.allCases { print("\(kind.rawValue): \(reading.sensors.filter { $0.kind == kind }.count) sensors") }
        if CommandLine.arguments.contains("--sensors") {
            for sensor in reading.sensors { print("\(sensor.key) | \(sensor.group) | \(sensor.name) | \(sensor.value) \(sensor.kind.unit)") }
        }
        semaphore.signal()
    }
    semaphore.wait()
} else {
    try MainActor.assumeIsolated {
        if CommandLine.arguments.contains("--ui-checks") {
            try runUIWorkflowChecks()
        } else if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let model = FanModel(demo: true)
            if CommandLine.arguments.contains("--quiet-preview") { model.openSettings(); model.draftProfile = .quiet; model.saveProfile(); model.closeSettings() }
            if CommandLine.arguments.contains("--smart-preview") {
                model.snapshot.temperature = 73.4
                model.snapshot.sensors = [.init(key: "TCMz", name: "CPU 固件最高温", group: "CPU", kind: .temperature, value: 73.4, controlEligible: true)]
                model.select(.smart)
            }
            if CommandLine.arguments.contains("--manual-empty-preview") { model.selectMode(.manual) }
            if CommandLine.arguments.contains("--adjusting-preview") {
                model.control.fans = model.control.fans.map { .init(id: $0.id, rpm: $0.rpm, confirmed: false, smart: $0.smart) }
            }
            if CommandLine.arguments.contains("--manual-preview") { model.select(.custom) }
            if CommandLine.arguments.contains("--preset-preview") { model.select(.balanced) }
            if CommandLine.arguments.contains("--mixed-preview") {
                model.select(.smart); model.select(.custom); model.scope = 0; model.customPercent = 55; model.applyCustom()
            }
            let narrow = CommandLine.arguments.contains("--narrow")
            let settingsPreview = CommandLine.arguments.contains("--settings-preview")
            if settingsPreview { model.openSettings() }
            let renderer = ImageRenderer(content: Group {
                if settingsPreview { SettingsView(model: model, snapshotMode: true) }
                else { ContentView(model: model, snapshotMode: true).frame(width: narrow ? 448 : 680).fixedSize(horizontal: false, vertical: true) }
            })
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw FanCoolError.hardware("无法渲染预览图片。")
            }
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            print("Saved preview: \(CommandLine.arguments[index + 1])")
        } else {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}
