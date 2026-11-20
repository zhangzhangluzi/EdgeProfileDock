import AppKit
import ImageIO

enum ProfileArtwork {
    private static let colors: [NSColor] = [
        NSColor(srgbRed: 0.23, green: 0.38, blue: 0.71, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.47, blue: 0.39, alpha: 1),
        NSColor(srgbRed: 0.66, green: 0.31, blue: 0.21, alpha: 1),
        NSColor(srgbRed: 0.43, green: 0.31, blue: 0.66, alpha: 1)
    ]

    static func color(for profile: EdgeProfile) -> NSColor {
        let hash = profile.id.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return colors[Int(hash % UInt32(colors.count))]
    }

    static func initial(for profile: EdgeProfile) -> String {
        profile.displayName.first.map { String($0).uppercased() } ?? "E"
    }

    static func portrait(for profile: EdgeProfile, pixels: Int) -> NSImage? {
        guard let url = profile.avatarURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixels
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// 返回是否实际使用了本地头像，即使缓存图损坏也能生成启动器。
    static func writeIcon(for profile: EdgeProfile, to destination: URL) throws -> Bool {
        let avatar = portrait(for: profile, pixels: 384)
        let color = color(for: profile)
        let iconset = FileManager.default.temporaryDirectory
            .appendingPathComponent("epd-icon-\(UUID().uuidString).iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconset) }

        for (edge, name) in [(64, "32x32@2x"), (128, "128x128"), (256, "256x256"), (512, "512x512")] {
            guard let png = render(edge: edge, color: color, avatar: avatar, profile: profile) else {
                throw LauncherBuilderError.writeFailed("无法绘制资料图标。")
            }
            try png.write(to: iconset.appendingPathComponent("icon_\(name).png"))
        }

        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        convert.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
        try convert.run()
        convert.waitUntilExit()
        guard convert.terminationStatus == 0 else {
            throw LauncherBuilderError.writeFailed("无法写入资料图标。")
        }
        return avatar != nil
    }

    private static func render(edge: Int, color: NSColor, avatar: NSImage?, profile: EdgeProfile) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let scale = CGFloat(edge) / 512
        context.cgContext.clear(CGRect(x: 0, y: 0, width: edge, height: edge))
        context.cgContext.scaleBy(x: scale, y: scale)

        let plate = NSBezierPath(roundedRect: NSRect(x: 35, y: 35, width: 442, height: 442), xRadius: 105, yRadius: 105)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowBlurRadius = 15
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        shadow.set()
        NSColor.white.setFill()
        plate.fill()
        NSGraphicsContext.restoreGraphicsState()
        let lightGray = NSColor(srgbRed: 0.929, green: 0.942, blue: 0.960, alpha: 1)
        NSGradient(starting: lightGray, ending: .white)?.draw(in: plate, angle: 90)
        NSColor.black.withAlphaComponent(0.10).setStroke()
        plate.lineWidth = 2
        plate.stroke()

        let circle = NSRect(x: 91, y: 91, width: 330, height: 330)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: circle.insetBy(dx: -7, dy: -7)).fill()
        if let avatar {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: circle).addClip()
            let ratio = max(circle.width / avatar.size.width, circle.height / avatar.size.height)
            let width = avatar.size.width * ratio
            let height = avatar.size.height * ratio
            avatar.draw(
                in: NSRect(x: circle.midX - width / 2, y: circle.midY - height / 2, width: width, height: height),
                from: .zero, operation: .sourceOver, fraction: 1
            )
            NSGraphicsContext.restoreGraphicsState()
        } else {
            color.withAlphaComponent(0.12).setFill()
            NSBezierPath(ovalIn: circle).fill()
            draw(initial(for: profile), size: 176, color: color, centeredAt: NSPoint(x: 256, y: 260))
        }
        let border = NSBezierPath(ovalIn: circle)
        NSColor.black.withAlphaComponent(0.09).setStroke()
        border.lineWidth = 3
        border.stroke()

        if profile.browser == .edgeBeta {
            let badge = NSBezierPath(ovalIn: NSRect(x: 344, y: 79, width: 85, height: 85))
            NSColor(srgbRed: 0.16, green: 0.20, blue: 0.28, alpha: 1).setFill()
            badge.fill()
            NSColor.white.setStroke()
            badge.lineWidth = 5
            badge.stroke()
            draw("β", size: 56, color: .white, centeredAt: NSPoint(x: 386.5, y: 126))
        }

        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func draw(_ label: String, size: CGFloat, color: NSColor, centeredAt center: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color
        ]
        let text = label as NSString
        let box = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: center.x - box.width / 2, y: center.y - box.height / 2), withAttributes: attributes)
    }
}
