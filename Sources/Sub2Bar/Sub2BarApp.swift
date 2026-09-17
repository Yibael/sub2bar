import AppKit
import SwiftUI
import Combine

@main
enum Sub2BarApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = AppStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var observation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Sub2Bar 账号监控")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Sub2Bar · sub2api 账号监控"
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: PanelSizing.width, height: PanelSizing.initialHeight)
        popover.contentViewController = NSHostingController(rootView: panelView())
        observation = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTooltip() }
        }
        store.start()
        if !store.isConfigured {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.togglePopover() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
    }

    private func setupMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Sub2Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"),
                                    ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"),
                                    ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        edit.submenu = editMenu; menu.addItem(edit)
        NSApplication.shared.mainMenu = menu
    }

    @objc private func togglePopover() {
        if NSApplication.shared.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
            settings.target = self; menu.addItem(settings)
            menu.addItem(withTitle: "退出 Sub2Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
            return
        }
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        // Resolve the intrinsic layout before presentation, avoiding the bootstrap height.
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            let height = view.fittingSize.height
            if height.isFinite, height > 0 {
                popover.contentSize = NSSize(width: PanelSizing.width, height: height)
            }
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Start immediately once presented; didShow remains an idempotent backup.
        if popover.isShown { store.setPanelVisible(true) }
        popover.contentViewController?.view.window?.makeKey()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func popoverDidShow(_ notification: Notification) { store.setPanelVisible(popover.isShown) }
    func popoverWillClose(_ notification: Notification) { store.setPanelVisible(false) }
    func popoverDidClose(_ notification: Notification) { store.setPanelVisible(false) }

    @objc private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = WindowFactory.settings()
            window.center()
            settingsWindow = window
        }
        // Recreate the draft so reopening settings always reflects the saved configuration.
        if settingsWindow?.isVisible != true {
            settingsWindow?.contentView = NSHostingView(rootView: SettingsView(store: store))
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func panelView() -> PopoverView {
        PopoverView(store: store, openSettings: { [weak self] in self?.showSettings() },
                    onHeightChange: { [weak self] height in
            // Update AppKit only for real geometry changes, never on every poll.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Earlier queued measurements may be stale by the time AppKit applies them.
                let currentHeight = self.popover.contentViewController?.view.fittingSize.height ?? height
                guard currentHeight.isFinite, currentHeight > 0,
                      abs(self.popover.contentSize.height - currentHeight) >= 1 else { return }
                self.popover.contentSize = NSSize(width: PanelSizing.width, height: currentHeight)
            }
        })
    }

    @objc private func wokeUp() { store.resumeAfterSleep() }
    @objc private func willSleep() { store.suspendForSleep() }
    private func updateTooltip() {
        let state = store.errorMessage != nil ? "连接异常" : "\(store.activeCount) 个可调度账号"
        statusItem.button?.toolTip = "Sub2Bar · \(state)"
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
