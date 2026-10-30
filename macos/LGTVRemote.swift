import AppKit

private final class RemoteFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private final class WindowDragHandle: NSView {
    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startMouse = window.convertPoint(toScreen: event.locationInWindow)
        startOrigin = window.frame.origin
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: startOrigin.x + mouse.x - startMouse.x,
                                      y: startOrigin.y + mouse.y - startMouse.y))
    }
}

private final class RemoteController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var commandMenu: NSMenu!
    private var statusLine: NSMenuItem!
    private var hostLine: NSMenuItem!
    private var appsMenu: NSMenu!
    private var inputsMenu: NSMenu!
    private var remotePanel: NSWindow?
    private var padFocusView: RemoteFocusView?
    private var panelStatus: NSTextField?
    private var feedbackPanel: NSPanel?
    private var feedbackTitle: NSTextField?
    private var feedbackMessage: NSTextField?
    private var feedbackSpinner: NSProgressIndicator?
    private var keyMonitor: Any?
    private var directionGroup: NSView?
    private var trackpadGroup: NSView?
    private let pointer = PointerSession()
    private var controls: [NSMenuItem] = []
    private var busy = false
    private var pending: [([String], ((Bool, String) -> Void)?)] = []

    private var host: String {
        get { UserDefaults.standard.string(forKey: "tvHost") ?? "" }
        set {
            let changed = newValue != host
            if changed { pointer.stop() }
            UserDefaults.standard.set(newValue, forKey: "tvHost")
            hostLine.title = "TV: \(newValue.isEmpty ? "not selected" : newValue)"
            updateControls()
            if changed && !newValue.isEmpty { refreshApps() }
            if changed && trackpadGroup?.isHidden == false && remotePanel?.isVisible == true { startPointer() }
        }
    }

    private var cliPath: String {
        ProcessInfo.processInfo.environment["LGTV_CLI_PATH"]
            ?? Bundle.main.resourceURL?.appendingPathComponent("Backend/lg-tv/lg-tv").path ?? ""
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("LG TV Remote: menu-bar app launched")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tv", accessibilityDescription: "LG TV Remote")
        statusItem.button?.title = "TV"
        let menu = NSMenu()
        menu.addItem(withTitle: "LG TV Remote", action: nil, keyEquivalent: "")
        hostLine = menu.addItem(withTitle: "TV: not selected", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add(menu, "Discover TV", action: #selector(discover))
        add(menu, "Set TV IP…", action: #selector(setHost))
        add(menu, "Pair / Check Connection", action: #selector(pair), control: true)
        add(menu, "Check TV Status", action: #selector(checkStatus), control: true)
        menu.addItem(.separator())
        add(menu, "Show Remote", action: #selector(openRemotePad))
        add(menu, "Hide Remote", action: #selector(hideRemote))
        add(menu, "Wake Screen", action: #selector(wakeScreen), control: true)
        add(menu, "Power On", action: #selector(powerOn), control: true)
        add(menu, "Set Up Power On", action: #selector(setupPowerOn), control: true)
        add(menu, "Volume Up", action: #selector(volumeUp), control: true)
        add(menu, "Volume Down", action: #selector(volumeDown), control: true)
        add(menu, "Mute", action: #selector(mute), control: true)
        add(menu, "Unmute", action: #selector(unmute), control: true)
        menu.addItem(.separator())
        add(menu, "Up", action: #selector(up), control: true)
        add(menu, "Down", action: #selector(down), control: true)
        add(menu, "Left", action: #selector(left), control: true)
        add(menu, "Right", action: #selector(right), control: true)
        add(menu, "OK", action: #selector(enter), control: true)
        add(menu, "Home", action: #selector(home), control: true)
        add(menu, "Back", action: #selector(back), control: true)
        menu.addItem(.separator())
        let launchItem = NSMenuItem(title: "Launch App", action: nil, keyEquivalent: "")
        appsMenu = NSMenu(title: "Launch App")
        launchItem.submenu = appsMenu
        menu.addItem(launchItem)
        controls.append(launchItem)
        add(menu, "Refresh App List", action: #selector(refreshAppsAction), control: true)
        let inputItem = NSMenuItem(title: "TV Inputs", action: nil, keyEquivalent: "")
        inputsMenu = NSMenu(title: "TV Inputs")
        inputItem.submenu = inputsMenu
        menu.addItem(inputItem)
        controls.append(inputItem)
        add(menu, "Channel Up", action: #selector(channelUp), control: true)
        add(menu, "Channel Down", action: #selector(channelDown), control: true)
        add(menu, "Power Off…", action: #selector(powerOff), control: true)
        menu.addItem(.separator())
        statusLine = menu.addItem(withTitle: "Discovering your TV…", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        commandMenu = menu
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.toolTip = "Click to show or hide remote. Right-click for options."
        hostLine.title = "TV: \(host.isEmpty ? "not selected" : host)"
        updateControls()
        if host.isEmpty { scan(showErrors: false) } else { refreshApps() }
        openRemotePad()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Activation/reopen events can follow a close. Only the explicit menu action
        // should restore a closed remote; otherwise the red close button appears inert.
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { pointer.stop() }

    @objc private func statusItemClicked() {
        if NSApplication.shared.currentEvent?.type == .rightMouseUp ||
            NSApplication.shared.currentEvent?.modifierFlags.contains(.control) == true {
            statusItem.menu = commandMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if remotePanel?.isVisible == true && remotePanel?.isMiniaturized == false {
            hideRemote()
        } else {
            openRemotePad()
        }
    }

    @objc private func hideRemote() {
        pointer.stop()
        remotePanel?.orderOut(nil)
        feedbackPanel?.orderOut(nil)
        statusItem.button?.toolTip = "Remote hidden. Click TV to show it again; right-click for options."
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === remotePanel else { return true }
        hideRemote()
        return false
    }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === remotePanel { pointer.stop() }
    }

    private func add(_ menu: NSMenu, _ title: String, action: Selector, control: Bool = false) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        if control { controls.append(item) }
    }

    private func updateControls() {
        for item in controls { item.isEnabled = !host.isEmpty && !busy }
    }

    private func note(_ message: String) {
        let line = message.replacingOccurrences(of: "\n", with: " ")
        statusLine.title = String(line.prefix(70))
        statusItem.button?.toolTip = message + "\nClick TV to show/hide remote. Right-click for options."
        panelStatus?.stringValue = String(line.prefix(65))
        panelStatus?.toolTip = message
    }

    private func prompt(_ title: String, value: String = "") -> String? {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func feedback(_ title: String, message: String, working: Bool = false) {
        if feedbackPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 170),
                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false
            )
            panel.title = "LG TV Remote — Status"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            let view = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 360, height: 170))
            view.material = .popover
            view.blendingMode = .behindWindow
            view.state = .active
            let titleLabel = NSTextField(labelWithString: "")
            titleLabel.frame = NSRect(x: 20, y: 125, width: 286, height: 24)
            titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
            view.addSubview(titleLabel)
            feedbackTitle = titleLabel
            let messageLabel = NSTextField(wrappingLabelWithString: "")
            messageLabel.frame = NSRect(x: 20, y: 45, width: 320, height: 72)
            messageLabel.isSelectable = true
            messageLabel.font = .systemFont(ofSize: 13)
            view.addSubview(messageLabel)
            feedbackMessage = messageLabel
            let spinner = NSProgressIndicator(frame: NSRect(x: 320, y: 129, width: 16, height: 16))
            spinner.style = .spinning
            spinner.isDisplayedWhenStopped = false
            view.addSubview(spinner)
            feedbackSpinner = spinner
            let done = NSButton(title: "Close", target: self, action: #selector(closeFeedback))
            done.bezelStyle = .rounded
            done.frame = NSRect(x: 266, y: 10, width: 78, height: 28)
            view.addSubview(done)
            panel.contentView = view
            panel.center()
            feedbackPanel = panel
        }
        // Size the status window to the message so keyboard guidance is never clipped.
        let bounds = (message as NSString).boundingRect(
            with: NSSize(width: 320, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let messageHeight = max(72, ceil(bounds.height) + 8)
        feedbackPanel?.setContentSize(NSSize(width: 360, height: messageHeight + 98))
        feedbackMessage?.frame = NSRect(x: 20, y: 45, width: 320, height: messageHeight)
        feedbackTitle?.frame.origin.y = messageHeight + 53
        feedbackSpinner?.frame.origin.y = messageHeight + 57
        feedbackTitle?.stringValue = title
        feedbackMessage?.stringValue = message
        feedbackMessage?.toolTip = message
        if working { feedbackSpinner?.startAnimation(nil) }
        else { feedbackSpinner?.stopAnimation(nil) }
        feedbackPanel?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func closeFeedback() { feedbackPanel?.close() }

    private func run(_ arguments: [String], completion: ((Bool, String) -> Void)? = nil) {
        if busy {
            if pending.count < 25 { pending.append((arguments, completion)) }
            else {
                note("Remote queue full; wait for the TV")
                completion?(false, "Remote queue full; wait for the TV, then retry")
            }
            return
        }
        let cli = cliPath
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            let message = "The bundled remote helper is missing. Reinstall LG TV Remote."
            note(message)
            if let completion { completion(false, message) }
            else { feedback("Remote unavailable", message: message) }
            return
        }
        busy = true
        updateControls()
        note("Working…")
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var succeeded = false
            var message = ""
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                succeeded = process.terminationStatus == 0
                message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                message = message.replacingOccurrences(of: "^TV command failed [(][^)]+[)]: ", with: "", options: .regularExpression)
                if message.isEmpty { message = succeeded ? "Command finished" : "Command failed" }
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.busy = false
                self.updateControls()
                if !succeeded { self.pending.removeAll() }
                self.note(message)
                completion?(succeeded, message)
                if !self.busy && !self.pending.isEmpty {
                    let next = self.pending.removeFirst()
                    self.run(next.0, completion: next.1)
                }
            }
        }
    }

    private func command(_ name: String, _ extra: String? = nil, feedbackTitle: String? = nil) {
        guard !host.isEmpty else {
            feedback("Select a TV", message: "Choose Discover TV or Set TV IP first.")
            return
        }
        var args = [name, host]
        if let extra { args.append(extra) }
        if let feedbackTitle {
            feedback(feedbackTitle, message: "Contacting your TV…", working: true)
            run(args) { succeeded, output in
                self.feedback(succeeded ? feedbackTitle : "Could not complete check", message: output)
            }
        } else { run(args) }
    }

    private func refreshApps(userInitiated: Bool = false, retriesRemaining: Int = 2) {
        guard !host.isEmpty else { return }
        if userInitiated { feedback("Refreshing apps", message: "Loading installed apps from your TV…", working: true) }
        appsMenu.removeAllItems()
        appsMenu.addItem(withTitle: "Loading apps…", action: nil, keyEquivalent: "")
        run(["apps", host]) { succeeded, output in
            self.appsMenu.removeAllItems()
            guard succeeded else {
                if output.contains("No route to host") && retriesRemaining > 0 {
                    let requestedHost = self.host
                    self.note("Connecting to TV…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        guard self.host == requestedHost else { return }
                        self.refreshApps(userInitiated: userInitiated, retriesRemaining: retriesRemaining - 1)
                    }
                    return
                }
                if userInitiated { self.feedback("App list failed", message: output) }
                self.appsMenu.addItem(withTitle: "Could not load apps", action: nil, keyEquivalent: "")
                self.note("App list failed; choose Refresh App List")
                return
            }
            let apps: [(String, String)] = output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty else { return nil }
                let id = String(parts[0])
                let title = parts[1].isEmpty ? id : String(parts[1])
                return (id, title)
            }.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
            for (id, title) in apps {
                let item = self.appsMenu.addItem(withTitle: title, action: #selector(self.launchSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
            }
            if apps.isEmpty {
                self.appsMenu.addItem(withTitle: "No apps reported", action: nil, keyEquivalent: "")
            }
            self.note("Loaded \(apps.count) apps; choose Launch App")
            if userInitiated { self.feedback("App list refreshed", message: "Loaded \(apps.count) apps. Choose Launch App in the TV menu to open one.") }
            NSLog("LG TV Remote: loaded %ld app names", apps.count)
            self.refreshInputs()
        }
    }

    private func refreshInputs() {
        guard !host.isEmpty else { return }
        inputsMenu.removeAllItems()
        inputsMenu.addItem(withTitle: "Loading inputs…", action: nil, keyEquivalent: "")
        run(["inputs", host]) { succeeded, output in
            self.inputsMenu.removeAllItems()
            guard succeeded else {
                self.inputsMenu.addItem(withTitle: "Could not load inputs", action: nil, keyEquivalent: "")
                self.note("Input list failed")
                return
            }
            let inputs: [(String, String)] = output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty else { return nil }
                return (String(parts[0]), parts[1].isEmpty ? String(parts[0]) : String(parts[1]))
            }
            for (id, title) in inputs {
                let item = self.inputsMenu.addItem(withTitle: title, action: #selector(self.selectInput(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
            }
            if inputs.isEmpty { self.inputsMenu.addItem(withTitle: "No inputs reported", action: nil, keyEquivalent: "") }
            self.note("Remote ready; \(inputs.count) TV inputs available")
        }
    }

    @objc private func refreshAppsAction() { refreshApps(userInitiated: true) }
    @objc private func launchSelected(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        command("launch", id)
    }
    @objc private func selectInput(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        command("set-input", id)
    }

    private func scan(showErrors: Bool) {
        if showErrors { feedback("Discovering TV", message: "Searching your local network for LG TVs…", working: true) }
        run(["discover"]) { succeeded, output in
            NSLog("LG TV Remote: discovery finished, success=%@", succeeded ? "yes" : "no")
            guard succeeded else {
                self.note("Discovery failed; choose Set TV IP…")
                if showErrors { self.feedback("Discovery failed", message: output + "\nYou can also use Set TV IP in the TV menu.") }
                return
            }
            let addresses = output.split(separator: "\n").map(String.init)
            if addresses.count == 1 {
                self.host = addresses[0]
                self.note("Found TV at \(addresses[0]); controls are ready")
                if showErrors { self.feedback("TV found", message: "Address: \(addresses[0])\nSelected for control. Use Pair / Check Connection to verify authorization.") }
            } else {
                self.note("Multiple TVs found; choose Set TV IP…")
                if showErrors { self.feedback("Multiple TVs found", message: output + "\nChoose your own TV with Set TV IP.") }
            }
        }
    }
    @objc private func discover() { scan(showErrors: true) }
    @objc private func setHost() {
        if let value = prompt("TV IP address", value: host) {
            host = value
            note("TV address saved")
            feedback("TV address saved", message: "Address: \(value)\nUse Pair / Check Connection to verify authorization.")
        }
    }
    @objc private func pair() { command("pair", feedbackTitle: "TV Connection") }
    @objc private func volumeUp() { command("volume-up") }
    @objc private func volumeDown() { command("volume-down") }
    @objc private func mute() { command("mute") }
    @objc private func unmute() { command("unmute") }
    @objc private func up() { command("button", "UP") }
    @objc private func down() { command("button", "DOWN") }
    @objc private func left() { command("button", "LEFT") }
    @objc private func right() { command("button", "RIGHT") }
    @objc private func enter() { command("button", "ENTER") }
    @objc private func home() { command("button", "HOME") }
    @objc private func back() { command("button", "BACK") }

    @objc private func openSettings(_ sender: NSButton) {
        let menu = NSMenu()
        add(menu, "Hide Remote", action: #selector(hideRemote))
        add(menu, "Power On", action: #selector(powerOn))
        add(menu, "Power Off…", action: #selector(powerOff))
        add(menu, "Set Up Power On", action: #selector(setupPowerOn))
        add(menu, "Set Wake MAC Manually…", action: #selector(setWakeMAC))
        add(menu, "Discover TV", action: #selector(discover))
        add(menu, "Wake Screen", action: #selector(wakeScreen))
        add(menu, "Set TV IP…", action: #selector(setHost))
        add(menu, "Pair / Check Connection", action: #selector(pair))
        add(menu, "Check TV Status", action: #selector(checkStatus))
        add(menu, "Refresh App List", action: #selector(refreshAppsAction))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    private func padButton(
        _ title: String, _ action: Selector, _ x: CGFloat, _ y: CGFloat,
        _ width: CGFloat = 54, symbol: String? = nil, iconOnly: Bool = false
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.frame = NSRect(x: x, y: y, width: width, height: 30)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 14, weight: .medium)
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button.image = image
            button.imagePosition = iconOnly ? .imageOnly : .imageLeading
            if iconOnly {
                button.title = ""
                button.setAccessibilityLabel(title)
                button.toolTip = title
            }
        }
        return button
    }

    private func glassGroup(_ frame: NSRect) -> (NSGlassEffectView, NSView) {
        let glass = NSGlassEffectView(frame: frame)
        glass.cornerRadius = 22
        glass.style = .regular
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        glass.tintColor = NSColor.systemBlue.withAlphaComponent(0.08)
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        glass.contentView = content
        return (glass, content)
    }

    @objc private func openRemotePad() {
        if remotePanel == nil {
            let panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 370),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            panel.title = "LG TV Remote"
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.delegate = self
            panel.isReleasedWhenClosed = false
            panel.isOpaque = true
            panel.backgroundColor = .windowBackgroundColor
            panel.titlebarAppearsTransparent = false
            panel.titleVisibility = .visible
            panel.center()
            let view = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 360, height: 370))
            view.material = .popover
            view.blendingMode = .behindWindow
            view.state = .active
            let title = NSTextField(labelWithString: "LG TV Remote")
            title.frame = NSRect(x: 20, y: 335, width: 240, height: 28)
            title.font = .systemFont(ofSize: 19, weight: .semibold)
            title.toolTip = "Drag here to move the remote window"
            view.addSubview(title)
            let dragHandle = WindowDragHandle(frame: NSRect(x: 16, y: 330, width: 244, height: 38))
            dragHandle.toolTip = "Drag to move the remote window"
            view.addSubview(dragHandle)
            view.addSubview(padButton("Power On", #selector(powerOn), 268, 334, 32, symbol: "power", iconOnly: true))
            let settings = padButton("TV Settings", #selector(openSettings(_:)), 308, 334, 32, symbol: "gearshape", iconOnly: true)
            view.addSubview(settings)
            let mode = NSSegmentedControl(labels: ["Buttons", "Trackpad"], trackingMode: .selectOne, target: self, action: #selector(changeControlMode(_:)))
            mode.frame = NSRect(x: 90, y: 295, width: 180, height: 28)
            mode.selectedSegment = 0
            view.addSubview(mode)
            let focusView = RemoteFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            view.addSubview(focusView)
            padFocusView = focusView
            panel.initialFirstResponder = focusView

            let (directionGlass, directionContent) = glassGroup(NSRect(x: 65, y: 139, width: 230, height: 146))
            let upButton = padButton("Up", #selector(up), 88, 107, 54, symbol: "arrow.up", iconOnly: true)
            directionContent.addSubview(upButton)
            directionContent.addSubview(padButton("Left", #selector(left), 20, 58, 54, symbol: "arrow.left", iconOnly: true))
            directionContent.addSubview(padButton("OK", #selector(enter), 88, 58, 54))
            directionContent.addSubview(padButton("Right", #selector(right), 156, 58, 54, symbol: "arrow.right", iconOnly: true))
            directionContent.addSubview(padButton("Down", #selector(down), 88, 9, 54, symbol: "arrow.down", iconOnly: true))
            view.addSubview(directionGlass)
            directionGroup = directionGlass
            let (trackGlass, trackContent) = glassGroup(NSRect(x: 16, y: 139, width: 328, height: 146))
            let trackpad = PointerTrackpad(frame: trackContent.bounds)
            trackpad.setAccessibilityElement(true)
            trackpad.setAccessibilityRole(.group)
            trackpad.setAccessibilityLabel("TV Trackpad: drag to move, click to select")
            trackpad.move = { [weak self] dx, dy in self?.pointer.move(dx, dy) }
            trackpad.click = { [weak self] in self?.pointer.click() }
            trackpad.scroll = { [weak self] dx, dy in self?.pointer.scroll(dx, dy) }
            trackContent.addSubview(trackpad)
            trackGlass.isHidden = true
            trackpadGroup = trackGlass
            view.addSubview(trackGlass)
            pointer.status = { [weak self] message in self?.note(message) }

            let (navGlass, navContent) = glassGroup(NSRect(x: 16, y: 85, width: 328, height: 42))
            navContent.addSubview(padButton("Home", #selector(home), 45, 6, 100, symbol: "house.fill"))
            navContent.addSubview(padButton("Back", #selector(back), 183, 6, 100, symbol: "arrow.uturn.backward"))
            view.addSubview(navGlass)

            let (mediaGlass, mediaContent) = glassGroup(NSRect(x: 16, y: 31, width: 328, height: 42))
            mediaContent.addSubview(padButton("Rewind", #selector(rewind), 11, 6, 60, symbol: "backward.end.fill", iconOnly: true))
            mediaContent.addSubview(padButton("Play", #selector(play), 93, 6, 60, symbol: "play.fill", iconOnly: true))
            mediaContent.addSubview(padButton("Pause", #selector(pause), 175, 6, 60, symbol: "pause.fill", iconOnly: true))
            mediaContent.addSubview(padButton("Fast Forward", #selector(fastForward), 257, 6, 60, symbol: "forward.end.fill", iconOnly: true))
            view.addSubview(mediaGlass)
            let status = NSTextField(labelWithString: "Use arrows to select a TV item")
            status.frame = NSRect(x: 16, y: 5, width: 328, height: 18)
            status.textColor = .secondaryLabelColor
            view.addSubview(status)
            panelStatus = status
            panel.contentView = view
            remotePanel = panel
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.remotePanel?.isKeyWindow == true,
                      !(self.remotePanel?.firstResponder is NSTextView) else { return event }
                let buttons: [UInt16: String] = [123: "LEFT", 124: "RIGHT", 125: "DOWN", 126: "UP", 36: "ENTER", 53: "BACK"]
                guard let button = buttons[event.keyCode] else { return event }
                self.command("button", button)
                return nil
            }
        }
        if remotePanel?.isMiniaturized == true { remotePanel?.deminiaturize(nil) }
        remotePanel?.makeKeyAndOrderFront(nil)
        statusItem.button?.toolTip = "Click TV to hide remote. Right-click for options."
        if trackpadGroup?.isHidden == false { startPointer() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            if let padFocusView = self.padFocusView { self.remotePanel?.makeFirstResponder(padFocusView) }
        }
    }

    @objc private func changeControlMode(_ sender: NSSegmentedControl) {
        let trackpad = sender.selectedSegment == 1
        directionGroup?.isHidden = trackpad
        trackpadGroup?.isHidden = !trackpad
        if trackpad { startPointer() }
        else { pointer.stop(); note("Button control ready") }
    }

    private func startPointer() {
        guard !pointer.isRunning else { return }
        guard !host.isEmpty else { note("Choose Discover TV or Set TV IP first"); return }
        pointer.start(cli: cliPath, host: host)
    }

    @objc private func checkStatus() { command("status", feedbackTitle: "TV Status") }
    @objc private func wakeScreen() { command("wake-screen", feedbackTitle: "Wake Screen") }
    @objc private func powerOn() { command("power-on", feedbackTitle: "Power On") }
    @objc private func setupPowerOn() { command("wake-setup", feedbackTitle: "Power-on Setup") }
    @objc private func setWakeMAC() {
        guard !host.isEmpty else { feedback("Select a TV", message: "Choose Discover TV or Set TV IP first."); return }
        if let mac = prompt("TV Wi-Fi or Ethernet MAC address") {
            command("wake-setup", mac, feedbackTitle: "Power-on Setup")
        }
    }
    @objc private func play() { command("play") }
    @objc private func pause() { command("pause") }
    @objc private func rewind() { command("rewind") }
    @objc private func fastForward() { command("fast-forward") }
    @objc private func channelUp() { command("channel-up") }
    @objc private func channelDown() { command("channel-down") }
    @objc private func powerOff() {
        let alert = NSAlert()
        alert.messageText = "Turn off the TV?"
        alert.addButton(withTitle: "Turn Off")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { command("power-off") }
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

@main
private enum LGTVRemoteApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = RemoteController()
        app.delegate = controller
        app.run()
    }
}
