import AppKit
import ApplicationServices

// Rail owns this strip. The apps it switches to remain normal, independent apps.
struct Pin: Codable, Equatable, Identifiable {
    var id = UUID()
    var bundleID: String
    var path: String
    var name: String
    var windowTitle: String?
    var label: String { windowTitle.map { "\(name) — \($0)" } ?? name }
}

struct Settings: Codable {
    var pins: [Pin]
    var x: Double?
    var y: Double?
}

enum Persistence {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Rail/settings.json")
    static func load() -> Settings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }
    static func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: url, options: .atomic)
    }
}

enum Layout {
    static let width: CGFloat = 54
    static let row: CGFloat = 44
    static func height(_ count: Int) -> CGFloat { 20 + CGFloat(count) * row + 42 }
    static func fittedHeight(_ count: Int, screenHeight: CGFloat) -> CGFloat {
        min(height(count), max(height(0), screenHeight - 16))
    }
    static func screen(for frame: NSRect, in screens: [NSRect]) -> NSRect? {
        guard !screens.isEmpty else { return nil }
        // Keep offscreen saved positions near their previous display instead of
        // choosing the last display when every intersection has zero area.
        return screens.min { a, b in
            func distance(_ screen: NSRect) -> CGFloat {
                let x = max(screen.minX - frame.midX, 0, frame.midX - screen.maxX)
                let y = max(screen.minY - frame.midY, 0, frame.midY - screen.maxY)
                return x * x + y * y
            }
            return distance(a) < distance(b)
        }
    }
    static func clamp(_ frame: NSRect, to screens: [NSRect]) -> NSRect {
        guard let screen = screen(for: frame, in: screens) else { return frame }
        var result = frame
        result.origin.x = min(max(result.minX, screen.minX + 8), screen.maxX - frame.width - 8)
        result.origin.y = min(max(result.minY, screen.minY + 8), screen.maxY - frame.height - 8)
        return result
    }
}

enum PinStatus: String {
    case stopped = "Not running"
    case ready = "Ready"
    case active = "Active"
    case parked = "Parked · still running"
    case needsAccess = "Window access needed"
    case missingWindow = "Choose this window again"
    case unknown = "Window state unavailable"

    var primaryAction: String {
        switch self {
        case .stopped: return "Open"
        case .parked: return "Bring back"
        default: return "Switch to"
        }
    }
    var canPark: Bool { self == .ready || self == .active }
    func consideringHiddenApp(_ hidden: Bool) -> PinStatus {
        hidden && (self == .active || self == .ready) ? .parked : self
    }

    static func window(running: Bool, access: Bool, matches: Int, minimized: Bool?, focused: Bool) -> PinStatus {
        guard running else { return .stopped }
        guard access else { return .needsAccess }
        guard matches == 1 else { return .missingWindow }
        guard let minimized else { return .unknown }
        if minimized { return .parked }
        return focused ? .active : .ready
    }
}

struct WindowTarget {
    let element: AXUIElement
    let title: String
}

enum Windows {
    static var trusted: Bool { AXIsProcessTrusted() }
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    static func list(_ app: NSRunningApplication) -> [WindowTarget] {
        list(pid: app.processIdentifier)
    }
    static func list(pid: pid_t) -> [WindowTarget] {
        guard trusted else { return [] }
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.35)
        guard let windows = value(root, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            AXUIElementSetMessagingTimeout(window, 0.25)
            guard let title = value(window, kAXTitleAttribute) as? String, !title.isEmpty,
                  (value(window, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole else { return nil }
            return WindowTarget(element: window, title: title)
        }
    }
    static func matches(_ title: String, in windows: [WindowTarget]) -> [WindowTarget] {
        windows.filter { $0.title == title }
    }
    static func minimized(_ window: AXUIElement) -> Bool? {
        value(window, kAXMinimizedAttribute) as? Bool
    }
    static func setMinimized(_ window: AXUIElement, _ flag: Bool) -> AXError {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, flag ? kCFBooleanTrue : kCFBooleanFalse)
    }
}

final class RailPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class IconListView: NSView { override var isFlipped: Bool { true } }

final class ActionTarget: NSObject {
    var action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run(_ sender: Any?) { action() }
}

