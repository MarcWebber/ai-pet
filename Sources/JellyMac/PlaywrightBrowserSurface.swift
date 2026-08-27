import AppKit
import Foundation
import JellyCore

public enum PlaywrightBrowserChannel: String, Equatable, Sendable {
    case chrome
    case edge = "msedge"

    public static func channel(bundleIdentifier: String?) -> PlaywrightBrowserChannel? {
        switch bundleIdentifier {
        case "com.google.Chrome": .chrome
        case "com.microsoft.edgemac": .edge
        default: nil
        }
    }
}

public enum PlaywrightBrowserPreparation: Equatable, Sendable {
    case attached
    case unavailable(String)
}

public enum PlaywrightSnapshotParser {
    public static func parse(
        yaml: String,
        commandOutput: String,
        viewportWidth: Int = 1_280,
        viewportHeight: Int = 900
    ) -> SemanticSnapshot? {
        var elements: [SemanticElement] = []
        var ancestors: [(indent: Int, id: String)] = []
        for sourceLine in yaml.split(whereSeparator: \.isNewline) {
            let line = String(sourceLine)
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) {
                $0 + ($1 == "\t" ? 2 : 1)
            }
            while ancestors.last.map({ $0.indent >= indent }) == true {
                ancestors.removeLast()
            }
            guard let semantic = element(
                line,
                parentID: ancestors.last?.id,
                width: viewportWidth,
                height: viewportHeight
            ) else { continue }
            elements.append(semantic)
            ancestors.append((indent, semantic.id))
        }
        let url = pageValue("Page URL", commandOutput)
        let title = pageValue("Page Title", commandOutput) ?? ""
        guard !elements.isEmpty || !yaml.isEmpty || url != nil else { return nil }
        return SemanticSnapshot(
            applicationName: "Playwright Browser", windowTitle: title,
            pageURL: url, readableText: String(yaml.prefix(12_000)),
            elements: Array(elements.prefix(250))
        )
    }

    private static func element(
        _ line: String,
        parentID: String?,
        width: Int,
        height: Int
    ) -> SemanticElement? {
        guard let ref = attribute("ref", line),
              let box = attribute("box", line)?.split(separator: ",").compactMap({
                  Double($0).map { Int($0.rounded()) }
              }),
              box.count == 4 else { return nil }
        var descriptor = line.trimmingCharacters(in: .whitespaces)
        if descriptor.hasPrefix("-") { descriptor.removeFirst() }
        let name = descriptor.split(whereSeparator: { $0.isWhitespace || $0 == ":" }).first.map(String.init)
        let roles: [String: SemanticElementRole] = [
            "button": .button, "link": .link, "textbox": .textField,
            "searchbox": .textField, "spinbutton": .textField,
            "checkbox": .checkBox, "radio": .radioButton,
            "menuitem": .menuItem, "combobox": .popUpButton,
            "scrollbar": .scrollArea, "dialog": .dialog,
            "group": .group, "list": .list, "listitem": .listItem,
            "row": .row, "cell": .cell, "gridcell": .cell,
            "tab": .tab, "heading": .heading,
            "text": .staticText, "paragraph": .staticText
        ]
        guard let name, let role = roles[name], width > 0, height > 0 else { return nil }
        let left = min(width, max(0, box[0])), top = min(height, max(0, box[1]))
        let right = min(width, max(left, box[0] + box[2]))
        let bottom = min(height, max(top, box[1] + box[3]))
        guard right > left, bottom > top else { return nil }
        let x = left * 1_000 / width, y = top * 1_000 / height
        let quote = line.firstIndex(of: "\"").flatMap { start in
            line[line.index(after: start)...].firstIndex(of: "\"").map {
                String(line[line.index(after: start)..<$0])
            }
        }
        return SemanticElement(
            id: ref, parentID: parentID,
            role: role, label: quote ?? role.rawValue,
            value: value(line, role: role),
            frame: SemanticRect(
                x: x, y: y, width: max(1, right * 1_000 / width - x),
                height: max(1, bottom * 1_000 / height - y)
            ),
            isEnabled: !line.contains("[disabled]")
        )
    }

    private static func value(
        _ line: String,
        role: SemanticElementRole
    ) -> String? {
        if role == .checkBox || role == .radioButton {
            return line.contains("[checked]") ? "checked" : "unchecked"
        }
        if role == .popUpButton, line.contains("[selected]") {
            return "selected"
        }
        guard role == .textField,
              let firstQuote = line.firstIndex(of: "\""),
              let lastQuote = line[line.index(after: firstQuote)...]
                .firstIndex(of: "\"")
        else { return nil }
        let tail = line[line.index(after: lastQuote)...]
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        let valueTail = tail[tail.index(after: colon)...]
        let boundary = [" [ref=", " [box=", " [disabled]", " [checked]"]
            .compactMap { valueTail.range(of: $0)?.lowerBound }
            .min() ?? valueTail.endIndex
        let raw = valueTail[..<boundary].trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !raw.isEmpty else { return "" }
        if raw.count >= 2, raw.first == "\"", raw.last == "\"" {
            return String(raw.dropFirst().dropLast())
        }
        return String(raw)
    }

    private static func attribute(_ name: String, _ line: String) -> String? {
        guard let start = line.range(of: "[\(name)=")?.upperBound,
              let end = line[start...].firstIndex(of: "]") else { return nil }
        return String(line[start..<end])
    }

    private static func pageValue(_ name: String, _ output: String) -> String? {
        let prefix = "- \(name):"
        for line in output.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix(prefix) {
                return String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

@MainActor
final class PlaywrightBrowserSurface: CaptureService, ScreenActionExecuting {
    private enum SessionOwnership { case none, attached }
    private static let defaultViewport = (width: 1_280, height: 900)
    public let prefersSemanticObservation = true
    private let executableURL: URL?
    private let runner: ProcessRunning
    private let temporaryRoot: URL
    private let session: String
    private var ownership = SessionOwnership.none
    private var viewport: (width: Int, height: Int)

    init() {
        let temporaryRoot = FileManager.default.temporaryDirectory
        let session = "jellypet-\(ProcessInfo.processInfo.processIdentifier)"
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        self.executableURL = paths.lazy.map {
            URL(fileURLWithPath: $0).appendingPathComponent("playwright-cli")
        }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
        self.runner = FoundationProcessRunner(currentDirectoryURL: temporaryRoot)
        self.temporaryRoot = temporaryRoot
        self.session = session
        viewport = Self.defaultViewport
    }

    public func prepare(
        attachingTo channel: PlaywrightBrowserChannel?
    ) async throws -> PlaywrightBrowserPreparation {
        guard executableURL != nil else {
            return .unavailable("没有找到 playwright-cli")
        }
        if ownership != .none { await endSession() }
        guard let channel else {
            return .unavailable("当前前台应用不是 Chrome 或 Edge")
        }
        return try await attach(to: channel)
    }

    public func capture(displayID _: UInt32) async throws -> CaptureArtifact {
        guard ownership != .none else { throw PetFailure.captureFailed }
        let directory = temporaryRoot.appendingPathComponent(
            "JellyPet-Capture-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let image = directory.appendingPathComponent("screen.png")
        do { _ = try await command(["screenshot", "--filename=\(image.path)"]) }
        catch is CancellationError {
            try? FileManager.default.removeItem(at: directory)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw PetFailure.captureFailed
        }
        guard FileManager.default.fileExists(atPath: image.path) else {
            try? FileManager.default.removeItem(at: directory)
            throw PetFailure.captureFailed
        }
        if let representation = NSImage(contentsOf: image)?.representations.first,
           representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            viewport = (representation.pixelsWide, representation.pixelsHigh)
        }
        return CaptureArtifact(imageURL: image, sessionDirectoryURL: directory)
    }

    public func snapshot(displayID _: UInt32) async -> SemanticSnapshot? {
        guard ownership != .none else { return nil }
        let directory = temporaryRoot.appendingPathComponent(
            "JellyPet-Semantics-\(UUID().uuidString)", isDirectory: true
        )
        guard (try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("page.yaml")
        guard let output = try? await command(["snapshot", "--boxes", "--filename=\(file.path)"]),
              let yaml = try? String(contentsOf: file, encoding: .utf8),
              let value = PlaywrightSnapshotParser.parse(
                  yaml: yaml, commandOutput: output,
                  viewportWidth: viewport.width,
                  viewportHeight: viewport.height
              )
        else { return nil }
        return value
    }

    public func execute(_ action: ScreenAction, snapshot: SemanticSnapshot?, displayID _: UInt32) async throws {
        try action.validate()
        try await perform(action, snapshot)
    }

    public func cancel() { runner.cancel() }

    public func close() async {
        await endSession()
    }

    private func reset() {
        ownership = .none
        viewport = Self.defaultViewport
    }

    private func attach(
        to channel: PlaywrightBrowserChannel
    ) async throws -> PlaywrightBrowserPreparation {
        struct DiscoveredChannel: Decodable {
            let channel: String
            let endpoint: String?
            let extensionInstalled: Bool
        }
        struct BrowserListing: Decodable {
            let channelSessions: [DiscoveredChannel]
        }
        let discoveryOutput: String
        do {
            discoveryOutput = try await command(
                ["list", "--all", "--json"], timeout: 4
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unavailable("无法读取 Playwright 浏览器连接状态")
        }
        guard let data = discoveryOutput.data(using: .utf8),
              let listing = try? JSONDecoder().decode(
                  BrowserListing.self,
                  from: data
              ),
              let discovery = listing.channelSessions.first(where: {
                  $0.channel == channel.rawValue
              }) else {
            return .unavailable("Playwright 没有发现当前浏览器")
        }
        var attempts: [[String]] = []
        if discovery.extensionInstalled {
            attempts.append(["attach", "--extension=\(channel.rawValue)"])
        }
        if discovery.endpoint?.isEmpty == false {
            attempts.append(["attach", "--cdp=\(channel.rawValue)"])
        }
        guard !attempts.isEmpty else {
            return .unavailable(
                "当前浏览器没有安装 Playwright Extension，也没有开启 CDP"
            )
        }
        for arguments in attempts {
            do {
                let timeout: TimeInterval = arguments.contains {
                    $0.hasPrefix("--extension=")
                } ? 30 : 6
                _ = try await command(arguments, timeout: timeout)
                ownership = .attached
                return .attached
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                _ = try? await command(["detach"], timeout: 2)
                reset()
            }
        }
        return .unavailable("Playwright 发现了浏览器，但连接失败")
    }

    private func endSession() async {
        guard ownership != .none else { reset(); return }
        _ = try? await command(["detach"], timeout: 5)
        reset()
    }

    private func perform(_ action: ScreenAction, _ snapshot: SemanticSnapshot?) async throws {
        switch action {
        case let .click(target), let .doubleClick(target):
            let count = action.isDoubleClick ? 2 : 1
            if let ref = try ref(target, snapshot) {
                _ = try await command([count == 2 ? "dblclick" : "click", ref])
            } else {
                let point = try point(target)
                _ = try await code("await page.mouse.click(\(point.x), \(point.y), { clickCount: \(count) });")
            }
        case let .typeText(target, text, replaces):
            let currentText = semanticValue(for: target, snapshot: snapshot)
            if let ref = try ref(target, snapshot) {
                _ = try await command(["click", ref])
            } else {
                let point = try point(target)
                _ = try await code(
                    "await page.mouse.click(\(point.x), \(point.y));"
                )
            }
            try await applyHumanEdit(
                text,
                replacing: replaces,
                currentText: currentText
            )
        case let .drag(fromX, fromY, toX, toY, duration):
            let from = point(fromX, fromY), to = point(toX, toY)
            _ = try await code("await page.mouse.move(\(from.x), \(from.y)); await page.mouse.down(); await page.mouse.move(\(to.x), \(to.y), { steps: \(max(12, min(60, duration / 16))) }); await page.mouse.up();")
        case let .keyPress(key, modifiers): _ = try await command(["press", keyName(key, modifiers)])
        case let .navigate(url):
            _ = try await command(["goto", url], timeout: 60)
        case let .scroll(target, deltaX, deltaY):
            if let target {
                if let ref = try ref(target, snapshot) { _ = try await command(["hover", ref]) }
                else {
                    let point = try point(target)
                    _ = try await command(["mousemove", "\(point.x)", "\(point.y)"])
                }
            }
            let x = -deltaX, y = -deltaY
            let steps = max(3, min(6, Int(ceil(Double(max(abs(x), abs(y))) / 70))))
            _ = try await code("for (let i = 0; i < \(steps); i++) { await page.mouse.wheel(\(x / steps), \(y / steps)); await page.waitForTimeout(90); }")
        case let .wait(milliseconds):
            try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        }
    }

    private func ref(_ target: ScreenActionTarget, _ snapshot: SemanticSnapshot?) throws -> String? {
        guard case let .element(elementID) = target else { return nil }
        guard snapshot?.elements.contains(where: {
                  $0.id == elementID && $0.isEnabled
              }) == true
        else { throw PetFailure.semanticTargetUnavailable }
        return elementID
    }

    private func semanticValue(
        for target: ScreenActionTarget,
        snapshot: SemanticSnapshot?
    ) -> String? {
        guard case let .element(elementID) = target else { return nil }
        return snapshot?.elements.first(where: { $0.id == elementID })?.value
    }

    private func point(_ target: ScreenActionTarget) throws -> (x: Int, y: Int) {
        guard case let .visual(x, y) = target else { throw PetFailure.invalidScreenAction }
        return point(x, y)
    }

    private func point(_ x: Int, _ y: Int) -> (x: Int, y: Int) {
        (x * viewport.width / 1_000, y * viewport.height / 1_000)
    }

    private func keyName(_ key: ScreenKey, _ modifiers: [KeyModifier]) -> String {
        let prefix = modifiers.map {
            switch $0 { case .command: "Meta"; case .control: "Control"; case .option: "Alt"; case .shift: "Shift" }
        }
        let value = switch key {
        case .return: "Enter"; case .escape: "Escape"; case .delete: "Backspace"
        case .forwardDelete: "Delete"; case .left: "ArrowLeft"; case .right: "ArrowRight"
        case .up: "ArrowUp"; case .down: "ArrowDown"; case .pageUp: "PageUp"
        case .pageDown: "PageDown"; case .space: "Space"; default: key.rawValue
        }
        return (prefix + [value]).joined(separator: "+")
    }

    private func applyHumanEdit(
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
        case .unchanged:
            return
        case let .append(value):
            try await typeHumanly(value, replacing: false)
        case let .replaceAll(value):
            try await typeHumanly(value, replacing: true)
        case let .replaceRange(prefix, removed, suffix, replacement):
            let selection: String
            if prefix <= suffix {
                selection = """
                await page.keyboard.press('Meta+ArrowUp');
                for (let i = 0; i < \(prefix); i++) await page.keyboard.press('ArrowRight');
                for (let i = 0; i < \(removed); i++) await page.keyboard.press('Shift+ArrowRight');
                """
            } else {
                selection = """
                await page.keyboard.press('Meta+ArrowDown');
                for (let i = 0; i < \(suffix); i++) await page.keyboard.press('ArrowLeft');
                for (let i = 0; i < \(removed); i++) await page.keyboard.press('Shift+ArrowLeft');
                """
            }
            _ = try await code(selection, timeout: 30)
            if replacement.isEmpty {
                if removed > 0 { _ = try await command(["press", "Backspace"]) }
            } else {
                try await typeHumanly(replacement, replacing: false)
            }
        }
    }

    private func typeHumanly(
        _ text: String,
        replacing: Bool
    ) async throws {
        let strokes = HumanTypingPlan.strokes(
            for: HumanTextEditPlan.normalize(text),
            seed: UInt64.random(in: 1...UInt64.max)
        )
        let encoded = try JSONEncoder().encode(strokes)
        let plan = String(decoding: encoded, as: UTF8.self)
        let reset = replacing
            ? "await page.keyboard.press('Meta+A'); await page.waitForTimeout(90); await page.keyboard.press('Backspace'); await page.waitForTimeout(120);"
            : ""
        let body = """
        \(reset)
        const strokes = \(plan);
        const typeOne = async (value) => {
          if (/^[\\x20-\\x7E]$/.test(value)) await page.keyboard.type(value);
          else await page.keyboard.insertText(value);
        };
        for (let index = 0; index < strokes.length; index++) {
          const stroke = strokes[index];
          if (stroke.mistypedText) {
            await typeOne(stroke.mistypedText);
            await page.waitForTimeout(stroke.mistakeDelayMilliseconds);
            await page.keyboard.press('Backspace');
            await page.waitForTimeout(stroke.correctionDelayMilliseconds);
          }
          if (stroke.text === '\\n') {
            await page.keyboard.press('Enter');
            await page.waitForTimeout(stroke.delayAfterMilliseconds);
            await page.keyboard.press('Meta+Shift+ArrowLeft');
            await page.waitForTimeout(25);
            const next = strokes[index + 1]?.text;
            if (next === undefined || next === '\\n') {
              await page.keyboard.type(' ');
              await page.keyboard.press('Backspace');
            }
          } else {
            await typeOne(stroke.text);
            await page.waitForTimeout(stroke.delayAfterMilliseconds);
          }
        }
        """
        let delay = strokes.reduce(0) {
            $0 + $1.delayAfterMilliseconds
                + ($1.mistypedText == nil
                    ? 0
                    : $1.mistakeDelayMilliseconds
                        + $1.correctionDelayMilliseconds)
        }
        let timeout = min(3_600, max(30, TimeInterval(delay) / 1_000 + 20))
        _ = try await code(body, timeout: timeout)
    }

    private func code(
        _ body: String,
        timeout: TimeInterval = 30
    ) async throws -> String {
        try await command(
            ["run-code", "async (page) => { \(body) }"],
            timeout: timeout
        )
    }

    private func command(_ arguments: [String], timeout: TimeInterval = 30) async throws -> String {
        guard let executableURL else { throw PetFailure.screenActionFailed }
        let result: ProcessResult
        do {
            result = try await runner.run(
                executableURL: executableURL,
                arguments: ["-s=\(session)"] + arguments,
                standardInput: Data(), timeout: timeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PetFailure.screenActionFailed
        }
        try Task.checkCancellation()
        guard result.exitCode == 0, result.stdout.count <= 4 * 1_024 * 1_024
        else { throw PetFailure.screenActionFailed }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}

private extension ScreenAction {
    var isDoubleClick: Bool {
        if case .doubleClick = self { return true }
        return false
    }
}

@MainActor
public final class TakeoverSurfaceRouter: CaptureService, SemanticContextProviding, ScreenActionExecuting {
    private enum Route { case native, playwright }
    private let native: (CaptureService, SemanticContextProviding, ScreenActionExecuting)
    private let playwright: PlaywrightBrowserSurface
    private var route = Route.native

    public init(
        nativeCapture: CaptureService,
        nativeSemantics: SemanticContextProviding,
        nativeExecutor: ScreenActionExecuting
    ) {
        native = (nativeCapture, nativeSemantics, nativeExecutor)
        self.playwright = PlaywrightBrowserSurface()
    }

    public func useNative() { route = .native }
    public var prefersSemanticObservation: Bool { route == .playwright }
    public func closeBrowser() async {
        await playwright.close()
        route = .native
    }
    public func prepareBrowser(
        attachingTo channel: PlaywrightBrowserChannel?
    ) async throws -> PlaywrightBrowserPreparation {
        route = .native
        let preparation = try await playwright.prepare(
            attachingTo: channel
        )
        if case .attached = preparation { route = .playwright }
        return preparation
    }
    public func capture(displayID: UInt32) async throws -> CaptureArtifact {
        route == .native
            ? try await native.0.capture(displayID: displayID)
            : try await playwright.capture(displayID: displayID)
    }
    public func snapshot(displayID: UInt32) async -> SemanticSnapshot? {
        route == .native ? await native.1.snapshot(displayID: displayID)
            : await playwright.snapshot(displayID: displayID)
    }
    public func execute(_ action: ScreenAction, snapshot: SemanticSnapshot?, displayID: UInt32) async throws {
        if route == .native { try await native.2.execute(action, snapshot: snapshot, displayID: displayID) }
        else { try await playwright.execute(action, snapshot: snapshot, displayID: displayID) }
    }
    public func cancel() { route == .native ? native.2.cancel() : playwright.cancel() }
}
