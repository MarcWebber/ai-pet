import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import JellyCore

public enum BrowserSemanticPolicy {
    public enum NavigationEntry: Equatable { case addressBar, spotlight }

    public static let supportedBundleIDs: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.beta",
        "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "org.mozilla.firefox"
    ]

    public static func role(_ axRole: String) -> SemanticElementRole? {
        switch axRole {
        case kAXButtonRole: .button
        case "AXLink": .link
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole: .textField
        case kAXCheckBoxRole: .checkBox
        case kAXRadioButtonRole: .radioButton
        case kAXMenuItemRole: .menuItem
        case kAXPopUpButtonRole: .popUpButton
        case kAXScrollAreaRole, "AXWebArea": .scrollArea
        case "AXDialog", "AXSheet": .dialog
        case kAXGroupRole, "AXTabGroup": .group
        case kAXListRole: .list
        case "AXListItem": .listItem
        case kAXRowRole: .row
        case kAXCellRole: .cell
        case "AXTab": .tab
        case "AXHeading": .heading
        case kAXStaticTextRole: .staticText
        default: nil
        }
    }

    public static func role(
        _ axRole: String,
        label: String,
        identifier: String?
    ) -> SemanticElementRole? {
        if isCodeEditorCandidate(role: axRole, label: label, identifier: identifier) {
            return .textField
        }
        return role(axRole)
    }

    public static func isCodeEditorCandidate(
        role: String,
        label: String,
        identifier: String?
    ) -> Bool {
        let codeEditorRoles = ["AXGroup", "AXUnknown", "AXWebArea", "AXScrollArea"]
        let text = "\(label) \(identifier ?? "")".lowercased()
        let codeEditorLabels = [
            "editor content", "code editor", "monaco-editor", "codemirror",
            "代码编辑器", "代码输入"
        ]
        return codeEditorRoles.contains(role) && codeEditorLabels.contains(where: text.contains)
    }

    public static func navigationEntry(frontmostBundleID: String?) -> NavigationEntry {
        guard let frontmostBundleID, supportedBundleIDs.contains(frontmostBundleID)
        else { return .spotlight }
        return .addressBar
    }

    public static func safeValue(
        role: SemanticElementRole,
        subrole: String?,
        value: String?
    ) -> String? {
        guard role != .textField || subrole != kAXSecureTextFieldSubrole else { return nil }
        guard role == .textField, let value else { return compact(value) }
        let clean = value.unicodeScalars.map {
            $0.value == 10 || $0.value == 9 ? String($0)
                : CharacterSet.controlCharacters.contains($0) ? " " : String($0)
        }.joined()
        return clean.isEmpty ? nil : String(clean.prefix(4_000))
    }

    public static func pageURL(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_048,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              var parts = URLComponents(string: trimmed),
              let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), parts.host?.isEmpty == false
        else { return nil }
        parts.scheme = scheme; parts.user = nil; parts.password = nil; parts.fragment = nil
        return parts.string
    }

    public static func readableText(_ fragments: [String]) -> String? {
        var seen: Set<String> = [], lines: [String] = [], count = 0
        for fragment in fragments.prefix(80) {
            guard let value = compact(fragment), seen.insert(value).inserted else { continue }
            let remaining = 4_000 - count - (lines.isEmpty ? 0 : 1)
            guard remaining > 0 else { break }
            let line = String(value.prefix(remaining))
            lines.append(line); count += line.count + (lines.count > 1 ? 1 : 0)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    public static func normalizedFrame(_ frame: CGRect, displayBounds: CGRect) -> SemanticRect? {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return nil }
        let frame = frame.intersection(displayBounds)
        guard !frame.isNull, frame.width >= 2, frame.height >= 2 else { return nil }
        func value(_ point: CGFloat, _ origin: CGFloat, _ length: CGFloat) -> Int {
            min(1_000, max(0, Int(((point - origin) / length * 1_000).rounded())))
        }
        let x = value(frame.minX, displayBounds.minX, displayBounds.width)
        let y = value(frame.minY, displayBounds.minY, displayBounds.height)
        let result = SemanticRect(
            x: x, y: y,
            width: max(1, value(frame.maxX, displayBounds.minX, displayBounds.width) - x),
            height: max(1, value(frame.maxY, displayBounds.minY, displayBounds.height) - y)
        )
        return result.isValid ? result : nil
    }

    static func compact(_ value: String?) -> String? {
        let words = value?.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : String($0)
        }.joined().split(whereSeparator: \.isWhitespace)
        guard let words, !words.isEmpty else { return nil }
        return String(words.joined(separator: " ").prefix(160))
    }
}

