import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let progressURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/rclone-nas/local-edit-state/progress.tsv")
    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/rclone-nas/local-edit.log")
    private let primaryWorkURL = URL(fileURLWithPath: "/Volumes/data/PhD", isDirectory: true)
    private let fallbackWorkURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/NAS Local Edit", isDirectory: true)

    private var statusItem: NSStatusItem!
    private let statusMenuItem = NSMenuItem(title: "没有正在传输的文件", action: nil, keyEquivalent: "")
    private let progressMenuItem = NSMenuItem()
    private let progressIndicator = NSProgressIndicator(frame: NSRect(x: 12, y: 3, width: 216, height: 14))
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "NAS")

        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.isIndeterminate = false
        let progressView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 20))
        progressView.addSubview(progressIndicator)
        progressMenuItem.view = progressView
        progressMenuItem.isHidden = true

        let menu = NSMenu()
        menu.addItem(statusMenuItem)
        menu.addItem(progressMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开本地工作区", action: #selector(openWorkDirectory), keyEquivalent: "")
        menu.addItem(withTitle: "打开同步日志", action: #selector(openLog), keyEquivalent: "")
        menu.items.suffix(2).forEach { $0.target = self }
        statusItem.menu = menu

        refresh()
        timer = Timer.scheduledTimer(timeInterval: 0.5, target: self,
                                     selector: #selector(refresh), userInfo: nil, repeats: true)
    }

    @objc private func refresh() {
        guard let contents = try? String(contentsOf: progressURL, encoding: .utf8) else {
            showIdle()
            return
        }

        let fields = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 4,
              let percent = Int(fields[1]),
              let timestamp = TimeInterval(fields[3]) else {
            showIdle()
            return
        }

        let state = String(fields[0])
        let path = String(fields[2])
        switch state {
        case "uploading":
            statusItem.button?.image = NSImage(systemSymbolName: "arrow.up.circle", accessibilityDescription: "正在上传")
            statusMenuItem.title = "正在上传：\(path)（\(percent)%）"
            progressIndicator.doubleValue = Double(percent)
            progressMenuItem.isHidden = false
        case "done" where Date().timeIntervalSince1970 - timestamp <= 8:
            statusItem.button?.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "上传完成")
            statusMenuItem.title = "上传完成：\(path)"
            progressIndicator.doubleValue = 100
            progressMenuItem.isHidden = false
        case "error":
            statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "上传失败")
            statusMenuItem.title = "上传失败，等待重试：\(path)"
            progressMenuItem.isHidden = true
        default:
            showIdle()
        }
    }

    private func showIdle() {
        statusItem.button?.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "NAS")
        statusMenuItem.title = "没有正在传输的文件"
        progressMenuItem.isHidden = true
    }

    @objc private func openWorkDirectory() {
        let target = FileManager.default.isWritableFile(atPath: primaryWorkURL.path)
            ? primaryWorkURL : fallbackWorkURL
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        NSWorkspace.shared.open(target)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(logURL)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
