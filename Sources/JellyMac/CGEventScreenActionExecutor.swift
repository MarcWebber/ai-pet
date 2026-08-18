import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import JellyCore

@MainActor
public final class CGEventScreenActionExecutor: ScreenActionExecuting {
    private let source = CGEventSource(stateID: .privateState)
    private let mouseLock = NSLock()
    private var activeMouseUpPoint: CGPoint?

    public init() {}

    public func execute(
        _ action: ScreenAction,
        snapshot: SemanticSnapshot?,
        displayID: UInt32
    ) async throws {
        try action.validate()
        let bounds = try onlineBounds(displayID)
        switch action {
        case let .click(target):
            try click(at: coordinate(target, snapshot, in: bounds), count: 1)
        case let .doubleClick(target):
            try click(at: coordinate(target, snapshot, in: bounds), count: 2)
        case let .drag(fromX, fromY, toX, toY, duration):
            try await drag(
                from: coordinate(fromX, fromY, in: bounds),
                to: coordinate(toX, toY, in: bounds),
                duration: duration
            )
        case let .typeText(target, text, replaces):
            let point = try coordinate(target, snapshot, in: bounds)
            try click(at: point, count: 1); try await pause(120)
            try click(at: point, count: 1); try await pause(120)
            try await insert(text, replacing: replaces)
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
        }
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
        let characters = Array(text)
        let burst = characters.count > 2_000 ? 4 : characters.count > 600 ? 2 : 1
        for start in stride(from: 0, to: characters.count, by: burst) {
            try Task.checkCancellation()
            let value = String(characters[start..<min(start + burst, characters.count)])
            let events = try [keyboardEvent(0, true), keyboardEvent(0, false)]
            let utf16 = Array(value.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                guard let address = buffer.baseAddress else { return }
                events.forEach {
                    $0.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: address)
                }
            }
            events.forEach(post)
            let delay = characters.count > 2_000 ? 10 : characters.count > 600 ? 18 : 28
            try await pause(delay + (value.last.map { "\n。！？!?，,；;：:".contains($0) } == true ? 45 : 0))
        }
    }

    private func insert(_ text: String, replacing: Bool) async throws {
        if replacing { try keyPress(.a, [.command]); try await pause(80) }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return }
        try await type(String(first))
        for line in lines.dropFirst() {
            try Task.checkCancellation()
            try keyPress(.return, []); try await pause(45)
            try keyPress(.left, [.command, .shift]); try await pause(20)
            if line.isEmpty {
                try await type(" "); try keyPress(.delete, [])
            } else { try await type(String(line)) }
        }
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