@MainActor
public final class BrowserAccessibilityContextProvider: SemanticContextProviding {
    private struct Node {
        let element: AXUIElement
        let visibleBounds: CGRect
        let semanticParentID: Int?
    }
    private struct Candidate {
        let temporaryID: Int
        let parentTemporaryID: Int?
        let semantic: SemanticElement
        let element: AXUIElement
    }
    private struct Traversal {
        var candidates: [Candidate] = []
        var pageURL: String?
        var text: [String] = []
    }
    private var observationID = UUID().uuidString.lowercased()
    private var nativeElements: [String: AXUIElement] = [:]

    public init() {}

    public func snapshot(displayID: UInt32) async -> SemanticSnapshot? {
        // AX references are intentionally valid for one observation only. Clear them even
        // when the next observation fails so an old element can never be acted upon later.
        observationID = UUID().uuidString.lowercased()
        nativeElements.removeAll(keepingCapacity: true)
        let currentObservationID = observationID
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let processID = app.processIdentifier
        guard let window = frontWindow(
            AXUIElementCreateApplication(processID),
            intersecting: bounds
        ), let windowFrame = window.axFrame else { return nil }
        let visible = windowFrame.intersection(bounds)
        guard !visible.isNull else { return nil }

        let traversal = await traverse(window, displayBounds: bounds, visibleBounds: visible)
        let text = BrowserSemanticPolicy.readableText(traversal.text)
        guard !traversal.candidates.isEmpty || traversal.pageURL != nil || text != nil
        else { return nil }

        var elements: [SemanticElement] = []
        let sorted = traversal.candidates.sorted {
            ($0.semantic.frame.y, $0.semantic.frame.x)
                < ($1.semantic.frame.y, $1.semantic.frame.x)
        }.prefix(250)
        var currentNativeElements: [String: AXUIElement] = [:]
        let assignedIDs = Dictionary(uniqueKeysWithValues: sorted.enumerated().map {
            ($0.element.temporaryID, "ax-\(currentObservationID)-e\($0.offset + 1)")
        })
        for candidate in sorted {
            guard let elementID = assignedIDs[candidate.temporaryID] else { continue }
            let semantic = SemanticElement(
                id: elementID,
                parentID: candidate.parentTemporaryID.flatMap { assignedIDs[$0] },
                role: candidate.semantic.role,
                label: candidate.semantic.label, value: candidate.semantic.value,
                frame: candidate.semantic.frame, isEnabled: candidate.semantic.isEnabled
            )
            elements.append(semantic)
            currentNativeElements[elementID] = candidate.element
        }
        let snapshot = SemanticSnapshot(
            applicationName: BrowserSemanticPolicy.compact(app.localizedName)
                ?? app.bundleIdentifier ?? "",
            windowTitle: BrowserSemanticPolicy.compact(window.axString(kAXTitleAttribute)) ?? "",
            pageURL: traversal.pageURL,
            readableText: text,
            elements: elements
        )
        guard currentObservationID == observationID else { return nil }
        nativeElements = currentNativeElements
        return snapshot
    }

    func nativeElement(for id: String) -> AXUIElement? {
        guard id.hasPrefix("ax-\(observationID)-") else { return nil }
        return nativeElements[id]
    }

    private func frontWindow(_ app: AXUIElement, intersecting bounds: CGRect?) -> AXUIElement? {
        if let focused = app.axElement(kAXFocusedWindowAttribute), validWindow(focused, bounds) {
            return focused
        }
        return app.axElements(kAXWindowsAttribute).first { validWindow($0, bounds) }
    }

    private func validWindow(_ window: AXUIElement, _ bounds: CGRect?) -> Bool {
        guard window.axBool(kAXMinimizedAttribute) != true, let frame = window.axFrame
        else { return false }
        return bounds.map(frame.intersects) ?? true
    }

