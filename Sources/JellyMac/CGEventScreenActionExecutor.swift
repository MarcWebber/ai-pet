import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import JellyCore

@MainActor
public final class CGEventScreenActionExecutor: ScreenActionExecuting {
    private let semanticProvider: BrowserAccessibilityContextProvider
    private let typingSpeedPercent: () -> Int
    private let source = CGEventSource(stateID: .privateState)
    private let mouseLock = NSLock()
    private var activeMouseUpPoint: CGPoint?

    public init(
        semanticProvider: BrowserAccessibilityContextProvider,
        typingSpeedPercent: @escaping () -> Int = {
            HumanTypingPlan.defaultSpeedPercent
        }
    ) {
        self.semanticProvider = semanticProvider
        self.typingSpeedPercent = typingSpeedPercent
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
        case let .typeText(target, text):
            guard semanticValue(
                for: target,
                snapshot: snapshot
            ) != nil else {
                throw PetFailure.editorTextUnavailable
            }
            let focusedElement = try await focusTextTarget(
                target,
                snapshot: snapshot,
                bounds: bounds
            )
            try await insert(text, focusedElement: focusedElement)
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

    private func focusTextTarget(
        _ target: ScreenActionTarget,
        snapshot: SemanticSnapshot?,
        bounds: CGRect
    ) async throws -> AXUIElement {
        guard let element = try nativeElement(target, snapshot: snapshot) else {
            throw PetFailure.semanticTargetUnavailable
        }
        var processID: pid_t = 0
        let pidStatus = AXUIElementGetPid(element, &processID)
        guard pidStatus == .success else {
            throw PetFailure.inputFocusChanged
        }
        try click(at: coordinate(target, snapshot, in: bounds), count: 1)
        try await pause(120)
        try ensureFocused(element)
        return element
    }

    private func ensureFocused(_ expected: AXUIElement) throws {
        var processID: pid_t = 0
        guard AXUIElementGetPid(expected, &processID) == .success,
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == processID else {
            throw PetFailure.inputFocusChanged
        }
        guard let focused = focusedElement(processID: processID) else {
            throw PetFailure.inputFocusChanged
        }
        if isSameOrDescendant(focused, of: expected) { return }
        guard isEditorSuggestion(focused) else {
            throw PetFailure.inputFocusChanged
        }
        try keyPress(.escape, [])
        usleep(150_000)
        guard let restored = focusedElement(processID: processID) else {
            throw PetFailure.inputFocusChanged
        }
        guard isSameOrDescendant(restored, of: expected) else {
            throw PetFailure.inputFocusChanged
        }
    }

    private func focusedElement(processID: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func isSameOrDescendant(
        _ element: AXUIElement,
        of ancestor: AXUIElement
    ) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<32 {
            guard let value = current else { return false }
            if CFEqual(value, ancestor) { return true }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                value,
                kAXParentAttribute as CFString,
                &parentValue
            ) == .success,
                  let parentValue,
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                return false
            }
            current = unsafeBitCast(parentValue, to: AXUIElement.self)
        }
        return false
    }

    private func isEditorSuggestion(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<16 {
            guard let value = current else { return false }
            var roleValue: CFTypeRef?, descriptionValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(
                value,
                kAXRoleAttribute as CFString,
                &roleValue
            )
            _ = AXUIElementCopyAttributeValue(
                value,
                kAXDescriptionAttribute as CFString,
                &descriptionValue
            )
            if roleValue as? String == kAXListRole,
               descriptionValue as? String == "Suggest" {
                return true
            }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                value,
                kAXParentAttribute as CFString,
                &parentValue
            ) == .success,
                  let parentValue,
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
                return false
            }
            current = unsafeBitCast(parentValue, to: AXUIElement.self)
        }
        return false
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

    private func type(
        _ text: String,
        focusedElement: AXUIElement? = nil
    ) async throws {
        let strokes = HumanTypingPlan.strokes(
            for: text,
            seed: UInt64.random(in: 1...UInt64.max),
            speedPercent: typingSpeedPercent()
        )
        var index = 0
        while index < strokes.count {
            let stroke = strokes[index]
            try Task.checkCancellation()
            if let focusedElement { try ensureTypingProcess(focusedElement) }
            if let mistake = stroke.mistypedText {
                try emit(mistake)
                try await pause(stroke.mistakeDelayMilliseconds)
                if let focusedElement {
                    try ensureTypingProcess(focusedElement)
                }
                try keyPress(.delete, [])
                try await pause(stroke.correctionDelayMilliseconds)
            }
            if stroke.text == "\n" {
                try keyPress(.return, [])
                try await pause(stroke.delayAfterMilliseconds)
                index += 1
                guard let focusedElement else { continue }
                var desiredIndent = ""
                while index < strokes.count,
                      strokes[index].text == " "
                        || strokes[index].text == "\t" {
                    desiredIndent += strokes[index].text
                    index += 1
                }
                try await matchAutomaticIndentation(
                    desiredIndent,
                    focusedElement: focusedElement
                )
            } else {
                try emit(stroke.text)
                if stroke.text == "{", let focusedElement {
                    try await pause(50)
                    try await removeAutoClosedBrace(
                        focusedElement: focusedElement
                    )
                }
                try await pause(stroke.delayAfterMilliseconds)
                index += 1
            }
        }
    }

    private func removeAutoClosedBrace(
        focusedElement: AXUIElement
    ) async throws {
        try ensureTypingProcess(focusedElement)
        var rawValue: CFTypeRef?, rawSelection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &rawValue
        ) == .success,
              let value = rawValue as? String,
              AXUIElementCopyAttributeValue(
                  focusedElement,
                  kAXSelectedTextRangeAttribute as CFString,
                  &rawSelection
              ) == .success,
              let rawSelection,
              CFGetTypeID(rawSelection) == AXValueGetTypeID() else {
            throw PetFailure.inputFocusChanged
        }
        let selectionValue = unsafeBitCast(rawSelection, to: AXValue.self)
        var selection = CFRange()
        let units = Array(value.utf16)
        guard AXValueGetValue(selectionValue, .cfRange, &selection),
              selection.length == 0,
              selection.location >= 0,
              selection.location <= units.count else {
            throw PetFailure.inputFocusChanged
        }
        guard selection.location < units.count,
              units[selection.location] == 125 else { return }
        try keyPress(.forwardDelete, [])
        try await pause(45)
    }

    private func matchAutomaticIndentation(
        _ desired: String,
        focusedElement: AXUIElement
    ) async throws {
        let wanted = Array(desired)
        for _ in 0..<64 {
            try ensureTypingProcess(focusedElement)
            let current = Array(try automaticIndentation(
                focusedElement: focusedElement
            ))
            if current == wanted { return }
            var shared = 0
            while shared < min(current.count, wanted.count),
                  current[shared] == wanted[shared] {
                shared += 1
            }
            if current.count > shared {
                try keyPress(.delete, [])
                try await pause(45)
            } else if wanted.count > shared {
                try emit(String(wanted[shared]))
                try await pause(45)
            } else {
                throw PetFailure.inputFocusChanged
            }
        }
        throw PetFailure.inputFocusChanged
    }

    private func automaticIndentation(
        focusedElement: AXUIElement
    ) throws -> String {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &rawValue
        ) == .success,
              let value = rawValue as? String else {
            throw PetFailure.editorTextUnavailable
        }
        var rawSelection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &rawSelection
        ) == .success,
              let rawSelection,
              CFGetTypeID(rawSelection) == AXValueGetTypeID() else {
            throw PetFailure.inputFocusChanged
        }
        let selectionValue = unsafeBitCast(rawSelection, to: AXValue.self)
        var selection = CFRange()
        guard AXValueGetValue(selectionValue, .cfRange, &selection),
              selection.length == 0 else {
            throw PetFailure.inputFocusChanged
        }
        let units = Array(value.utf16)
        guard selection.location >= 0,
              selection.location <= units.count else {
            throw PetFailure.inputFocusChanged
        }
        let cursor = selection.location
        let lineStart = units[..<cursor].lastIndex(of: 10).map { $0 + 1 } ?? 0
        let automatic = String(
            decoding: units[lineStart..<cursor],
            as: UTF16.self
        )
        guard automatic.allSatisfy({ $0 == " " || $0 == "\t" }) else {
            throw PetFailure.inputFocusChanged
        }
        return automatic
    }

    private func insert(
        _ text: String,
        focusedElement: AXUIElement
    ) async throws {
        let desired = HumanTextEditPlan.normalize(text)
        try ensureFocused(focusedElement)
        let current = HumanTextEditPlan.normalize(
            try editorText(focusedElement)
        )
        switch HumanTextEditPlan.make(
            currentText: current,
            desiredText: desired
        ) {
        case .currentTextUnavailable:
            throw PetFailure.editorTextUnavailable
        case .unchanged:
            return
        case let .replaceRange(location, length, value):
            try selectTextRange(
                location: location,
                length: length,
                focusedElement: focusedElement
            )
            if value.isEmpty {
                try keyPress(.delete, [])
            } else {
                try await type(value, focusedElement: focusedElement)
            }
        }
        try await pause(300)
        guard HumanTextEditPlan.normalize(try editorText(focusedElement))
            == desired else {
            throw PetFailure.screenActionFailed
        }
    }

    private func editorText(_ element: AXUIElement) throws -> String {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &rawValue
        ) == .success,
              let value = rawValue as? String else {
            throw PetFailure.editorTextUnavailable
        }
        return value
    }

    private func selectTextRange(
        location: Int,
        length: Int,
        focusedElement: AXUIElement
    ) throws {
        try ensureFocused(focusedElement)
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(
                  focusedElement,
                  kAXSelectedTextRangeAttribute as CFString,
                  value
              ) == .success else {
            throw PetFailure.inputFocusChanged
        }
    }

    private func ensureTypingProcess(_ expected: AXUIElement) throws {
        var processID: pid_t = 0
        guard AXUIElementGetPid(expected, &processID) == .success,
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == processID else {
            throw PetFailure.inputFocusChanged
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
