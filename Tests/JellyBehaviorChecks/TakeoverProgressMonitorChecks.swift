import Foundation
import CoreGraphics
import ImageIO
import JellyCore
import UniformTypeIdentifiers

func runTakeoverProgressMonitorChecks() {
    var monitor = TakeoverProgressMonitor()
    let unchanged = progressSnapshot(value: "before")
    check(monitor.recordObservation(snapshot: unchanged, screenshotPNG: nil) == .proceed, "initial observation must proceed")
    for repetition in 1...4 {
        check(monitor.recordAction() == .proceed, "action \(repetition) must stay within budget")
        check(
            monitor.recordObservation(snapshot: unchanged, screenshotPNG: nil) == .proceed,
            "unchanged post-action observation \(repetition) must stay below warning"
        )
    }
    check(monitor.recordAction() == .proceed, "fifth action must stay within budget")
    check(
        monitor.recordObservation(snapshot: unchanged, screenshotPNG: nil)
            == .warning("界面已连续 5 次没有可确认的变化，请重新定位或更换策略。"),
        "unchanged post-action observations must warn before stopping"
    )
    check(monitor.recordAction() == .proceed, "sixth action must stay within budget")
    check(
        monitor.recordObservation(snapshot: unchanged, screenshotPNG: nil)
            == .stop("执行动作后界面连续 6 次没有可确认的变化，接管已停止。"),
        "repeated unchanged post-action observations must stop takeover"
    )

    var resetMonitor = TakeoverProgressMonitor()
    let changed = progressSnapshot(value: "after")
    _ = resetMonitor.recordObservation(snapshot: unchanged, screenshotPNG: nil)
    for _ in 1...5 {
        _ = resetMonitor.recordAction()
        _ = resetMonitor.recordObservation(snapshot: unchanged, screenshotPNG: nil)
    }
    _ = resetMonitor.recordAction()
    check(
        resetMonitor.recordObservation(snapshot: changed, screenshotPNG: nil) == .proceed,
        "a changed observation must reset the no-progress counter"
    )

    var budget = TakeoverProgressMonitor()
    for _ in 1...60 { check(budget.recordAction() == .proceed, "action budget") }
    check(
        budget.recordAction() == .stop("连续操作已达到 60 次，接管已停止以避免失控。"),
        "action budget must reject additional work"
    )

    let semantic = progressSnapshot(value: "static semantics")
    let whitePNG = progressPNG(Array(repeating: 0xFF, count: 256))
    var oneDarkCell = Array(repeating: UInt8(0xFF), count: 256)
    oneDarkCell[0] = 0
    let oneDarkCellPNG = progressPNG(oneDarkCell)
    var changedRegion = Array(repeating: UInt8(0xFF), count: 256)
    for index in 0..<64 { changedRegion[index] = 0 }
    let changedRegionPNG = progressPNG(changedRegion)
    var decodedPNGMonitor = TakeoverProgressMonitor()
    _ = decodedPNGMonitor.recordObservation(snapshot: semantic, screenshotPNG: whitePNG)
    for _ in 1...4 {
        _ = decodedPNGMonitor.recordAction()
        _ = decodedPNGMonitor.recordObservation(snapshot: semantic, screenshotPNG: oneDarkCellPNG)
    }
    _ = decodedPNGMonitor.recordAction()
    check(decodedPNGMonitor.recordObservation(snapshot: semantic, screenshotPNG: oneDarkCellPNG)
        == .warning("界面已连续 5 次没有可确认的变化，请重新定位或更换策略。"),
        "a single dark cell on a decoded white PNG must count as visual jitter")
    _ = decodedPNGMonitor.recordAction()
    check(
        decodedPNGMonitor.recordObservation(snapshot: semantic, screenshotPNG: changedRegionPNG) == .proceed,
        "a clearly changed region in a decoded PNG must reset no-progress detection"
    )

    var observeLoop = TakeoverProgressMonitor()
    check(observeLoop.recordObservation(snapshot: semantic, screenshotPNG: whitePNG) == .proceed, "first loop observation")
    for _ in 1...10 {
        check(observeLoop.recordObservation(snapshot: semantic, screenshotPNG: whitePNG) == .proceed, "loop observation")
    }
    check(
        observeLoop.recordObservation(snapshot: semantic, screenshotPNG: whitePNG)
            == .warning("界面已连续 11 次没有可确认的变化，请重新定位或更换策略。"),
        "repeated observe-only loops must warn before the observation budget is exhausted"
    )
    check(
        observeLoop.recordObservation(snapshot: semantic, screenshotPNG: whitePNG)
            == .stop("界面连续 12 次没有可确认的变化，接管已停止。"),
        "repeated observe-only loops must stop without waiting for an action"
    )

    var unavailableLoop = TakeoverProgressMonitor()
    check(unavailableLoop.recordObservation(snapshot: nil, screenshotPNG: Data()) == .proceed, "first unavailable observation")
    check(unavailableLoop.recordObservation(snapshot: nil, screenshotPNG: Data())
        == .warning("已连续 2 次没有取得有效界面，请等待加载或检查窗口状态。"),
        "unavailable observations must warn before stopping")
    check(unavailableLoop.recordObservation(snapshot: nil, screenshotPNG: Data())
        == .stop("连续 3 次无法取得有效界面，接管已停止。"),
        "unavailable observations must stop takeover")
}

private func progressSnapshot(value: String?) -> SemanticSnapshot {
    SemanticSnapshot(
        applicationName: "Messages",
        windowTitle: "Conversation",
        elements: [
            SemanticElement(
                id: "e1",
                role: .textField,
                label: "Message",
                value: value,
                frame: SemanticRect(x: 100, y: 700, width: 700, height: 80),
                isEnabled: true
            )
        ]
    )
}

private func progressPNG(_ luminance: [UInt8]) -> Data {
    precondition(luminance.count == 256)
    var pixels = luminance
    let image = pixels.withUnsafeMutableBytes { buffer -> CGImage in
        guard let baseAddress = buffer.baseAddress,
              let context = CGContext(
                data: baseAddress,
                width: 16,
                height: 16,
                bitsPerComponent: 8,
                bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ),
              let image = context.makeImage() else {
            fatalError("Unable to create progress-check image")
        }
        return image
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { fatalError("Unable to create PNG destination") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Unable to encode progress-check PNG")
    }
    return data as Data
}
