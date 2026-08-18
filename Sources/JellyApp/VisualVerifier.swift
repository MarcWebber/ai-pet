import AppKit
import JellyCore

@MainActor
enum VisualVerifier {
    struct Result {
        let passed: Bool
        let message: String
    }

    static func verifyPetTransparency() -> Result {
        guard let data = JellySpriteView.packagedSheet.tiffRepresentation,
              let atlas = NSBitmapImageRep(data: data)
        else {
            return Result(
                passed: false,
                message: "Visual verification failed: unable to decode the sprite atlas."
            )
        }

        func alpha(x: Int, y: Int) -> UInt8 {
            UInt8(
                ((atlas.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255)
                    .rounded()
            )
        }

        let cellWidth = atlas.pixelsWide / 8
        let cellHeight = atlas.pixelsHigh / 8
        let idleY = 0
        let cornerAlpha = [
            alpha(x: 0, y: idleY),
            alpha(x: cellWidth - 1, y: idleY),
            alpha(x: 0, y: idleY + cellHeight - 1),
            alpha(x: cellWidth - 1, y: idleY + cellHeight - 1)
        ]
        let centerAlpha = alpha(
            x: cellWidth / 2,
            y: idleY + cellHeight / 2
        )

        let successColumn = 3
        let successX = successColumn * cellWidth
        let successY = 6 * cellHeight
        let sourceHeadroom = Int(
            (CGFloat(cellHeight) * JellyView.successSourceHeadroomRatio)
                .rounded()
        )
        let headroomAlpha = (successY - sourceHeadroom..<successY).flatMap { y in
            (successX..<successX + cellWidth).map { alpha(x: $0, y: y) }
        }.max() ?? 0
        let topEdgeY = successY - sourceHeadroom
        let topEdgeAlpha = (successX..<successX + cellWidth).map {
            alpha(x: $0, y: topEdgeY)
        }.max() ?? 0
        let requiredPanelHeight = JellyView.baseSpriteHeight
            * (1 + JellyView.successSourceHeadroomRatio)

        let passed = cornerAlpha.allSatisfy { $0 == 0 }
            && centerAlpha > 0
            && topEdgeAlpha == 0
            && headroomAlpha > 0
            && JellyView.panelHeight >= ceil(requiredPanelHeight)
        let message = passed
            ? "Visual verification passed: pet corners are transparent and the success jump fits its headroom."
            : "Visual verification failed: corner alpha \(cornerAlpha), center alpha \(centerAlpha), success top edge \(topEdgeAlpha), headroom alpha \(headroomAlpha)."

        return Result(passed: passed, message: message)
    }

    static func verifySettingsLayout() -> Result {
        let form = SettingsFormView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 1_260)
        )
        form.render(SettingsViewState(
            displays: [],
            selectedDisplayID: nil,
            assistantPreferences: AssistantPreferences.default,
            takeoverEnabled: false,
            showActivityDetails: true,
            globalShortcut: .controlOptionSpace,
            answerScrollShortcut: .controlOptionArrows,
            answerHistoryShortcut: .controlOptionArrows,
            availableRuntimes: [],
            modelOptions: ["gpt-5.6-luna"],
            runtimeText: "布局检查",
            configurationURL: URL(fileURLWithPath: "/tmp/JellyPet/config.json"),
            configurationError: nil,
            spriteSheetURL: nil
        ))
        let verification = form.verifyEditableLayout()
        return Result(
            passed: verification.passed,
            message: verification.passed
                ? "Settings layout verification passed: \(verification.message)."
                : "Settings layout verification failed: \(verification.message)."
        )
    }

}
