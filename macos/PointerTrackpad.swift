import AppKit

final class PointerTrackpad: NSView {
    var move: ((Double, Double) -> Void)?
    var click: (() -> Void)?
    var scroll: ((Double, Double) -> Void)?
    private var previous = NSPoint.zero
    private var distance: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        let text = "Drag to move the TV pointer\nClick to select · Scroll to browse"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (text as NSString).draw(in: NSRect(x: 12, y: bounds.midY - 25, width: bounds.width - 24, height: 50),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13),
                             .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        previous = convert(event.locationInWindow, from: nil)
        distance = 0
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - previous.x
        let dy = previous.y - point.y // TV coordinates increase downwards.
        distance += hypot(dx, dy)
        move?(Double(dx) * 2, Double(dy) * 2)
        previous = point
    }

    override func mouseUp(with event: NSEvent) {
        if distance < 4 { click?() }
    }

    override func scrollWheel(with event: NSEvent) {
        let scale = event.hasPreciseScrollingDeltas ? 0.1 : 1.0
        scroll?(Double(event.scrollingDeltaX) * scale, -Double(event.scrollingDeltaY) * scale)
    }
}

/// One helper process/socket per trackpad session; movement is coalesced at 25 Hz.
final class PointerSession {
    var status: ((String) -> Void)?
    var isRunning: Bool { process?.isRunning == true }
    private var process: Process?
    private var input: FileHandle?
    private var timer: Timer?
    private var ready = false
    private var inFlight = false
    private var waiting: [[String: Any]] = []
    private var generation = UUID()
    private var pendingX = 0.0
    private var pendingY = 0.0
    private let writes = DispatchQueue(label: "local.lgtv.pointer-writes")

    func start(cli: String, host: String) {
        stop()
        let current = generation
        let child = Process()
        child.executableURL = URL(fileURLWithPath: cli)
        child.arguments = ["pointer", host]
        let stdin = Pipe(), stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stdout
        var buffer = Data()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                buffer.append(data)
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer[..<end]
                    buffer.removeSubrange(...end)
                    if let reply = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                        if reply["ready"] as? Bool == true {
                            self.ready = true
                            self.status?("Trackpad connected; drag to move, click to select")
                        } else if reply["sent"] as? Bool == true {
                            self.inFlight = false
                            self.status?("Trackpad ready")
                            if !self.waiting.isEmpty { self.send(self.waiting.removeFirst()) }
                        }
                    } else if let message = String(data: Data(line), encoding: .utf8), !message.isEmpty {
                        self.status?(message)
                    }
                }
            }
        }
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.stop()
                self.status?("Trackpad disconnected; select Buttons, then Trackpad to retry")
            }
        }
        do {
            try child.run()
            process = child
            input = stdin.fileHandleForWriting
            status?("Connecting TV trackpad…")
            let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.flush() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            status?("Could not start trackpad: \(error.localizedDescription)")
        }
    }

    func move(_ dx: Double, _ dy: Double) {
        guard ready else { return }
        pendingX += dx
        pendingY += dy
    }

    func click() { flush(); send(["type": "click"]) }
    func scroll(_ dx: Double, _ dy: Double) { flush(); send(["type": "scroll", "dx": max(-1000, min(1000, dx)), "dy": max(-1000, min(1000, dy))]) }

    private func flush() {
        guard !inFlight && waiting.isEmpty else { return }
        guard pendingX != 0 || pendingY != 0 else { return }
        let dx = max(-1000, min(1000, pendingX)), dy = max(-1000, min(1000, pendingY))
        pendingX = 0
        pendingY = 0
        send(["type": "move", "dx": dx, "dy": dy])
    }

    private func send(_ event: [String: Any]) {
        guard ready, let input, let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        if inFlight {
            if waiting.count < 10 { waiting.append(event) }
            else { status?("Trackpad busy; wait for the TV") }
            return
        }
        inFlight = true
        let current = generation
        writes.async { [weak self] in
            do { try input.write(contentsOf: data + Data([10])) }
            catch {
                DispatchQueue.main.async {
                    guard let self, self.generation == current else { return }
                    self.stop()
                    self.status?("Trackpad disconnected; select Trackpad again to retry")
                }
            }
        }
    }

    func stop() {
        generation = UUID()
        ready = false
        inFlight = false
        waiting.removeAll()
        timer?.invalidate()
        timer = nil
        pendingX = 0
        pendingY = 0
        if let input { writes.async { try? input.close() } }
        input = nil
        if let process {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { process.terminate() }
            }
        }
        process = nil
    }
}
