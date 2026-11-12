import AppKit
import Carbon.HIToolbox

/// Global ⌥⌘U to open the menu-bar popover. Uses Carbon's RegisterEventHotKey, which needs no
/// Accessibility permission (it only receives this one key combination, not all keystrokes).
@MainActor final class GlobalHotkey {
    static let shared = GlobalHotkey()
    static let display = "⌥⌘U"
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func setEnabled(_ on: Bool) {
        if on { register() } else { unregister() }
    }

    private func register() {
        guard ref == nil else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in GlobalHotkey.togglePopover() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x43555342) /* "CUSB" */, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_U), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
        DebugLog.shared.add(status == noErr ? "Global shortcut \(Self.display) on" : "Couldn't register \(Self.display) (another app may use it)")
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    /// MenuBarExtra has no API to open its window, so click its status-bar button. If that button
    /// can't be found (macOS internals changed), show Settings instead so the shortcut still does something.
    static func togglePopover() {
        for w in NSApp.windows where String(describing: type(of: w)).contains("NSStatusBarWindow") {
            if let button = findButton(in: w.contentView) {
                NSApp.activate(ignoringOtherApps: true)
                button.performClick(nil)
                return
            }
        }
        if let m = AppDelegate.model { WindowManager.shared.showSettings(model: m) }
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let b = view as? NSStatusBarButton { return b }
        for v in view.subviews { if let b = findButton(in: v) { return b } }
        return nil
    }
}
