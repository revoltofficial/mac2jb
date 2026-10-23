import Cocoa
import Darwin

func approvalPromptCount(_ text: String) -> Int {
    let lower = text.lowercased()
    return ["press enter to continue", "press enter to begin"].reduce(0) {
        $0 + lower.components(separatedBy: $1).count - 1
    }
}

final class App: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let log = NSTextView()
    let status = NSTextField(labelWithString: "Ready. Start the host before sending session commands.")
    let address = NSTextField(string: "")
    let next = NSButton(title: "Continue selected sender step", target: nil, action: nil)
    var host: Process?, sender: Process?
    var input: Pipe?
    var senderText = ""
    var approved = 0
    var root: URL!
    var hostButton: NSButton!
    var guidedTimer: Timer?
    var sessionCommandsStarted = false
    func applicationDidFinishLaunching(_ note: Notification) {
        do { try prepare() } catch { alert("Cannot prepare app", error.localizedDescription); NSApp.terminate(nil); return }
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 820,height: 620), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "mac2jb"
        window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor,constant: 20),stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor,constant: -20),stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor,constant: 20),stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor,constant: -20)])
        let title = NSTextField(labelWithString: "mac2jb · USB keyboard & local host")
        title.font = .boldSystemFont(ofSize: 23); stack.addArrangedSubview(title)
        let hint = NSTextField(wrappingLabelWithString: "Connect the Mac and console to the same local network. USB sending requires an already loaded usbgadget driver. No security settings are changed.")
        stack.addArrangedSubview(hint)
        address.placeholderString = "Mac IPv4 address reachable by the console"
        address.stringValue = localIP()
        address.widthAnchor.constraint(greaterThanOrEqualToConstant: 310).isActive = true
        let row = NSStackView(); row.spacing = 10
        row.addArrangedSubview(NSTextField(labelWithString: "Mac IP:")); row.addArrangedSubview(address)
        hostButton = button("Start host", #selector(startHost)); row.addArrangedSubview(hostButton)
        row.addArrangedSubview(button("Stop all", #selector(stopAll))); stack.addArrangedSubview(row)
        let actions = NSStackView(); actions.spacing = 10
        actions.addArrangedSubview(button("Preview bootstrap", #selector(preview)))
        actions.addArrangedSubview(button("Send bootstrap", #selector(bootstrap)))
        actions.addArrangedSubview(button("Send session commands", #selector(commands)))
        stack.addArrangedSubview(actions)
        let guided = button("Start guided session (host + commands)", #selector(guidedSession))
        guided.bezelStyle = .rounded
        stack.addArrangedSubview(guided)
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "After transferring: save the bootstrap if possible, load it in fresh SmileBASIC, then start a guided session. Check the console before every Continue. Do not repeat REMOVE in the same SmileBASIC session."))
        next.target = self; next.action = #selector(continueStep); next.isEnabled = false; stack.addArrangedSubview(next)
        status.maximumNumberOfLines = 2; stack.addArrangedSubview(status)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        log.isEditable = false; log.isSelectable = true; log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        log.isVerticallyResizable = true; log.autoresizingMask = [.width]; log.textContainer?.widthTracksTextView = true
        scroll.documentView = log; stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        stack.addArrangedSubview(button("Open session files", #selector(openFiles)))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item); let appMenu = NSMenu(); item.submenu = appMenu
        appMenu.addItem(withTitle: "Quit mac2jb",action: #selector(NSApplication.terminate(_:)),keyEquivalent: "q"); NSApp.mainMenu = menu
        append("Bundled runtime ready. Session files: \(root.path)\nStart the host, then load or transfer the bootstrap.\nObserve the console before approving each session command.\n")
    }
    func prepare() throws {
        let payload = Bundle.main.resourceURL!.appendingPathComponent("payload")
        let base = FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0].appendingPathComponent("mac2jb")
        try FileManager.default.createDirectory(at: base,withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700])
        // Fresh workspace prevents reuse of a stale pairing token and allows concurrent app sessions.
        root = base.appendingPathComponent("session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700])
        for item in try FileManager.default.contentsOfDirectory(at: payload,includingPropertiesForKeys: nil) where item.lastPathComponent != "runtime" {
            try FileManager.default.copyItem(at: item,to: root.appendingPathComponent(item.lastPathComponent))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700],ofItemAtPath: root.path)
    }
    func localIP() -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return "" }; defer { freeifaddrs(head) }
        var p = head; var fallback = ""
        while let current = p {
            defer { p = current.pointee.ifa_next }
            guard let a = current.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else { continue }
            var out = [CChar](repeating: 0,count: Int(NI_MAXHOST))
            guard getnameinfo(a,socklen_t(a.pointee.sa_len),&out,socklen_t(out.count),nil,0,NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: out); if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") { continue }
            if String(cString: current.pointee.ifa_name) == "en0" { return ip }; fallback = ip
        }; return fallback
    }
    func button(_ title: String,_ action: Selector) -> NSButton { NSButton(title: title,target: self,action: action) }
    func append(_ text: String) {
        log.textStorage?.append(NSAttributedString(string: text,attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11,weight: .regular)]))
        log.scrollToEndOfDocument(nil)
    }
    func alert(_ title: String,_ text: String) { let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal() }
    func confirm(_ title: String) -> Bool {
        let a = NSAlert(); a.messageText = title; a.informativeText = "This sends keyboard input to the connected console. Check its focused editor and keep the cable connected."
        a.addButton(withTitle: "Send"); a.addButton(withTitle: "Cancel"); return a.runModal() == .alertFirstButtonReturn
    }
    func driverReady() -> Bool {
        let p = Process(); let pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/usr/bin/kmutil"); p.arguments = ["showloaded"]; p.standardOutput = pipe; p.standardError = pipe
        do { try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            if p.terminationStatus == 0 && String(decoding: data,as: UTF8.self).contains("gay.bowser.usbgadget") { return true }
        } catch { }
        alert("USB driver unavailable", "usbgadget.kext must already be loaded. This app does not install the driver or change security settings. Host and preview remain available."); return false
    }
    func launch(_ executable: String,_ args: [String],isHost: Bool) {
        let p = Process(); let out = Pipe(); let stdin = Pipe()
        p.executableURL = executable.hasPrefix("runtime/") ? Bundle.main.resourceURL!.appendingPathComponent("payload").appendingPathComponent(executable) : root.appendingPathComponent(executable); p.arguments = args; p.currentDirectoryURL = root
        p.standardOutput = out; p.standardError = out; p.standardInput = stdin
        var env = ProcessInfo.processInfo.environment; env["PATH"] = Bundle.main.resourceURL!.appendingPathComponent("payload/runtime/bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"; p.environment = env
        if !isHost { senderText = ""; approved = 0; next.isEnabled = false }
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let d = handle.availableData; if d.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: d,as: UTF8.self)
            DispatchQueue.main.async { guard let self = self else { return }; self.append((isHost ? "[host] " : "") + text)
                if !isHost { self.senderText += text; self.refreshPrompt() }
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { guard let self = self else { return }
                self.append("\n\(isHost ? "Host" : "Sender") exited (\(proc.terminationStatus)).\n")
                if isHost { self.guidedTimer?.invalidate(); self.guidedTimer = nil; self.host = nil; self.hostButton.isEnabled = true }
                else { self.sender = nil; self.input = nil; self.next.isEnabled = false }
                self.status.stringValue = proc.terminationStatus == 0 ? "Finished. Check the console for the result." : "Stopped. See the log for details."
            }
        }
        do { try p.run(); if isHost { host = p; hostButton.isEnabled = false; status.stringValue = "Host running. Wait for its session command in the log." } else { sender = p; input = stdin; status.stringValue = "Sender running. Observe the console; approve prompts below." } }
        catch { out.fileHandleForReading.readabilityHandler = nil; alert("Could not start",error.localizedDescription) }
    }
    func refreshPrompt() {
        let count = approvalPromptCount(senderText)
        next.isEnabled = count > approved
        if next.isEnabled { status.stringValue = "Action required: read the latest sender prompt, check the console, then click Continue." }
    }
    @objc func continueStep() { guard next.isEnabled, let h = input?.fileHandleForWriting else { return }; approved += 1; next.isEnabled = false; do { try h.write(contentsOf: Data("\n".utf8)) } catch { alert("Sender input failed",error.localizedDescription) } }
    @objc func startHost() {
        guard host == nil else { return }
        let ip = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); var a = in_addr()
        guard inet_pton(AF_INET,ip,&a) == 1 else { alert("Enter your Mac's local IPv4 address", "Use the address on the same network as the console."); return }
        sessionCommandsStarted = false
        launch("runtime/bin/node",["scripts/host-wrapper.cjs",ip],isHost: true)
    }
    func idle() -> Bool { if sender != nil || guidedTimer != nil { alert("Session is busy", "Finish or stop the current operation first."); return false }; return true }
    @objc func preview() { if idle() { launch("mac2jb-send",["assets/bootstrap.bas","--dry-run"],isHost: false) } }
    @objc func bootstrap() { if idle() && driverReady() && confirm("Send bootstrap to the empty SmileBASIC editor?") { launch("mac2jb-send",["assets/bootstrap.bas","--delay-ms","50"],isHost: false) } }
    @objc func commands() {
        guard idle() else { return }
        guard host?.isRunning == true, FileManager.default.fileExists(atPath: root.appendingPathComponent("vendor/ns2jb/runs/mac2jb-active-connect.txt").path) else { alert("Start the host first", "Wait for the current session command. Load the saved bootstrap in a freshly opened SmileBASIC before sending commands."); return }
        guard !sessionCommandsStarted else { alert("Session commands already started", "Do not repeat REMOVE in this SmileBASIC session. Stop all, reopen SmileBASIC, reload the saved bootstrap, and start a new host session before retrying."); return }
        if driverReady() && confirm("Start the guided session commands?") { beginCommands() }
    }
    func beginCommands() {
        sessionCommandsStarted = true
        launch("mac2jb-commands",["--delay-ms","50"],isHost: false)
    }
    @objc func guidedSession() {
        guard idle() else { return }
        guard !sessionCommandsStarted else { alert("Start a fresh session first", "Stop all, reopen SmileBASIC, and reload the saved bootstrap. Never repeat REMOVE in the same SmileBASIC session."); return }
        guard driverReady() else { return }
        let a = NSAlert()
        a.messageText = "Start the host and guided session?"
        a.informativeText = "The Mac and Switch must share a local network. Open fresh SmileBASIC, load the saved bootstrap, and focus command entry. The app will use a fresh host command and pause before each console step."
        a.addButton(withTitle: "Start guided session"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if host == nil { startHost() }
        guard host?.isRunning == true else { return }
        status.stringValue = "Preparing session: waiting for the host's fresh connection command…"
        append("\nGuided session: preparing host, then RUN → REMOVE → current V=START. Check each console result before Continue.\n")
        let deadline = Date().addingTimeInterval(20)
        guidedTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            guard self.host?.isRunning == true else { timer.invalidate(); self.guidedTimer = nil; self.status.stringValue = "Host stopped. See the log before retrying."; return }
            let active = self.root.appendingPathComponent("vendor/ns2jb/runs/mac2jb-active-connect.txt")
            if FileManager.default.fileExists(atPath: active.path) {
                timer.invalidate(); self.guidedTimer = nil
                self.beginCommands()
            } else if Date() >= deadline {
                timer.invalidate(); self.guidedTimer = nil
                self.status.stringValue = "Host readiness timed out. Check the IP address and host log."
            }
        }
    }
    @objc func stopAll() { guidedTimer?.invalidate(); guidedTimer = nil; sender?.terminate(); host?.terminate(); next.isEnabled = false; status.stringValue = "Stopping. If a key remains pressed, disconnect the USB cable." }
    @objc func openFiles() { NSWorkspace.shared.open(root) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) { stopAll() }
}
if CommandLine.arguments.contains("--self-test") {
    let r = Bundle.main.resourceURL!.appendingPathComponent("payload")
    for path in ["mac2jb-send","mac2jb-commands","runtime/bin/node","vendor/ns2jb/run.cjs","scripts/host-wrapper.cjs","vendor/libusbd/libusbd.dylib","assets/bootstrap.bas"] {
        guard FileManager.default.fileExists(atPath: r.appendingPathComponent(path).path) else { fputs("Missing \(path)\n",stderr); exit(1) }
    }
    precondition(approvalPromptCount("Focus the editor, then press Enter to begin (type anything to cancel): ") == 1)
    precondition(approvalPromptCount("Press Enter to cont") == 0)
    precondition(approvalPromptCount("Press Enter to continue: ") == 1)
    precondition(approvalPromptCount("press Enter to begin: \nPress Enter to continue: ") == 2)
    precondition(approvalPromptCount("Waiting for USB host enumeration...") == 0)
    print("App payload and sender prompt regression checks verified"); exit(0)
}
let app = NSApplication.shared
let delegate = App(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