final class IconButton: NSButton {
    var appIcon: NSImage?
    var active = false { didSet { needsDisplay = true } }
    var parked = false { didSet { needsDisplay = true } }
    var hovering = false { didSet { needsDisplay = true } }
    var isAdd = false
    var context: (() -> NSMenu)?
    private var tracking: NSTrackingArea?
    override var isOpaque: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 3, dy: 3) }
    override func drawFocusRingMask() {
        NSColor.black.setFill()
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 8, yRadius: 8).fill()
    }
    @discardableResult func showMenu() -> Bool {
        guard let menu = context?() else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX + 8, y: bounds.midY), in: self)
        return true
    }
    override func accessibilityPerformShowMenu() -> Bool { showMenu() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.cancelOperation(nil); return }
        if event.keyCode == 125 || event.keyCode == 126 {
            if let next = event.keyCode == 125 ? nextKeyView : previousKeyView {
                window?.makeFirstResponder(next); next.scrollToVisible(next.bounds)
            }
            return
        }
        if (event.keyCode == 109 && event.modifierFlags.contains(.shift)) ||
            (event.keyCode == 36 && event.modifierFlags.contains(.control)) { showMenu(); return }
        if event.keyCode == 36 || event.keyCode == 76 {
            if let action { sendAction(action, to: target) }; return
        }
        super.keyDown(with: event)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = context?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event) }
        else { super.mouseDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.09 : 0.045).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 8, yRadius: 8).fill()
        }
        if isAdd {
            NSColor.secondaryLabelColor.setStroke()
            let path = NSBezierPath(); path.lineWidth = 1.3; path.lineCapStyle = .round
            let c = NSPoint(x: bounds.midX, y: bounds.midY)
            path.move(to: NSPoint(x: c.x - 5, y: c.y)); path.line(to: NSPoint(x: c.x + 5, y: c.y))
            path.move(to: NSPoint(x: c.x, y: c.y - 5)); path.line(to: NSPoint(x: c.x, y: c.y + 5)); path.stroke()
            return
        }
        let iconRect = NSRect(x: bounds.midX - 15, y: bounds.midY - 15, width: 30, height: 30)
        appIcon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: parked ? 0.48 : 1,
                      respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        if active && !parked {
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: bounds.midY - 1.5, width: 3, height: 3)).fill()
        }
        if parked {
            let badge = NSRect(x: bounds.midX + 5, y: bounds.midY + 4, width: 15, height: 15)
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(ovalIn: badge).fill()
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: badge.minX + 5, y: badge.minY + 4, width: 1.7, height: 7), xRadius: 0.6, yRadius: 0.6).fill()
            NSBezierPath(roundedRect: NSRect(x: badge.minX + 8.3, y: badge.minY + 4, width: 1.7, height: 7), xRadius: 0.6, yRadius: 0.6).fill()
        }
    }
}

