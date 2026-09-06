import AppKit
import CoreGraphics

// Собирает набор иконок приложения из исходного изображения 1024×1024.
// Символ вырезается по маске и заново компонуется поверх фирменного градиента,
// чтобы он стоял ровно по центру и занимал одинаковую долю плитки во всех вариантах.

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: makeicon <source.png> <output-dir>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[2])

let side = 1024
/// Насколько далеко от центра плитки может уходить символ (доля от стороны).
let symbolReach = 0.39
let colorSpace = CGColorSpaceCreateDeviceRGB()
let full = CGRect(x: 0, y: 0, width: side, height: side)

guard let source = NSImage(contentsOfFile: arguments[1])?
    .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("не удалось открыть \(arguments[1])\n".utf8))
    exit(1)
}

func makeContext(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
              space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func write(_ image: CGImage, to name: String) {
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: image.width, height: image.height)
    guard let data = representation.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("не удалось закодировать \(name)\n".utf8))
        exit(1)
    }
    try! data.write(to: outputDirectory.appendingPathComponent(name))
    print("  \(name) — \(image.width)×\(image.height)")
}

// MARK: - Маска символа

// Символ на исходнике белый, фон — насыщенный градиент, поэтому минимальный
// из цветовых каналов надёжно отделяет одно от другого и сохраняет сглаживание.
var pixels = [UInt8](repeating: 0, count: side * side * 4)
pixels.withUnsafeMutableBytes { buffer in
    let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: side * 4, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(source, in: full)
}

let threshold = 120.0
var mask = [UInt8](repeating: 0, count: side * side * 4)
var minColumn = side, maxColumn = 0, minRow = side, maxRow = 0
var mass = 0.0, momentX = 0.0, momentY = 0.0

for row in 0..<side {
    for column in 0..<side {
        let index = row * side + column
        let minimum = Double(min(pixels[index * 4], pixels[index * 4 + 1], pixels[index * 4 + 2]))
        let value = UInt8(max(0, min(1, (minimum - threshold) / (255 - threshold))) * 255)
        mask[index * 4 + 3] = value
        if value > 32 {
            minColumn = min(minColumn, column); maxColumn = max(maxColumn, column)
            minRow = min(minRow, row); maxRow = max(maxRow, row)
            let weight = Double(value) / 255
            mass += weight
            momentX += weight * Double(column)
            momentY += weight * Double(row)
        }
    }
}

let maskImage = mask.withUnsafeMutableBytes { buffer -> CGImage in
    CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
              bytesPerRow: side * 4, space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}

// Опора — центр масс, а не габаритный прямоугольник: тогда крупная страница
// уравновешивает мелкую искру и плитка не выглядит перекошенной.
let centerX = CGFloat(momentX / mass)
let centerYFromTop = CGFloat(momentY / mass)
let reach = max(
    max(centerX - CGFloat(minColumn), CGFloat(maxColumn) - centerX),
    max(centerYFromTop - CGFloat(minRow), CGFloat(maxRow) - centerYFromTop)
)
let scale = CGFloat(side) * symbolReach / reach
let placement = CGRect(x: CGFloat(side) / 2 - centerX * scale,
                       y: CGFloat(side) / 2 + centerYFromTop * scale - CGFloat(side) * scale,
                       width: CGFloat(side) * scale,
                       height: CGFloat(side) * scale)

print("символ: \(maxColumn - minColumn)×\(maxRow - minRow) px, масштаб \(String(format: "%.2f", scale))")

/// Рисует символ поверх произвольной подложки.
func compose(background: (CGContext) -> Void, symbol: (CGContext, CGRect) -> Void) -> CGImage {
    let context = makeContext(side)
    context.interpolationQuality = .high
    background(context)

    context.saveGState()
    context.clip(to: placement, mask: maskImage)
    symbol(context, placement)
    context.restoreGState()
    return context.makeImage()!
}

func brandGradient(_ colors: [CGColor], locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

func fillDiagonal(_ context: CGContext, _ rect: CGRect, _ gradient: CGGradient) {
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY),
                               options: [])
}

// MARK: - Варианты для iOS

let backgroundGradient = brandGradient([
    CGColor(srgbRed: 0.486, green: 0.227, blue: 0.929, alpha: 1),   // #7C3AED
    CGColor(srgbRed: 0.659, green: 0.333, blue: 0.969, alpha: 1),   // #A855F7
    CGColor(srgbRed: 0.925, green: 0.282, blue: 0.600, alpha: 1)    // #EC4899
], locations: [0, 0.55, 1])

let light = compose(background: { context in
    fillDiagonal(context, full, backgroundGradient)
}, symbol: { context, rect in
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(rect)
})
write(light, to: "icon-ios-light.png")

// Тёмный вариант: фон рисует система, символ сохраняет фирменные цвета.
let dark = compose(background: { _ in }, symbol: { context, rect in
    fillDiagonal(context, rect, brandGradient([
        CGColor(srgbRed: 0.753, green: 0.518, blue: 0.988, alpha: 1),
        CGColor(srgbRed: 0.976, green: 0.659, blue: 0.831, alpha: 1)
    ], locations: [0, 1]))
})
write(dark, to: "icon-ios-dark.png")

// Тонированный вариант: систему интересует только яркость, цвет она подставит сама.
let tinted = compose(background: { _ in }, symbol: { context, rect in
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(rect)
})
write(tinted, to: "icon-ios-tinted.png")

// MARK: - macOS

// В доке иконка не во всю плитку: тело занимает ~80% холста и имеет скругление.
func macIcon(_ size: Int) -> CGImage {
    let canvas = CGFloat(size)
    let body = (canvas * 0.8046).rounded()
    let origin = ((canvas - body) / 2).rounded()
    let rect = CGRect(x: origin, y: origin, width: body, height: body)

    let context = makeContext(size)
    context.interpolationQuality = .high
    context.addPath(CGPath(roundedRect: rect, cornerWidth: body * 0.2237, cornerHeight: body * 0.2237, transform: nil))
    context.clip()
    context.draw(light, in: rect)
    return context.makeImage()!
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    write(macIcon(size), to: "icon-mac-\(size).png")
}

print("готово")
