import Carbon.HIToolbox
import JellyCore

public final class CarbonHotkeyService {
    private enum Action: UInt32, CaseIterable {
        case primary = 1
        case answerScrollUp = 2
        case answerScrollDown = 3
        case answerHistoryPrevious = 4
        case answerHistoryNext = 5
    }

    private static let signature = OSType(0x4A454C59)

    private var hotKeys: [Action: EventHotKeyRef] = [:]
    private var callbacks: [Action: () -> Void] = [:]
    private var handler: EventHandlerRef?

    public init() {}

    public func register(
        shortcut: GlobalShortcut = .controlOptionSpace,
        callback: @escaping () -> Void
    ) throws {
        let components = components(for: shortcut)
        try register(
            action: .primary,
            keyCode: components.keyCode,
            modifiers: components.modifiers,
            callback: callback
        )
    }

    public func registerAnswerScrolling(
        shortcut: AnswerScrollShortcut,
        onUp: @escaping () -> Void,
        onDown: @escaping () -> Void
    ) throws {
        unregister(.answerScrollUp)
        unregister(.answerScrollDown)
        let modifiers = modifiers(shortcut)
        do {
            try register(
                action: .answerScrollUp,
                keyCode: UInt32(kVK_UpArrow),
                modifiers: modifiers,
                callback: onUp
            )
            try register(
                action: .answerScrollDown,
                keyCode: UInt32(kVK_DownArrow),
                modifiers: modifiers,
                callback: onDown
            )
        } catch {
            unregister(.answerScrollUp)
            unregister(.answerScrollDown)
            throw PetFailure.answerScrollShortcutUnavailable
        }
    }

    public func unregisterAnswerScrolling() {
        unregister(.answerScrollUp)
        unregister(.answerScrollDown)
    }

    public func registerAnswerHistoryNavigation(
        shortcut: AnswerHistoryShortcut,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void
    ) throws {
        unregister(.answerHistoryPrevious)
        unregister(.answerHistoryNext)
        let modifiers = modifiers(shortcut)
        do {
            try register(
                action: .answerHistoryPrevious,
                keyCode: UInt32(kVK_LeftArrow),
                modifiers: modifiers,
                callback: onPrevious
            )
            try register(
                action: .answerHistoryNext,
                keyCode: UInt32(kVK_RightArrow),
                modifiers: modifiers,
                callback: onNext
            )
        } catch {
            unregister(.answerHistoryPrevious)
            unregister(.answerHistoryNext)
            throw PetFailure.answerHistoryShortcutUnavailable
        }
    }

    public func unregisterAnswerHistoryNavigation() {
        unregister(.answerHistoryPrevious)
        unregister(.answerHistoryNext)
    }

    public func unregister() {
        for action in Action.allCases {
            unregister(action)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
        handler = nil
    }

    private func register(
        action: Action,
        keyCode: UInt32,
        modifiers: UInt32,
        callback: @escaping () -> Void
    ) throws {
        unregister(action)
        try installHandlerIfNeeded()
        let identifier = EventHotKeyID(
            signature: Self.signature,
            id: action.rawValue
        )
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard status == noErr, let hotKey else {
            throw PetFailure.shortcutUnavailable
        }
        hotKeys[action] = hotKey
        callbacks[action] = callback
    }

    private func installHandlerIfNeeded() throws {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let service = Unmanaged<CarbonHotkeyService>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                var identifier = EventHotKeyID(signature: 0, id: 0)
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr,
                      identifier.signature == CarbonHotkeyService.signature,
                      let action = Action(rawValue: identifier.id),
                      let callback = service.callbacks[action]
                else {
                    return OSStatus(eventNotHandledErr)
                }
                callback()
                return noErr
            },
            1,
            &eventType,
            userData,
            &handler
        )
        guard status == noErr else {
            handler = nil
            throw PetFailure.shortcutUnavailable
        }
    }

    private func unregister(_ action: Action) {
        if let hotKey = hotKeys.removeValue(forKey: action) {
            UnregisterEventHotKey(hotKey)
        }
        callbacks[action] = nil
    }

    private func components(
        for shortcut: GlobalShortcut
    ) -> (keyCode: UInt32, modifiers: UInt32) {
        switch shortcut {
        case .controlOptionJ:
            (UInt32(kVK_ANSI_J), UInt32(controlKey | optionKey))
        case .controlOptionSpace:
            (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .controlShiftSpace:
            (UInt32(kVK_Space), UInt32(controlKey | shiftKey))
        case .commandShiftSpace:
            (UInt32(kVK_Space), UInt32(cmdKey | shiftKey))
        }
    }

    private func modifiers(_ shortcut: AnswerScrollShortcut) -> UInt32 {
        switch shortcut {
        case .controlOptionArrows: UInt32(controlKey | optionKey)
        case .controlShiftArrows: UInt32(controlKey | shiftKey)
        case .commandOptionArrows: UInt32(cmdKey | optionKey)
        case .commandShiftArrows: UInt32(cmdKey | shiftKey)
        }
    }

    private func modifiers(_ shortcut: AnswerHistoryShortcut) -> UInt32 {
        switch shortcut {
        case .controlOptionArrows: UInt32(controlKey | optionKey)
        case .controlShiftArrows: UInt32(controlKey | shiftKey)
        case .commandOptionArrows: UInt32(cmdKey | optionKey)
        case .commandShiftArrows: UInt32(cmdKey | shiftKey)
        }
    }

    deinit {
        unregister()
    }
}
