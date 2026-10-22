import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var panel: NSPanel!
    private var activity: NSObjectProtocol?
    private var eventMonitor: Any?
    private var contextMenu: NSMenu!
    private var viewModel: StatsViewModel?

    private let windowPositionXKey = "windowPositionX"
    private let windowTopKey = "windowTopY"
    private var anchorTop: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
            renderSnapshot(arguments: Array(CommandLine.arguments[(index + 1)...]))
            return
        }

        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Live stats refresh"
        )

        setupPanel()
        setupContextMenu()
        setupSleepWakeObservers()
    }

    private func setupPanel() {
        let viewModel = StatsViewModel()
        self.viewModel = viewModel
        let hostingController = NSHostingController(rootView: ContentView(viewModel: viewModel))
        // Let the panel follow the SwiftUI content size (overview vs. day detail)
        hostingController.sizingOptions = [.preferredContentSize]
        let fittingSize = hostingController.view.fittingSize

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentViewController = hostingController
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isRestorable = false

        if let x = UserDefaults.standard.object(forKey: windowPositionXKey) as? CGFloat,
           let top = UserDefaults.standard.object(forKey: windowTopKey) as? CGFloat {
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
        } else if let screen = NSScreen.main {
            // Top-right corner. The content has no size yet, so place by the widget's known
            // width and its top edge; height changes then grow downward.
            let visible = screen.visibleFrame
            let width = max(panel.frame.width, Layout.width + 24)
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - width - 20, y: visible.maxY - 20))
        }
        anchorTop = panel.frame.maxY
        keepOnScreen()

        panel.orderFront(nil)

        // Content size changes keep the top edge fixed, so the widget grows downward
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            if abs(panel.frame.maxY - self.anchorTop) > 0.5 {
                panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: self.anchorTop))
            }
            self.keepOnScreen()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.anchorTop = self.panel.frame.maxY
            self.saveWindowPosition(self.panel.frame)
        }
    }

    /// Pull the widget fully back onto the screen it overlaps most (or the main screen),
    /// e.g. after it grew past an edge or a display was disconnected.
    private func keepOnScreen() {
        guard let panel else { return }
        let frame = panel.frame
        let screen = NSScreen.screens.max {
            $0.visibleFrame.intersection(frame).width * $0.visibleFrame.intersection(frame).height
                < $1.visibleFrame.intersection(frame).width * $1.visibleFrame.intersection(frame).height
        }
        guard let visible = (screen?.visibleFrame.intersects(frame) == true ? screen : NSScreen.main)?.visibleFrame,
              !visible.contains(frame) else { return }
        let x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        anchorTop = y + frame.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func saveWindowPosition(_ frame: NSRect) {
        UserDefaults.standard.set(frame.minX, forKey: windowPositionXKey)
        UserDefaults.standard.set(frame.maxY, forKey: windowTopKey)
    }

    // MARK: - Snapshot (debug)

    /// `UsageWidget --snapshot out.png [all|30d|7d] [yyyy-MM-dd]` renders the widget to a PNG
    /// and exits. Handy for checking numbers without Screen Recording permission.
    private func renderSnapshot(arguments: [String]) {
        guard let output = arguments.first else { exit(2) }
        let viewModel = StatsViewModel()
        viewModel.loadData()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            guard viewModel.isLoaded else { return }
            timer.invalidate()
            for arg in arguments.dropFirst() {
                if let range = UsageRange.allCases.first(where: { String(localized: $0.title) == arg || $0.rawValue == arg }) {
                    viewModel.range = range
                } else {
                    viewModel.selectedDay = arg
                }
            }
            let renderer = ImageRenderer(content: ContentView(viewModel: viewModel).background(Color(hex: 0x2A2624)))
            renderer.scale = 2
            guard let image = renderer.cgImage else { exit(1) }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
            let s = viewModel.summary
            print("tokens(io)=\(s.tokens.io) all=\(s.tokens.all) in=\(s.tokens.input) out=\(s.tokens.output) cacheRead=\(s.tokens.cacheRead) cacheWrite=\(s.tokens.cacheWrite) activeDays=\(s.activeDays) sessions=\(s.sessions) replies=\(s.replies) userMsgs=\(s.userMessages) models=\(s.models.map(\.model))")
            exit(0)
        }
    }

    // MARK: - Context Menu

    private func setupContextMenu() {
        contextMenu = NSMenu()

        let refreshItem = NSMenuItem(
            title: String(localized: "Refresh"),
            action: #selector(refresh(_:)),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        contextMenu.addItem(refreshItem)

        let launchItem = NSMenuItem(
            title: String(localized: "Launch at Login"),
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        contextMenu.addItem(launchItem)

        contextMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: String(localized: "Quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        contextMenu.addItem(quitItem)

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window == panel {
                NSMenu.popUpContextMenu(self.contextMenu, with: event, for: panel.contentView!)
                return nil
            }
            return event
        }
    }

    @objc private func refresh(_ sender: NSMenuItem) {
        viewModel?.loadData()
        viewModel?.fetchAPIUsage()
    }

    // MARK: - Launch at Login (LaunchAgent plist)

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.emmett.UsageWidget.plist")
    }

    private var isLaunchAgentInstalled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if isLaunchAgentInstalled {
            try? FileManager.default.removeItem(at: launchAgentURL)
        } else {
            let plist: [String: Any] = [
                "Label": "com.emmett.UsageWidget",
                "ProgramArguments": ["/Applications/UsageWidget.app/Contents/MacOS/UsageWidget"],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
            ]
            let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            FileManager.default.createFile(atPath: launchAgentURL.path, contents: data)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleLaunchAtLogin(_:)) {
            menuItem.state = isLaunchAgentInstalled ? .on : .off
        }
        return true
    }

    // MARK: - Sleep/Wake

    private func setupSleepWakeObservers() {
        let ws = NSWorkspace.shared.notificationCenter

        // Pause when display sleeps (lid close, lock screen, display timeout)
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.viewModel?.pause()
        }

        // Resume when display wakes
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.viewModel?.resume()
        }

        // Also pause/resume on full system sleep/wake
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.viewModel?.pause()
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.viewModel?.resume()
        }
    }

}
