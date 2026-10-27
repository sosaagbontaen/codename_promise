import AppKit
import Carbon.HIToolbox
import Quartz
import ServiceManagement
import SwiftUI

/// A menu-bar app with one window: the capture panel.
///
/// It lives in the menu bar rather than the Dock because it is for the thirty seconds after
/// remembering something, not for sitting in. ⌃⌥D from anywhere opens it.
@main
@MainActor
enum DumpNotesCaptureApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: CapturePanel!
    private let model = CaptureModel()
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.prepareInbox()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "DumpNotes")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        panel = CapturePanel(model: model) { [weak self] in self?.hidePanel() }
        panel.delegate = self
        model.onFinished = { [weak self] in self?.hidePanel() }
        model.onPreview = { [weak self] in
            guard let self, let ql = QLPreviewPanel.shared() else { return }
            if ql.isVisible { ql.reloadData() } else { ql.makeKeyAndOrderFront(nil) }
            ql.currentPreviewItemIndex = self.model.previewIndex
        }

        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.togglePanel()
        }

        // First launch: show the panel so it's obvious the app is running and where it lives.
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            showPanel()
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Capture", action: #selector(menuShowPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Inbox Folder", action: #selector(revealInbox), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit DumpNotes Capture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detached again, or left-clicks would open the menu from now on.
        statusItem.menu = nil
    }

    @objc private func menuShowPanel() { showPanel() }

    @objc private func revealInbox() {
        NSWorkspace.shared.activateFileViewerSelecting([model.inbox])
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn\u{2019}t change that"
            alert.informativeText = "Move DumpNotes Capture into Applications and try again. You can also add it in System Settings, General, Login Items."
            alert.runModal()
        }
    }

    private func togglePanel() {
        panel.isVisible && NSApp.isActive ? hidePanel() : showPanel()
    }

    private func showPanel() {
        model.refresh()
        panel.placeOnActiveScreen()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        model.requestFocus()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        // Hand focus back to whatever the person was doing.
        NSApp.hide(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Left open when it loses focus, on purpose: dragging a photo in from Finder means
        // clicking Finder first. Esc or the hotkey closes it.
    }
}

/// A floating panel that takes keyboard input. Esc closes it; the draft stays for next time.
///
/// Also what Quick Look asks for the files to show: clicking a thumbnail opens them full size,
/// and the arrow keys page through everything attached.
final class CapturePanel: NSPanel, @preconcurrency QLPreviewPanelDataSource {
    private let onClose: () -> Void
    private let model: CaptureModel

    init(model: CaptureModel, onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "DumpNotes"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 420, height: 380)
        contentView = NSHostingView(rootView: CaptureView(model: model))
    }

    override var canBecomeKey: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        // Above this panel, which itself floats.
        panel.level = .modalPanel
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        model.previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        model.previewItems[index].url as NSURL
    }

    override func cancelOperation(_ sender: Any?) { onClose() }

    override func performClose(_ sender: Any?) { onClose() }

    /// Centred a little above the middle of whichever screen the pointer is on, the way
    /// Spotlight sits.
    func placeOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return center() }
        let size = frame.size
        setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.12
        ))
    }
}

/// A system-wide keyboard shortcut, through Carbon because that is still the only API for one
/// that needs no accessibility permission.
@MainActor
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static var action: (() -> Void)?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x444E4350), id: 1)  // "DNCP"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}