final class RailView: NSView {
    var openOptions: (() -> NSMenu)?
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = openOptions?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSColor.windowBackgroundColor.setFill(); shape.fill()
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke(); shape.lineWidth = 0.7; shape.stroke()
        NSColor.tertiaryLabelColor.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 6, y: bounds.maxY - 11, width: 12, height: 2), xRadius: 1, yRadius: 1).fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSRect(x: 15, y: 40, width: bounds.width - 30, height: 0.5).fill()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var settings = Settings(pins: [])
    var panel: RailPanel!
    var statusItem: NSStatusItem!
    var root: RailView!
    var buttons: [UUID: IconButton] = [:]
    var targets: [ActionTarget] = []
    var menuTargets: [ActionTarget] = []
    var statuses: [UUID: PinStatus] = [:]
    var scrollView: NSScrollView?
    var keyboardReturnApp: NSRunningApplication?
    var windowQueryInFlight = false
    var windowQueryRevision = 0
    var timer: Timer?
    var isRebuilding = false
    var isDemo = CommandLine.arguments.contains("--preview")
    let inMemory = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--self-test")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settings = isDemo ? Settings(pins: defaults()) : (Persistence.load() ?? Settings(pins: defaults()))
        setupStatusItem()
        panel = RailPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Rail"
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.delegate = self
        // Restore before rebuilding: the saved display determines the viewport.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        panel.setFrame(NSRect(x: settings.x ?? Double(screen.minX + 18), y: settings.y ?? Double(screen.midY - Layout.height(settings.pins.count) / 2), width: Layout.width, height: Layout.height(settings.pins.count)), display: false)
        rebuild()
        panel.orderFrontRegardless()
        panel.onCancel = { [weak self] in
            guard let self else { return }
            self.panel.resignKey(); self.keyboardReturnApp?.activate(options: [])
            self.keyboardReturnApp = nil
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didHideApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(workspaceChanged), name: NSWorkspace.didUnhideApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
        if isDemo {
            if let first = settings.pins.first { buttons[first.id]?.active = true }
            if let last = settings.pins.last { buttons[last.id]?.parked = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.exportPreview(); NSApp.terminate(nil) }
        }
    }

    func defaults() -> [Pin] {
        let urls = ["/Applications/Figma.app", "/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app", "/Applications/Google Chrome.app"]
        return urls.compactMap { makePin(URL(fileURLWithPath: $0)) }
    }
    func makePin(_ url: URL) -> Pin? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return Pin(bundleID: id, path: url.path, name: name)
    }
    func resolvedURL(_ pin: Pin) -> URL? {
        let original = URL(fileURLWithPath: pin.path)
        if FileManager.default.fileExists(atPath: pin.path) { return original }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: pin.bundleID)
    }
    func app(_ pin: Pin) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: pin.bundleID).first { !$0.isTerminated }
    }
    func persist() {
        guard !inMemory else { return }
        do { try Persistence.save(settings) }
        catch { NSLog("Rail could not save settings: %@", error.localizedDescription) }
    }

    func rebuild() {
        isRebuilding = true
        defer { isRebuilding = false }
        let top = panel.frame.isEmpty ? nil : panel.frame.maxY
        let origin = panel.frame.origin
        let screens = NSScreen.screens.map(\.visibleFrame)
        let screenHeight = Layout.screen(for: panel.frame, in: screens)?.height ?? 800
        let height = Layout.fittedHeight(settings.pins.count, screenHeight: screenHeight)
        root = RailView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: height))
        root.setAccessibilityElement(false)
        root.openOptions = { [weak self] in self?.optionsMenu() ?? NSMenu() }
        targets = []; buttons = [:]
        let viewport = NSScrollView(frame: NSRect(x: 4, y: 42, width: 46, height: height - 60))
        viewport.drawsBackground = false; viewport.borderType = .noBorder
        viewport.hasVerticalScroller = CGFloat(settings.pins.count) * Layout.row > viewport.bounds.height
        viewport.scrollerStyle = .overlay; viewport.autohidesScrollers = true
        viewport.verticalScrollElasticity = .none; viewport.horizontalScrollElasticity = .none
        let list = IconListView(frame: NSRect(x: 0, y: 0, width: 46, height: CGFloat(settings.pins.count) * Layout.row))
        viewport.documentView = list; root.addSubview(viewport); scrollView = viewport
        var keyViews: [IconButton] = []
        for (index, pin) in settings.pins.enumerated() {
            let button = IconButton(frame: NSRect(x: 0, y: CGFloat(index) * Layout.row, width: 46, height: Layout.row))
            button.isBordered = false; button.bezelStyle = .regularSquare
            button.focusRingType = .exterior
            if let url = resolvedURL(pin) { button.appIcon = NSWorkspace.shared.icon(forFile: url.path) }
            else { button.appIcon = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: pin.name) }
            button.toolTip = pin.label + "\nClick to switch · Right-click for options"
            button.setAccessibilityLabel(pin.label)
            button.setAccessibilityHelp("Switch to \(pin.label). Open the context menu to park, choose a window, or remove.")
            let target = ActionTarget { [weak self] in self?.activate(pin) }
            button.target = target; button.action = #selector(ActionTarget.run(_:)); targets.append(target)
            button.context = { [weak self] in self?.pinMenu(pin) ?? NSMenu() }
            button.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Show options", handler: { [weak button] in button?.showMenu() ?? false })])
            list.addSubview(button); buttons[pin.id] = button; keyViews.append(button)
        }
        let plus = IconButton(frame: NSRect(x: 4, y: 3, width: 46, height: 36))
        plus.isAdd = true; plus.isBordered = false; plus.toolTip = "Add an app or window"
        plus.setAccessibilityLabel("Add app or window")
        plus.focusRingType = .exterior
        plus.context = { [weak self] in self?.addMenu() ?? NSMenu() }
        plus.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Show options", handler: { [weak plus] in plus?.showMenu() ?? false })])
        let plusTarget = ActionTarget { [weak self, weak plus] in
            guard let self, let plus else { return }
            self.addMenu().popUp(positioning: nil, at: NSPoint(x: plus.bounds.maxX + 8, y: plus.bounds.maxY), in: plus)
        }
        plus.target = plusTarget; plus.action = #selector(ActionTarget.run(_:)); targets.append(plusTarget)
        root.addSubview(plus)
        keyViews.append(plus)
        for index in keyViews.indices { keyViews[index].nextKeyView = keyViews[(index + 1) % keyViews.count] }
        panel.contentView = root
        panel.initialFirstResponder = keyViews.first
        let frame = NSRect(x: origin.x, y: top.map { $0 - height } ?? origin.y, width: Layout.width, height: height)
        panel.setFrame(Layout.clamp(frame, to: NSScreen.screens.map(\.visibleFrame)), display: true)
        refresh()
    }

    func restorePosition() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let point = NSPoint(x: settings.x ?? Double(screen.minX + 18), y: settings.y ?? Double(screen.midY - panel.frame.height / 2))
        isRebuilding = true
        panel.setFrame(NSRect(origin: point, size: panel.frame.size), display: false)
        isRebuilding = false
        rebuild(); savePosition()
    }
    func windowDidMove(_ notification: Notification) {
        guard !isRebuilding else { return }
        settings.x = panel.frame.minX; settings.y = panel.frame.minY; persist()
    }
    @objc func screensChanged() {
        rebuild(); savePosition()
    }
    func windowDidChangeScreen(_ notification: Notification) {
        guard !isRebuilding else { return }
        rebuild(); savePosition()
    }
    @objc func workspaceChanged(_ notification: Notification) { refresh() }

    func refresh() {
        guard !isDemo else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let access = Windows.trusted
        var requests: [(pin: Pin, pid: pid_t, frontmost: Bool)] = []
        for pin in settings.pins {
            let running = app(pin)
            if pin.windowTitle != nil {
                if access, let running {
                    requests.append((pin, running.processIdentifier, front?.processIdentifier == running.processIdentifier))
                    if statuses[pin.id] == nil || statuses[pin.id] == .stopped || statuses[pin.id] == .needsAccess {
                        apply(.unknown, to: pin)
                    }
                } else {
                    apply(running == nil ? .stopped : .needsAccess, to: pin)
                }
            } else if let running {
                apply(running.isHidden ? .parked : (front?.processIdentifier == running.processIdentifier ? .active : .ready), to: pin)
            } else { apply(.stopped, to: pin) }
        }
        guard !requests.isEmpty, !windowQueryInFlight else { return }
        windowQueryInFlight = true
        let revision = windowQueryRevision
        let work = requests
        // A busy app must not block this strip's clicks or native menus while polled.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var windowsByApp: [pid_t: [WindowTarget]] = [:]
            let results = work.map { request -> (Pin, pid_t, PinStatus) in
                let windows = windowsByApp[request.pid] ?? Windows.list(pid: request.pid)
                windowsByApp[request.pid] = windows
                let matching = Windows.matches(request.pin.windowTitle!, in: windows)
                var focused = false
                if request.frontmost {
                    let root = AXUIElementCreateApplication(request.pid)
                    AXUIElementSetMessagingTimeout(root, 0.25)
                    if let element = Windows.value(root, kAXFocusedWindowAttribute), CFGetTypeID(element) == AXUIElementGetTypeID() {
                        let window = element as! AXUIElement
                        AXUIElementSetMessagingTimeout(window, 0.25)
                        focused = (Windows.value(window, kAXTitleAttribute) as? String) == request.pin.windowTitle
                    }
                }
                return (request.pin, request.pid, PinStatus.window(running: true, access: true, matches: matching.count,
                        minimized: matching.count == 1 ? Windows.minimized(matching[0].element) : nil, focused: focused))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.windowQueryInFlight = false
                guard self.windowQueryRevision == revision else { self.refresh(); return }
                let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                for (pin, pid, status) in results where self.settings.pins.contains(pin) && self.app(pin)?.processIdentifier == pid && Windows.trusted {
                    let currentStatus = status == .active && frontPID != pid ? PinStatus.ready : status
                    self.apply(currentStatus.consideringHiddenApp(self.app(pin)?.isHidden == true), to: pin)
                }
            }
        }
    }
    func apply(_ status: PinStatus, to pin: Pin) {
        statuses[pin.id] = status
        guard let button = buttons[pin.id] else { return }
        let hint = pin.windowTitle == nil ? "Hiding affects all windows. The app keeps running." : "Parking minimizes this window. The app keeps running."
        let tooltip = "\(pin.label)\n\(status.rawValue)\nClick to switch · Right-click for options\n\(hint)"
        guard button.toolTip != tooltip else { return }
        button.active = status == .active; button.parked = status == .parked
        button.toolTip = tooltip
        button.setAccessibilityLabel("\(pin.label), \(status.rawValue)")
        button.setAccessibilityHelp("\(status.primaryAction). \(hint) Use Show options for window selection and other actions.")
    }
    func savePosition() {
        settings.x = panel.frame.minX; settings.y = panel.frame.minY; persist()
    }
    func focusRail() {
        let current = NSWorkspace.shared.frontmostApplication
        if current?.bundleIdentifier != Bundle.main.bundleIdentifier { keyboardReturnApp = current }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let first = panel.initialFirstResponder {
            panel.makeFirstResponder(first); first.scrollToVisible(first.bounds)
        }
    }

    func activate(_ pin: Pin) {
        if let running = app(pin) { focus(pin, in: running); return }
        guard let url = resolvedURL(pin) else {
            message("App unavailable", "\(pin.name) has moved or was removed. Add it again with +."); return
        }
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] running, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.message("Couldn’t open \(pin.name)", error.localizedDescription) }
                else if let running {
                    // Existing window titles may not exist until the app has restored its documents.
                    if pin.windowTitle != nil {
                        self.message("\(pin.name) opened", "Choose the document window again from this icon’s right-click menu after it opens.")
                    } else { self.focus(pin, in: running) }
                }
            }
        }
    }
    func focus(_ pin: Pin, in running: NSRunningApplication) {
        windowQueryRevision += 1
        if let title = pin.windowTitle {
            guard Windows.trusted else { explainAccessibility(); return }
            let matching = Windows.matches(title, in: Windows.list(running))
            guard matching.count == 1, let target = matching.first else {
                message("Choose this window again", matching.isEmpty
                    ? "“\(title)” is no longer available. Its title may have changed. Right-click this icon and choose a window."
                    : "More than one window has this title. Rail won’t guess which one to switch to. Choose a uniquely titled window or switch to the whole app.")
                return
            }
            guard let minimized = Windows.minimized(target.element) else {
                message("Window state unavailable", "\(pin.name) did not report whether this window is minimized. Try again, or use Switch to → Whole app from the icon’s menu."); return
            }
            if minimized {
                guard Windows.setMinimized(target.element, false) == .success else {
                    message("Couldn’t restore the window", "\(pin.name) did not allow Rail to restore this window."); return
                }
            }
            running.unhide()
            let raised = AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
            let activated = running.activate(options: [])
            if raised != .success || !activated {
                message("Window switching is unavailable", "\(pin.name) did not accept the window-switch request. You can still pin the whole app.")
                return
            }
        } else {
            running.unhide()
            guard running.activate(options: []) else {
                message("Couldn’t switch to \(pin.name)", "The app may be closing or busy. Try again in a moment."); return
            }
        }
        refresh()
    }

    func park(_ pin: Pin) {
        windowQueryRevision += 1
        guard let running = app(pin) else { return }
        if let title = pin.windowTitle {
            guard Windows.trusted else { explainAccessibility(); return }
            let matching = Windows.matches(title, in: Windows.list(running))
            guard matching.count == 1, let target = matching.first else {
                message("Choose this window again", "This window is unavailable or has an ambiguous title. Right-click the icon to choose it again."); return
            }
            guard Windows.setMinimized(target.element, true) == .success else {
                message("Couldn’t park this window", "\(pin.name) doesn’t allow this window to be minimized right now."); return
            }
        } else {
            // The return value can precede the actual hidden state. Confirm on
            // the next run-loop turns instead of showing a false failure alert.
            let revision = windowQueryRevision
            _ = running.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                guard let self, self.windowQueryRevision == revision, self.settings.pins.contains(pin),
                      let current = self.app(pin), current.processIdentifier == running.processIdentifier else { return }
                self.refresh()
                if !current.isHidden {
                    self.message("Couldn’t confirm app hiding", "\(pin.name) is still visible. Try again from its icon’s menu.")
                }
            }
            return
        }
        apply(.parked, to: pin)
    }

    func item(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let target = ActionTarget(action); menuTargets.append(target)
        let item = NSMenuItem(title: title, action: #selector(ActionTarget.run(_:)), keyEquivalent: "")
        item.target = target; item.isEnabled = enabled; return item
    }
    func heading(_ text: String) -> NSMenuItem { let row = NSMenuItem(title: text, action: nil, keyEquivalent: ""); row.isEnabled = false; return row }

    func pinMenu(_ pin: Pin) -> NSMenu {
        refresh()
        menuTargets = []
        let menu = NSMenu(); menu.autoenablesItems = false
        let status = statuses[pin.id] ?? .stopped
        menu.addItem(heading(pin.label))
        menu.addItem(heading(status.rawValue))
        menu.addItem(item(status.primaryAction) { [weak self] in self?.activate(pin) })
        menu.addItem(item(pin.windowTitle == nil ? "Hide app (all windows)" : "Park window", enabled: status.canPark) { [weak self] in self?.park(pin) })
        menu.addItem(.separator())
        let sub = NSMenu(); sub.autoenablesItems = false
        let whole = item("Whole app") { [weak self] in self?.chooseTarget(pin, title: nil) }
        whole.state = pin.windowTitle == nil ? .on : .off; sub.addItem(whole)
        if let running = app(pin), Windows.trusted {
            let windows = Windows.list(running)
            if windows.isEmpty { sub.addItem(heading("No titled windows available")) }
            let counts = Dictionary(grouping: windows, by: \.title)
            for window in windows {
                let unique = counts[window.title]?.count == 1
                let row = item(window.title + (unique ? "" : " (same title)"), enabled: unique) { [weak self] in self?.chooseTarget(pin, title: window.title) }
                row.state = pin.windowTitle == window.title ? .on : .off; sub.addItem(row)
            }
        } else if !Windows.trusted {
            sub.addItem(item("Enable individual windows…") { [weak self] in self?.explainAccessibility() })
        } else {
            sub.addItem(heading("Open the app to choose a window"))
        }
        let row = NSMenuItem(title: "Switch to", action: nil, keyEquivalent: ""); row.submenu = sub; menu.addItem(row)
        menu.addItem(.separator())
        if let index = settings.pins.firstIndex(where: { $0.id == pin.id }) {
            menu.addItem(item("Move up", enabled: index > 0) { [weak self] in self?.move(pin, by: -1) })
            menu.addItem(item("Move down", enabled: index < settings.pins.count - 1) { [weak self] in self?.move(pin, by: 1) })
        }
        menu.addItem(item("Remove from Rail") { [weak self] in
            guard let self else { return }; self.settings.pins.removeAll { $0.id == pin.id }
            self.statuses.removeValue(forKey: pin.id); self.rebuild(); self.savePosition()
        })
        return menu
    }
    func chooseTarget(_ pin: Pin, title: String?) {
        guard let index = settings.pins.firstIndex(where: { $0.id == pin.id }) else { return }
        settings.pins[index].windowTitle = title
        statuses.removeValue(forKey: pin.id); rebuild(); savePosition()
    }
    func move(_ pin: Pin, by offset: Int) {
        guard let index = settings.pins.firstIndex(where: { $0.id == pin.id }), settings.pins.indices.contains(index + offset) else { return }
        settings.pins.swapAt(index, index + offset); rebuild(); savePosition()
    }

    func addMenu() -> NSMenu {
        menuTargets = []
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(heading("Add to Rail"))
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.bundleURL != nil
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for running in apps {
            guard let url = running.bundleURL, let pin = makePin(url) else { continue }
            let row = item(pin.name) { [weak self] in self?.add(pin) }
            row.image = running.icon; row.image?.size = NSSize(width: 16, height: 16)
            if settings.pins.contains(where: { $0.bundleID == pin.bundleID && $0.windowTitle == nil }) { row.state = .on }
            menu.addItem(row)
        }
        menu.addItem(.separator())
        menu.addItem(item("Choose application…") { [weak self] in self?.chooseApplication() })
        return menu
    }
    func add(_ pin: Pin) {
        if settings.pins.contains(where: { $0.bundleID == pin.bundleID && $0.windowTitle == nil }) { return }
        settings.pins.append(pin); rebuild(); savePosition()
    }
    func chooseApplication() {
        NSApp.activate(ignoringOtherApps: true)
        let chooser = NSOpenPanel(); chooser.title = "Add an app to Rail"
        chooser.directoryURL = URL(fileURLWithPath: "/Applications")
        chooser.canChooseFiles = true; chooser.canChooseDirectories = false
        chooser.allowedContentTypes = [.applicationBundle]; chooser.allowsMultipleSelection = false
        chooser.prompt = "Add"
        if chooser.runModal() == .OK, let url = chooser.url, let pin = makePin(url) { add(pin) }
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: "Rail")
            button.toolTip = "Rail"; button.target = self; button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }
    @objc func statusClicked(_ sender: NSStatusBarButton) {
        optionsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }
    func optionsMenu() -> NSMenu {
        menuTargets = []
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(heading("Rail"))
        menu.addItem(item(panel.isVisible ? "Hide Rail" : "Show Rail") { [weak self] in
            guard let self else { return }; if self.panel.isVisible { self.panel.orderOut(nil) } else { self.panel.orderFrontRegardless() }
        })
        menu.addItem(item("Focus Rail with keyboard") { [weak self] in self?.focusRail() })
        menu.addItem(item("Reset position") { [weak self] in
            guard let self else { return }; self.settings.x = nil; self.settings.y = nil; self.restorePosition(); self.panel.orderFrontRegardless(); self.persist()
        })
        menu.addItem(item("Individual window access…") { [weak self] in self?.explainAccessibility() })
        menu.addItem(.separator())
        menu.addItem(item("About Rail") { [weak self] in self?.message("Rail 0.1.1", "A small place for the apps you’re working with.\n\nClick to switch. Right-click for options. Drag the top grip to move.\n\nUse Focus Rail with keyboard in this menu, then ↑/↓ to move, Return to switch, Control-Return for options and Escape to return.\n\nParking hides an app or minimizes a chosen window; it keeps running. Rail does not suspend processes. Everything stays open when you quit Rail.") })
        menu.addItem(item("Quit Rail") { NSApp.terminate(nil) })
        return menu
    }
    func explainAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = Windows.trusted ? "Window access is enabled" : "Control individual windows"
        alert.informativeText = Windows.trusted
            ? "Right-click an app icon and use Switch to to choose a specific window."
            : "App switching works already. To choose and park individual windows, enable Rail in System Settings → Privacy & Security → Accessibility.\n\nRail reads window titles only on this Mac."
        if !Windows.trusted { alert.addButton(withTitle: "Open Settings") }
        alert.addButton(withTitle: Windows.trusted ? "Done" : "Later")
        if alert.runModal() == .alertFirstButtonReturn && !Windows.trusted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    func message(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); persist() }

    func exportPreview() {
        guard let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > index + 1 else { return }
        let out = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        // Render this exact native view without capturing the user's screen.
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: out) }
    }

    static func makeIcon() {
        guard let i = CommandLine.arguments.firstIndex(of: "--make-icon"), CommandLine.arguments.count > i + 1 else { return }
        let folder = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = size * scale
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
                let n = CGFloat(px)
                NSBezierPath(roundedRect: NSRect(x: n * 0.08, y: n * 0.08, width: n * 0.84, height: n * 0.84), xRadius: n * 0.19, yRadius: n * 0.19).fill()
                NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: n * 0.37, y: n * 0.19, width: n * 0.26, height: n * 0.62), xRadius: n * 0.1, yRadius: n * 0.1).fill()
                for j in 0..<3 {
                    NSColor(calibratedWhite: j == 2 ? 0.22 : 0.62, alpha: 1).setFill()
                    NSBezierPath(ovalIn: NSRect(x: n * 0.455, y: n * (0.31 + CGFloat(j) * 0.15), width: n * 0.09, height: n * 0.09)).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
                    try? png.write(to: folder.appendingPathComponent(name))
                }
            }
        }
    }

    static func renderRail() {
        guard let i = CommandLine.arguments.firstIndex(of: "--render-rail"), CommandLine.arguments.count > i + 1 else { return }
        let height = Layout.height(3)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 108, pixelsHigh: Int(height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: 2, y: 2)
        let dark = CommandLine.arguments.contains("--dark")
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            // The same drawing code used on screen, rendered without desktop access.
            let rail = RailView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: height))
            rail.draw(rail.bounds)
            let paths = ["/Applications/Figma.app", "/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app", "/Applications/Google Chrome.app"]
            for (index, path) in paths.enumerated() {
                let button = IconButton(frame: NSRect(x: 0, y: 0, width: 46, height: 44))
                if let resources = Bundle(path: path)?.resourceURL {
                    let declared = Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
                    let files = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
                    let declaredURL = declared.map { resources.appendingPathComponent($0.hasSuffix(".icns") ? $0 : $0 + ".icns") }
                    let iconURL = declaredURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                        ?? files.first { $0.pathExtension == "icns" }
                    if let iconURL { button.appIcon = NSImage(contentsOf: iconURL) }
                }
                button.active = index == 0; button.parked = index == 2
                button.hovering = index == 1 && CommandLine.arguments.contains("--hover")
                context.saveGState(); context.translateBy(x: 4, y: height - 18 - CGFloat(index + 1) * Layout.row)
                button.draw(button.bounds); context.restoreGState()
            }
            let plus = IconButton(frame: NSRect(x: 0, y: 0, width: 46, height: 36)); plus.isAdd = true
            context.saveGState(); context.translateBy(x: 4, y: 3); plus.draw(plus.bounds); context.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
    }

    static func selfTest() {
        var failures: [String] = []
        var count = 0
        func check(_ flag: Bool, _ text: String) { count += 1; if !flag { failures.append(text) } }
        // Configuration survives Unicode document titles and an empty working set.
        let original = Settings(pins: [Pin(bundleID: "test.app", path: "/Applications/Test.app", name: "Test", windowTitle: "Résumé — 草稿")], x: -1200, y: 70)
        let roundtrip = try? JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(original))
        check(roundtrip?.pins == original.pins && roundtrip?.x == original.x, "Configuration round trip")
        let empty = try? JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(Settings(pins: [])))
        check(empty?.pins.isEmpty == true, "Empty rail survives restart")
        let screens = [NSRect(x: -1440, y: 0, width: 1440, height: 900), NSRect(x: 0, y: 0, width: 1512, height: 944)]
        let lost = Layout.clamp(NSRect(x: 5000, y: -1000, width: 54, height: 194), to: screens)
        check(screens.contains(where: { $0.contains(lost) }), "Unplugged display recovers on screen")
        let left = NSRect(x: -1200, y: 300, width: 54, height: 194)
        check(Layout.clamp(left, to: screens) == left, "Negative-coordinate display is preserved")
        let element = AXUIElementCreateSystemWide()
        let choices = [WindowTarget(element: element, title: "Draft"), WindowTarget(element: element, title: "Draft"), WindowTarget(element: element, title: "Final")]
        check(Windows.matches("Draft", in: choices).count == 2, "Duplicate window titles stay ambiguous")
        check(Windows.matches("Final", in: choices).count == 1, "Unique window title resolves")
        check(Windows.matches("Old name", in: choices).isEmpty, "Stale window title does not target another document")
        check(Layout.height(0) >= 50 && Layout.height(3) == 194, "Empty and default rail fit controls")
        check(Layout.fittedHeight(3, screenHeight: 800) == 194, "Normal three-app rail keeps its approved size")
        check(Layout.fittedHeight(20, screenHeight: 400) == 384, "Saved long rail fits a smaller display without dropping pins")
        check(Layout.screen(for: NSRect(x: -5000, y: 300, width: 54, height: 194), in: screens) == screens[0], "Offscreen position recovers on the nearest display")
        check(PinStatus.window(running: false, access: false, matches: 0, minimized: nil, focused: false) == .stopped, "Stopped window pin reports the app is not running")
        check(PinStatus.window(running: true, access: false, matches: 1, minimized: true, focused: true) == .needsAccess, "Revoked access does not claim active or parked state")
        check(PinStatus.window(running: true, access: true, matches: 0, minimized: nil, focused: true) == .missingWindow, "Closed window cannot show an active dot")
        check(PinStatus.window(running: true, access: true, matches: 2, minimized: false, focused: true) == .missingWindow, "Ambiguous document cannot show an active dot")
        check(PinStatus.window(running: true, access: true, matches: 1, minimized: nil, focused: true) == .unknown, "A failed AX read is not treated as an unminimized window")
        check(PinStatus.window(running: true, access: true, matches: 1, minimized: true, focused: false) == .parked, "An already-minimized window is recognized after restart")
        check(PinStatus.window(running: true, access: true, matches: 1, minimized: false, focused: false) == .ready, "A window restored outside Rail stops showing parked")
        check(PinStatus.window(running: true, access: true, matches: 1, minimized: false, focused: true) == .active, "Only a known visible focused window shows active")
        check(!PinStatus.parked.canPark && !PinStatus.needsAccess.canPark && !PinStatus.unknown.canPark, "Parking is unavailable for parked or unreadable targets")
        check(PinStatus.parked.primaryAction == "Bring back", "Parked icon menu offers the correct recovery action")
        check(PinStatus.ready.consideringHiddenApp(true) == .parked, "A window in a hidden app also shows parked")
        check(PinStatus.missingWindow.consideringHiddenApp(true) == .missingWindow, "A hidden app does not mask a missing document")
        print(failures.isEmpty ? "PASS: \(count) focused checks (persistence, screen recovery, window targeting, state transitions, compact layout)." : "FAIL: \(failures.joined(separator: "; "))")
        if !failures.isEmpty { exit(1) }
    }
}

if CommandLine.arguments.contains("--self-test") { AppDelegate.selfTest(); exit(0) }
if CommandLine.arguments.contains("--make-icon") { AppDelegate.makeIcon(); exit(0) }
if CommandLine.arguments.contains("--render-rail") { AppDelegate.renderRail(); exit(0) }
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
