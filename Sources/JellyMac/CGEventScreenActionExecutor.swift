import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import JellyCore

@MainActor
public final class CGEventScreenActionExecutor: ScreenActionExecuting {
    private let semanticProvider: BrowserAccessibilityContextProvider
    private let source = CGEventSource(stateID: .privateState)
    private let mouseLock = NSLock()
    private var activeMouseUpPoint: CGPoint?

    public init(semanticProvider: BrowserAccessibilityContextProvider) {
        self.semanticProvider = semanticProvider
    }

    public func execute(
        _ action: ScreenAction,
        snapshot: SemanticSnapshot?,
        displayID: UInt32
    ) async throws {
        try action.validate()
        let bounds = try onlineBounds(displayID)
        switch action {
        case let .click(target):
            if try performSemanticActivation(target, snapshot: snapshot) { return }
            try click(at: coordinate(target, snapshot, in: bounds), count: 1)
        case let .doubleClick(target):
            // AXPress is a semantic activation, not one half of a double click. Repeating it
            // can submit a button twice, so preserve true double-click pointer semantics here.
            try click(at: coordinate(target, snapshot, in: bounds), count: 2)
        case let .drag(fromX, fromY, toX, toY, duration):
            try await drag(
                from: coordinate(fromX, fromY, in: bounds),
                to: coordinate(toX, toY, in: bounds),
                duration: duration
            )
        case let .typeText(target, text, replaces):
            let observedText = semanticValue(for: target, snapshot: snapshot)
            let point = try coordinate(target, snapshot, in: bounds)
            try click(at: point, count: 1); try await pause(120)
            try click(at: point, count: 1); try await pause(120)
            try await insert(
                text,
                replacing: replaces,
                currentText: observedText ?? focusedTextValue()
            )
        case let .keyPress(key, modifiers):
            try keyPress(key, modifiers)
        case let .navigate(url):
            let bundleID = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            }
            let key: ScreenKey = BrowserSemanticPolicy.navigationEntry(
                frontmostBundleID: bundleID
            ) == .addressBar ? .l : .space
            try keyPress(key, [.command]); try await pause(400)
            try await type(url); try keyPress(.return, [])
        case let .scroll(target, deltaX, deltaY):
            let point = try target.map {
                try coordinate($0, snapshot, in: bounds)
            } ?? CGPoint(x: bounds.midX, y: bounds.midY)
            try move(to: point)
            try await scroll(x: deltaX, y: deltaY)
        case let .wait(milliseconds):
            try await pause(milliseconds)
        }
    }

    public func cancel() { releaseMouseIfNeeded() }

    private func nativeElement(
        _ target: ScreenActionTarget,
        snapshot: SemanticSnapshot?
    ) throws -> AXUIElement? {
        guard case let .element(elementID) = target else { return nil }
        guard snapshot?.elements.contains(where: {
            $0.id == elementID && $0.isEnabled
        }) == true else {
            throw PetFailure.semanticTargetUnavailable
        }
        let element = semanticProvider.nativeElement(for: elementID)
        // Native IDs carry their observation generation. Never turn an expired native
        // handle back into a coordinate click from an old snapshot.
        if element == nil, elementID.hasPrefix("ax-") {
            throw PetFailure.semanticTargetUnavailable
        }
        return element
    }

    private func performSemanticActivation(
        _ target: ScreenActionTarget,
        snapshot: SemanticSnapshot?
    ) throws -> Bool {
        guard let element = try nativeElement(target, snapshot: snapshot) else { return false }
        guard let actions = axActions(element) else { return false }
        for action in [kAXPressAction, kAXConfirmAction] where actions.contains(action as String) {
            if AXUIElementPerformAction(element, action as CFString) == .success { return true }
        }
        return false
    }

    private func axActions(_ element: AXUIElement) -> [String]? {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return nil }
        return names as? [String]
    }

    private func coordinate(
        _ target: ScreenActionTarget,
        _ snapshot: SemanticSnapshot?,
        in bounds: CGRect
    ) throws -> CGPoint {
        switch target {
        case let .visual(x, y):
            return try coordinate(x, y, in: bounds)
        case let .element(elementID):
            guard let element = snapshot?.elements.first(where: {
                $0.id == elementID
            }), element.isEnabled, element.frame.isValid else {
                throw PetFailure.semanticTargetUnavailable
            }
            return try coordinate(
                element.frame.centerX,
                element.frame.centerY,
                in: bounds
            )
        case .locator:
            // Stable locators are resolved by TakeoverCoordinator against the current
            // observation before reaching a platform executor.
            throw PetFailure.semanticTargetUnavailable
        }
    }

    private func semanticValue(
        for target: ScreenActionTarget,
        snapshot: SemanticSnapshot?
    ) -> String? {
        guard case let .element(elementID) = target else { return nil }
        return snapshot?.elements.first(where: { $0.id == elementID })?.value
    }

    private func focusedTextValue() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var rawValue: CFTypeRef?, subroleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            &rawValue
        ) == .success,
              let value = rawValue as? String else { return nil }
        _ = AXUIElementCopyAttributeValue(
            focused,
            kAXSubroleAttribute as CFString,
            &subroleValue
        )
        return BrowserSemanticPolicy.safeValue(
            role: .textField,
            subrole: subroleValue as? String,
            value: value
        )
    }

    private func onlineBounds(_ displayID: UInt32) throws -> CGRect {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            throw PetFailure.selectedDisplayUnavailable
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success,
              ids.prefix(Int(count)).contains(displayID) else {
            throw PetFailure.selectedDisplayUnavailable
        }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else {
            throw PetFailure.selectedDisplayUnavailable
        }
        return bounds
    }

    private func coordinate(_ x: Int, _ y: Int, in bounds: CGRect) throws -> CGPoint {
        guard (0...1_000).contains(x), (0...1_000).contains(y) else {
            throw PetFailure.invalidScreenAction
        }
        return CGPoint(
            x: bounds.minX + CGFloat(x) / 1_000 * bounds.width,
            y: bounds.minY + CGFloat(y) / 1_000 * bounds.height
        )
    }

    private func click(at point: CGPoint, count: Int) throws {
        try move(to: point)
        for index in 1...count {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = try mouseEvent(type, point)
                event.setIntegerValueField(.mouseEventClickState, value: Int64(index))
                post(event); usleep(35_000)
            }
            if index < count { usleep(80_000) }
        }
    }

    private func drag(from start: CGPoint, to end: CGPoint, duration: Int) async throws {
        try move(to: start)
        post(try mouseEvent(.leftMouseDown, start))
        setMouseUp(start)
        defer { releaseMouseIfNeeded() }
        let steps = max(12, min(60, duration / 16))
        for index in 1...steps {
            try Task.checkCancellation()
            let progress = CGFloat(index) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            setMouseUp(point)
            post(try mouseEvent(.leftMouseDragged, point))
            try await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000 / UInt64(steps))
        }
    }

    private func type(_ text: String) async throws {
        let strokes = HumanTypingPlan.strokes(
            for: text,
            seed: UInt64.random(in: 1...UInt64.max)
        )
        for (index, stroke) in strokes.enumerated() {
            try Task.checkCancellation()
            if let mistake = stroke.mistypedText {
                try emit(mistake)
                try await pause(stroke.mistakeDelayMilliseconds)
                try keyPress(.delete, [])
                try await pause(stroke.correctionDelayMilliseconds)
            }
            if stroke.text == "\n" {
                try keyPress(.return, [])
                try await pause(stroke.delayAfterMilliseconds)
                try keyPress(.left, [.command, .shift])
                try await pause(25)
                let next = strokes.indices.contains(index + 1)
                    ? strokes[index + 1].text
                    : nil
                if next == nil || next == "\n" {
                    try emit(" ")
                    try keyPress(.delete, [])
                }
            } else {
                try emit(stroke.text)
                try await pause(stroke.delayAfterMilliseconds)
            }
        }
    }

    private func insert(
        _ text: String,
        replacing: Bool,
        currentText: String?
    ) async throws {
        switch HumanTextEditPlan.make(
            currentText: currentText,
            desiredText: text,
            replacesExistingText: replacing
        ) {
        case .currentTextUnavailable:
            throw PetFailure.editorTextUnavailable
        case .existingTextProtected:
            throw PetFailure.existingEditorTextProtected
        case .unchanged:
            return
        case let .append(value):
            try await type(value)
        case let .insertAtBoundary(prefix, suffix, value):
            try await moveToTextBoundary(
                prefixCount: prefix,
                suffixCount: suffix
            )
            if !value.isEmpty { try await type(value) }
        }
    }

    private func moveToTextBoundary(
        prefixCount: Int,
        suffixCount: Int
    ) async throws {
        if prefixCount <= suffixCount {
            try keyPress(.up, [.command]); try await pause(70)
            try await repeatKey(.right, count: prefixCount)
        } else {
            try keyPress(.down, [.command]); try await pause(70)
            try await repeatKey(.left, count: suffixCount)
        }
        try await pause(90)
    }

    private func repeatKey(
        _ key: ScreenKey,
        modifiers: [KeyModifier] = [],
        count: Int
    ) async throws {
        guard count > 0 else { return }
        for index in 0..<count {
            try Task.checkCancellation()
            try keyPress(key, modifiers)
            if index % 20 == 19 { try await pause(18) }
        }
    }

    private func emit(_ text: String) throws {
        let events = try [keyboardEvent(0, true), keyboardEvent(0, false)]
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            guard let address = buffer.baseAddress else { return }
            events.forEach {
                $0.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: address
                )
            }
        }
        events.forEach(post)
    }

    private func keyPress(_ key: ScreenKey, _ modifiers: [KeyModifier]) throws {
        let code = Self.keyCodes[key]!
        let events = try [keyboardEvent(code, true), keyboardEvent(code, false)]
        let flags = modifiers.reduce(into: CGEventFlags()) {
            $0.insert(Self.modifierFlags[$1]!)
        }
        events.forEach { $0.flags = flags; post($0) }
    }

    private static let keyCodes: [ScreenKey: CGKeyCode] = [
        .a: CGKeyCode(kVK_ANSI_A), .l: CGKeyCode(kVK_ANSI_L),
        .r: CGKeyCode(kVK_ANSI_R), .t: CGKeyCode(kVK_ANSI_T),
        .v: CGKeyCode(kVK_ANSI_V), .w: CGKeyCode(kVK_ANSI_W),
        .return: CGKeyCode(kVK_Return), .tab: CGKeyCode(kVK_Tab),
        .escape: CGKeyCode(kVK_Escape), .delete: CGKeyCode(kVK_Delete),
        .forwardDelete: CGKeyCode(kVK_ForwardDelete), .left: CGKeyCode(kVK_LeftArrow),
        .right: CGKeyCode(kVK_RightArrow), .up: CGKeyCode(kVK_UpArrow),
        .down: CGKeyCode(kVK_DownArrow), .space: CGKeyCode(kVK_Space),
        .home: CGKeyCode(kVK_Home), .end: CGKeyCode(kVK_End),
        .pageUp: CGKeyCode(kVK_PageUp), .pageDown: CGKeyCode(kVK_PageDown)
    ]
    private static let modifierFlags: [KeyModifier: CGEventFlags] = [
        .command: .maskCommand, .control: .maskControl,
        .option: .maskAlternate, .shift: .maskShift
    ]

    private func scroll(x: Int, y: Int) async throws {
        let x = min(420, max(-420, x)), y = min(420, max(-420, y))
        let steps = max(3, min(6, Int(ceil(Double(max(abs(x), abs(y))) / 70))))
        var posted = (x: 0, y: 0)
        for step in 1...steps {
            try Task.checkCancellation()
            let current = (
                x: Int((Double(x) * Double(step) / Double(steps)).rounded()),
                y: Int((Double(y) * Double(step) / Double(steps)).rounded())
            )
            guard let event = CGEvent(
                scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: Int32(clamping: current.y - posted.y),
                wheel2: Int32(clamping: current.x - posted.x), wheel3: 0
            ) else { throw PetFailure.screenActionFailed }
            post(event); posted = current
            try await pause(90)
        }
    }

    private func keyboardEvent(_ key: CGKeyCode, _ down: Bool) throws -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        else { throw PetFailure.screenActionFailed }
        return event
    }

    private func mouseEvent(_ type: CGEventType, _ point: CGPoint) throws -> CGEvent {
        guard let event = CGEvent(
            mouseEventSource: source, mouseType: type,
            mouseCursorPosition: point, mouseButton: .left
        ) else { throw PetFailure.screenActionFailed }
        return event
    }

    private func move(to point: CGPoint) throws { post(try mouseEvent(.mouseMoved, point)) }
    private func pause(_ milliseconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: AppMetadata.syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }
    private func setMouseUp(_ point: CGPoint) {
        mouseLock.withLock { activeMouseUpPoint = point }
    }
    private func releaseMouseIfNeeded() {
        let point = mouseLock.withLock { let value = activeMouseUpPoint; activeMouseUpPoint = nil; return value }
        if let point, let event = try? mouseEvent(.leftMouseUp, point) { post(event) }
    }
}
