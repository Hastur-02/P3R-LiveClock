import ClockKit
import CoreText
import UIKit

/// 时间单独交给小尺寸复杂功能的分钟时间线，避免每分钟复制整套动画。
///
/// 外观为方案 G「菜单竖排」（见 design/README.md）：右侧蓝色水面上自上而下四行——时、分、日期、星期，
/// 仿 P3R 主菜单：SF Black 斜体，亮水色半透明，深蓝错位影子；行距小于字高互相压叠，倾角正负交替。
///
/// 实测（design/README.md「可画区域实验」）：这个复杂功能的图以右下槽位中心 (172, 216.7) 为中心
/// 原样绘制，不缩放、不裁切，并且盖在中央动画上面。所以图做成 144×434 点、以槽位中心对称，
/// 就能覆盖屏幕 x 100–208、整屏高。下面的坐标都按屏幕点写（y 向下），画图时再换算到图内。
/// 版式参数与 design/clock_options.swift 的 ColumnStyle 默认值一致，由 check_bounds.py 卡在
/// 「笔画不碰人物、不出屏幕圆角」的上限。
enum GlassClock {
    static let identifier = "glass-clock"

    private static let slotCenter = CGPoint(x: 172, y: 216.7)
    private static let imageSize = CGSize(width: 144, height: 434)
    /// 图左上角在屏幕上的位置
    private static let origin = CGPoint(x: slotCenter.x - imageSize.width / 2, y: slotCenter.y - imageSize.height / 2)

    // 版式（屏幕点）：时分 57 号、日期星期 26 号，首行中心 y=100，右缘 x=203。
    // 字号是越界检查对全年所有时、分、日期、星期的叠加图卡出的上限（UNION=1 clock_options.swift），
    // 58 号时「2」的左下角会进入离人物 3 点的安全边距。
    private static let big: CGFloat = 57, small: CGFloat = 26, top: CGFloat = 100, right: CGFloat = 203
    private static let overlap: CGFloat = 0.55      // 时、分中心间距 = big × overlap，小于字高所以压叠
    private static let skewDeg: CGFloat = 16
    private static let cyan = UIColor(red: 0x8B / 255.0, green: 0xE8 / 255.0, blue: 0xF5 / 255.0, alpha: 0.82)
    private static let shadow = UIColor(red: 0x16 / 255.0, green: 0x3F / 255.0, blue: 0xB0 / 255.0, alpha: 0.85)

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "M/d"; return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE"; return f
    }()

    static func template(at date: Date) -> CLKComplicationTemplate? {
        guard let image = render(at: date) else { return nil }
        let provider = CLKFullColorImageProvider(fullColorImage: image)
        provider.accessibilityLabel = timeFormatter.string(from: date)
        // 非公开字段：关掉系统缩放与圆形遮罩，图才能按原尺寸超出槽位绘制。
        provider.setValue(false, forKey: "applyScalingAndCircularMasking")
        return CLKComplicationTemplateGraphicCircularImage(imageProvider: provider)
    }

    static func nextMinute(after date: Date) -> Date {
        Calendar.autoupdatingCurrent.dateInterval(of: .minute, for: date)!.end
    }

    // MARK: - 绘制

    private static func render(at date: Date) -> UIImage? {
        let scale: CGFloat = 2
        let w = Int(imageSize.width * scale), h = Int(imageSize.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        let hm = timeFormatter.string(from: date).split(separator: ":").map(String.init)
        let ys = [top, top + big * overlap,
                  top + big * overlap + big * 0.38 + small * 0.62,
                  top + big * overlap + big * 0.38 + small * 1.67]
        // 文字、字号、倾角、字距、右缘内缩
        let rows: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (hm[0], big, 10, 0, 2), (hm[1], big, -8, 0, 0),
            (dateFormatter.string(from: date), small, 8, 0.5, 3),
            (weekdayFormatter.string(from: date).uppercased(), small, -7, 1.0, 10)]
        for (i, (text, size, deg, kern, inset)) in rows.enumerated() {
            let font = tabular(UIFont.systemFont(ofSize: size, weight: .black, width: .standard))
            let width = lineWidth(text, font: font, kern: kern)
            let k = max(size / 60, 0.45)
            let center = CGPoint(x: right - inset - width / 2, y: ys[i])
            drawLine(ctx, text, font: font, color: shadow, center: center, offset: CGSize(width: 2.8 * k, height: 3.6 * k), deg: deg, kern: kern)
            drawLine(ctx, text, font: font, color: cyan, center: center, offset: .zero, deg: deg, kern: kern)
        }
        guard let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    /// 等宽数字：SF 默认是比例数字，「1」比「0」窄。等宽后每分钟行宽一致，排版不随时间左右跳，
    /// 宽度上限也确定。
    private static func tabular(_ font: UIFont) -> UIFont {
        let d = font.fontDescriptor.addingAttributes([.featureSettings: [[UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                                                                          UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]]])
        return UIFont(descriptor: d, size: font.pointSize)
    }

    private static func lineWidth(_ text: String, font: UIFont, kern: CGFloat) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .kern: kern]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - kern
    }

    /// 绕中心旋转、整体错切成斜体的一行字。center 是屏幕点（y 向下）。
    private static func drawLine(_ ctx: CGContext, _ text: String, font: UIFont, color: UIColor, center: CGPoint,
                                 offset: CGSize, deg: CGFloat, kern: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .kern: kern]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - kern
        let skew = tan(skewDeg * .pi / 180)
        // 屏幕点 → 图内点，再翻成 CoreGraphics 的 y 向上
        let x = center.x + offset.width - origin.x
        let y = imageSize.height - (center.y + offset.height - origin.y)
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        ctx.rotate(by: deg * .pi / 180)
        ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: skew, d: 1, tx: 0, ty: 0)
        ctx.textPosition = CGPoint(x: -width / 2 - font.capHeight / 2 * skew, y: -font.capHeight / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
