import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts.
///
/// Carbon hot keys are used on purpose: unlike a global `NSEvent` monitor they
/// need no Accessibility permission, which keeps the permission story to just
/// audio.
@MainActor
final class HotKeyCenter {

    struct Shortcut {
        let keyCode: UInt32
        let modifiers: UInt32
        let action: () -> Void
    }

    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var references: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    private init() {}

    func install(
        toggleSession: @escaping () -> Void,
        toggleOverlay: @escaping () -> Void,
        answerNow: @escaping () -> Void
    ) {
        installEventHandler()
        // ⌥⌘L – Mithören an/aus
        register(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey | cmdKey), action: toggleSession)
        // ⌥⌘O – Overlay ein/aus
        register(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(optionKey | cmdKey), action: toggleOverlay)
        // ⌥⌘A – Jetzt antworten
        register(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | cmdKey), action: answerNow)
    }

    private func installEventHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let identifier = hotKeyID.id
                DispatchQueue.main.async {
                    HotKeyCenter.shared.fire(identifier)
                }
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandler
        )
    }

    fileprivate func fire(_ identifier: UInt32) {
        handlers[identifier]?()
    }

    private func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        let identifier = nextID
        nextID += 1
        handlers[identifier] = action

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534D_544E), id: identifier) // 'SMTN'
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference
        )
        if status == noErr {
            references.append(reference)
        } else {
            handlers.removeValue(forKey: identifier)
        }
    }
}
