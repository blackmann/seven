import Carbon
import Foundation

/// Carbon registers each shortcut; no keyboard monitoring permission or
/// broad event tap is necessary. The overlay itself receives scroll events.
@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let identifier: EventHotKeyID
    var onPress: (() -> Void)?
    private(set) var registrationStatus: OSStatus = noErr

    init(keyCode: UInt32 = UInt32(kVK_Tab), modifiers: UInt32 = UInt32(optionKey), id: UInt32 = 1) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.identifier = EventHotKeyID(signature: 0x4D4F4445, id: id) // MODE
    }

    func register() {
        unregister()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            return MainActor.assumeIsolated {
                let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
                guard pressed.signature == shortcut.identifier.signature, pressed.id == shortcut.identifier.id else {
                    return OSStatus(eventNotHandledErr)
                }
                shortcut.onPress?()
                return noErr
            }
        }, 1, &event, context, &handler)
        guard handlerStatus == noErr else {
            registrationStatus = handlerStatus
            return
        }
        registrationStatus = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
        if registrationStatus != noErr { unregister() }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