    private func traverse(
        _ window: AXUIElement,
        displayBounds: CGRect,
        visibleBounds: CGRect
    ) async -> Traversal {
        var result = Traversal(), stack = [Node(
            element: window,
            visibleBounds: visibleBounds,
            semanticParentID: nil
        )]
        var visited = 0
        while let node = stack.popLast(), visited < 2_500, !Task.isCancelled {
            visited += 1
            if visited.isMultiple(of: 8) { await Task.yield() }
            let element = node.element
            if element.axBool(kAXHiddenAttribute) == true { continue }
            var childBounds = node.visibleBounds
            if let frame = element.axFrame, frame.width > 0, frame.height > 0 {
                guard frame.intersects(node.visibleBounds) else { continue }
                if clips(element) { childBounds = frame.intersection(node.visibleBounds) }
            }
            var descendantParentID = node.semanticParentID
            if result.candidates.count < 250,
               let candidate = candidate(
                   element,
                   displayBounds,
                   node.visibleBounds,
                   temporaryID: result.candidates.count,
                   parentTemporaryID: node.semanticParentID
               ) {
                result.candidates.append(candidate)
                descendantParentID = candidate.temporaryID
            }
            if let role = element.axString(kAXRoleAttribute) {
                if role == "AXWebArea", result.pageURL == nil {
                    result.pageURL = BrowserSemanticPolicy.pageURL(
                        element.axURL(kAXURLAttribute) ?? element.axURL(kAXDocumentAttribute)
                    )
                }
                if result.text.count < 80,
                   ["AXHeading", "AXStaticText"].contains(role),
                   element.axFrame?.intersects(node.visibleBounds) == true,
                   let value = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
                    .compactMap({ BrowserSemanticPolicy.compact(element.axString($0)) }).first {
                    result.text.append(value)
                }
            }
            stack += element.axElements(kAXChildrenAttribute).reversed().map {
                Node(
                    element: $0,
                    visibleBounds: childBounds,
                    semanticParentID: descendantParentID
                )
            }
        }
        return result
    }

    private func candidate(
        _ element: AXUIElement,
        _ displayBounds: CGRect,
        _ visibleBounds: CGRect,
        temporaryID: Int,
        parentTemporaryID: Int?
    ) -> Candidate? {
        guard let role = semanticRole(element),
              let frame = element.axFrame,
              let normalized = BrowserSemanticPolicy.normalizedFrame(
                  frame.intersection(visibleBounds), displayBounds: displayBounds
              ) else { return nil }
        let value = BrowserSemanticPolicy.safeValue(
            role: role,
            subrole: element.axString(kAXSubroleAttribute),
            value: element.axString(kAXValueAttribute)
        )
        let label = element.axLabel.isEmpty
            ? BrowserSemanticPolicy.compact(value) ?? ""
            : element.axLabel
        guard shouldExpose(role: role, label: label, value: value) else { return nil }
        return Candidate(
            temporaryID: temporaryID,
            parentTemporaryID: parentTemporaryID,
            semantic: SemanticElement(
                id: "", role: role, label: label, value: value,
                frame: normalized,
                isEnabled: element.axBool(kAXEnabledAttribute) != false
            ),
            element: element
        )
    }

    private func semanticRole(_ element: AXUIElement) -> SemanticElementRole? {
        guard let role = element.axString(kAXRoleAttribute) else { return nil }
        if ["AXDialog", "AXSheet"].contains(element.axString(kAXSubroleAttribute)) {
            return .dialog
        }
        return BrowserSemanticPolicy.role(
            role, label: element.axLabel,
            identifier: element.axString("AXIdentifier")
        )
    }

    private func shouldExpose(
        role: SemanticElementRole,
        label: String,
        value: String?
    ) -> Bool {
        switch role {
        case .group:
            return !label.isEmpty || value?.isEmpty == false
        case .heading, .staticText:
            return !label.isEmpty
        default:
            return true
        }
    }

    private func clips(_ element: AXUIElement) -> Bool {
        ["AXWebArea", kAXScrollAreaRole].contains(element.axString(kAXRoleAttribute))
    }
}

private extension AXUIElement {
    func axValue(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success
            ? value : nil
    }
    func axString(_ name: String) -> String? { axValue(name) as? String }
    func axBool(_ name: String) -> Bool? { axValue(name) as? Bool }
    func axURL(_ name: String) -> String? {
        let value = axValue(name)
        return (value as? URL)?.absoluteString ?? value as? String
    }
    func axElement(_ name: String) -> AXUIElement? {
        guard let value = axValue(name), CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    func axElements(_ name: String) -> [AXUIElement] {
        axValue(name) as? [AXUIElement] ?? []
    }
    var axFrame: CGRect? {
        guard let position = axAXValue(kAXPositionAttribute),
              let size = axAXValue(kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    var axLabel: String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute]
            .compactMap { BrowserSemanticPolicy.compact(axString($0)) }.first ?? ""
    }
    private func axAXValue(_ name: String) -> AXValue? {
        guard let value = axValue(name), CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }
}
