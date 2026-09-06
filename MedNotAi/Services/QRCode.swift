import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Генерация QR-кодов для промокодов.
///
/// В QR кладётся ссылка `mednoteai://promo/XXXXX-…`. Встроенный сканер
/// сразу активирует подписку; системная «Камера» открывает приложение
/// и передаёт код через `onOpenURL`.
enum QRCode {

    private static let context = CIContext()

    /// Рисует QR-код. `scale` задаёт размер модуля, чтобы код не размывался при увеличении.
    static func cgImage(for text: String, scale: CGFloat = 12) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // Высокий уровень коррекции: код читается, даже если часть закрыта пальцем.
        filter.correctionLevel = "H"

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }

    static func image(for text: String, scale: CGFloat = 12) -> Image? {
        guard let cgImage = cgImage(for: text, scale: scale) else { return nil }
        #if canImport(UIKit)
        return Image(uiImage: UIImage(cgImage: cgImage))
        #else
        return Image(nsImage: NSImage(cgImage: cgImage,
                                      size: NSSize(width: cgImage.width, height: cgImage.height)))
        #endif
    }

    /// Ссылка, которую кладём в QR: открывает приложение и сразу несёт код.
    static func payload(for code: String) -> String {
        let formatted = PromoCodeService.format(PromoCodeService.normalize(code))
        return "mednoteai://promo/\(formatted)"
    }

    /// Достаёт промокод из содержимого QR-кода: принимает и «голый» код,
    /// и ссылку вида `mednoteai://promo/XXXXX-XXXXX-XXXXX-XXXXX`.
    static func promoCode(from payload: String) -> String? {
        let candidate: String
        if let url = URL(string: payload), url.scheme?.lowercased() == "mednoteai" {
            candidate = url.lastPathComponent
        } else {
            candidate = payload
        }
        let normalized = PromoCodeService.normalize(candidate)
        return normalized.isEmpty ? nil : normalized
    }
}

// MARK: - Картинка QR-кода

struct QRCodeImage: View {
    let text: String
    var size: CGFloat = 180

    var body: some View {
        Group {
            if let image = QRCode.image(for: text) {
                image
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .padding(10)
        // Белая подложка обязательна: по тёмной теме сканеры код не различают.
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("QR-код промокода")
    }
}
