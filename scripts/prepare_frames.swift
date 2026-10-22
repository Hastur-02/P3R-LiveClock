#!/usr/bin/env swift
import AVFoundation
import AppKit
import CoreImage

// 从横屏原片生成原生复杂功能使用的高清帧序列。
// 当前坐标仅针对 Series 11 46mm 的模块化中央位置：中心比屏幕中心低 16 点。
guard CommandLine.arguments.count == 3 else { fatalError("用法：prepare_frames.swift 视频 输出目录") }
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let asset = AVURLAsset(url: input)
let duration = try await asset.load(.duration).seconds
let env = ProcessInfo.processInfo.environment
/// 帧率：默认 12 fps。帧数 = 时长 × 帧率，帧越多，表盘进程里解码后的内存越大（80 帧约 80 MB）。
let fps = Double(env["FPS"] ?? "12") ?? 12
let count = Int(ceil(duration * fps))
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
// 从横屏原片直接重新裁切。已裁成竖屏的输入缺少左侧内容，拒绝通过补边伪造。
let scale = 2.0
/// 从横屏原片里截取竖条的左边缘（原片像素）。默认 180 是官网开场视频的取景，换视频时按画面调整。
let cropX = Double(env["CROP_X"] ?? "180") ?? 180
let glassRect = CGRect(x: 103, y: 55, width: 93, height: 35)
let drawGlass = env["GLASS"] == "1"
let ciContext = CIContext(options: [.cacheIntermediates: false])
generator.maximumSize = CGSize(width: 1920, height: 1080)
for index in 0..<count {
    let time = CMTime(seconds: Double(index) * duration / Double(count), preferredTimescale: 60000)
    let (original, _) = try await generator.image(at: time)
    let cropWidth = Double(original.height) * 208 / 248
    guard Double(original.width) >= cropX + cropWidth,
          let image = original.cropping(to: CGRect(x: cropX, y: 0, width: cropWidth, height: Double(original.height))) else {
        fatalError("视频宽度不够：需要横屏视频，且 CROP_X + 截取宽度不能超出画面。")
    }
    guard let context = CGContext(data: nil, width: 416, height: 600, bitsPerComponent: 8, bytesPerRow: 416 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("无法创建画布") }
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 208, height: 300))
    // 画布上下预留量只用于抵消原生组件位置，实际屏幕内每个像素都来自原片裁切。
    context.draw(image, in: CGRect(x: 0, y: 42, width: 208, height: 248))
    // 玻璃外观随每帧背景重新采样；这是预渲染材质，不是宿主中的实时 Liquid Glass。
    // 方案 G 起时间改为右侧竖排、不再需要底板，默认不画；GLASS=1 时恢复旧的右下玻璃底板。
    if drawGlass, let background = context.makeImage() {
        let pixelRect = glassRect.applying(CGAffineTransform(scaleX: scale, y: scale))
        let blurred = CIImage(cgImage: background).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 5])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.8, kCIInputBrightnessKey: 0.045])
        let path = CGPath(roundedRect: glassRect, cornerWidth: 15, cornerHeight: 15, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let sample = ciContext.createCGImage(blurred, from: pixelRect) { context.draw(sample, in: glassRect) }
        let colors = [CGColor(gray: 1, alpha: 0.12), CGColor(red: 0.06, green: 0.12, blue: 0.34, alpha: 0.09)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: glassRect.midX, y: glassRect.maxY), end: CGPoint(x: glassRect.midX, y: glassRect.minY), options: [])
        context.restoreGState()
        context.addPath(path)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.3))
        context.setLineWidth(0.5)
        context.strokePath()
    }
    let fullImage = context.makeImage()!
    if index == 0 {
        let poster = NSBitmapImageRep(cgImage: fullImage)
        try poster.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("poster-retina.png"))
    }
    // 保留双倍像素。显示端先用静帧初始化像素密度，再切换到动画。
    let bitmap = NSBitmapImageRep(cgImage: fullImage)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(String(format: "p3r-%04d.png", index)))
}
let manifest: [String: Any] = ["frameCount": count, "duration": duration, "fps": fps, "pixelWidth": 416, "pixelHeight": 600, "scale": 2, "visiblePixelWidth": 416, "visiblePixelHeight": 496, "posterScale": 2, "posterPixelWidth": 416, "posterPixelHeight": 600, "animationResampling": "source-crop-high-quality", "sourceCropX": cropX, "source": input.lastPathComponent, "edgeFill": "none", "topPadding": 10, "bottomPadding": 42, "clockPresentation": drawGlass ? "bottom-right-component" : "right-column-menu-stack", "glassRectOnScreenPoints": drawGlass ? [103, 200, 93, 35] : [], "glassRendering": drawGlass ? "pre-rendered-background-sampling" : "none"]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("frames.json"))
print("已转换 \(count) 帧，时长 \(duration) 秒。")
