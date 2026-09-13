import Foundation
import PDFKit
import UniformTypeIdentifiers
import Compression
#if canImport(Vision)
import Vision
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct ImportedLecture: Sendable {
    var title: String
    var text: String
    var sourceName: String
}

enum LectureImportError: LocalizedError {
    case empty
    case unreadable

    var errorDescription: String? {
        switch self {
        case .empty: "В файле нет текста, который можно разобрать."
        case .unreadable: "Этот формат не удалось прочитать. Сохраните слайды в PDF или сделайте фото."
        }
    }
}

enum LectureImport {
    static let allowedTypes: [UTType] = {
        var types: [UTType] = [.pdf, .png, .jpeg, .heic, .image]
        if let pptx = UTType(filenameExtension: "pptx") { types.append(pptx) }
        if let ppt = UTType(filenameExtension: "ppt") { types.append(ppt) }
        return types
    }()

    static func load(urls: [URL]) async throws -> ImportedLecture {
        var chunks: [String] = []
        var names: [String] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            names.append(url.lastPathComponent)
            if let text = try? await extract(from: url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append("## \(url.deletingPathExtension().lastPathComponent)\n\n\(text)")
            }
        }
        let body = chunks.joined(separator: "\n\n")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LectureImportError.empty
        }
        let title = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent
            : "Лекция из \(urls.count) файлов"
        return ImportedLecture(title: title, text: body, sourceName: names.joined(separator: ", "))
    }

    static func load(images: [Data], names: [String] = []) async throws -> ImportedLecture {
        var pages: [String] = []
        for (index, data) in images.enumerated() {
            guard let text = await recognize(imageData: data) else { continue }
            let label = names.indices.contains(index) ? names[index] : "Слайд \(index + 1)"
            pages.append("## \(label)\n\n\(text)")
        }
        let body = pages.joined(separator: "\n\n")
        guard !body.isEmpty else { throw LectureImportError.empty }
        return ImportedLecture(title: "Слайды с фото", text: body, sourceName: "Фото слайдов")
    }

    private static func extract(from url: URL) async throws -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return pdfText(url)
        case "png", "jpg", "jpeg", "heic", "heif", "webp", "tif", "tiff":
            let data = try Data(contentsOf: url)
            return await recognize(imageData: data) ?? ""
        case "pptx", "ppt":
            return try pptxText(url)
        default:
            if let pdf = PDFDocument(url: url) {
                return pdfText(document: pdf)
            }
            throw LectureImportError.unreadable
        }
    }

    private static func pdfText(_ url: URL) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        return pdfText(document: document)
    }

    private static func pdfText(document: PDFDocument) -> String {
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let cleaned = OCRCleanup.keepUseful(page.string ?? "")
            if cleaned.isEmpty { continue }
            pages.append("### Страница \(index + 1)\n\n\(cleaned)")
        }
        return pages.joined(separator: "\n\n")
    }

    private static func pptxText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let files = ZipReader.extract(data, matching: "ppt/slides/slide")
        guard !files.isEmpty else { throw LectureImportError.unreadable }
        let slides = files
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .enumerated()
            .compactMap { index, file -> String? in
                let text = OCRCleanup.keepUseful(XMLText.plain(from: file.data))
                guard !text.isEmpty else { return nil }
                return "### Слайд \(index + 1)\n\n\(text)"
            }
        if slides.isEmpty { throw LectureImportError.empty }
        return slides.joined(separator: "\n\n")
    }

    private static func recognize(imageData: Data) async -> String? {
        #if canImport(Vision)
        guard let cgImage = cgImage(from: imageData) else { return nil }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let fragments = observations.compactMap { observation -> OCRFragment? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return OCRFragment(
                        text: candidate.string,
                        confidence: candidate.confidence,
                        box: observation.boundingBox
                    )
                }
                continuation.resume(returning: OCRCleanup.keepUseful(fragments: fragments))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ru-RU", "en-US", "kk-KZ", "tr-TR"]
            // Мелкий интерфейс (часы, лайки, кнопки) обычно ниже 2% высоты кадра.
            request.minimumTextHeight = 0.028
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
        #else
        return nil
        #endif
    }

    private static func cgImage(from data: Data) -> CGImage? {
        #if canImport(UIKit)
        return UIImage(data: data)?.cgImage
        #elseif canImport(AppKit)
        return NSImage(data: data).flatMap { image in
            var rect = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        #else
        return nil
        #endif
    }
}

// MARK: - Отбор полезного текста

#if canImport(Vision)
struct OCRFragment: Sendable {
    let text: String
    let confidence: Float
    let box: CGRect
}
#endif

/// Убирает интерфейсный мусор OCR: часы, лайки, кнопки, обрывки букв.
/// Связные предложения и заголовки слайда остаются.
enum OCRCleanup {
    static func keepUseful(_ raw: String) -> String {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return join(lines.filter { classify($0).isUseful })
    }

    #if canImport(Vision)
    static func keepUseful(fragments: [OCRFragment]) -> String? {
        let ordered = fragments.sorted { lhs, rhs in
            if abs(lhs.box.midY - rhs.box.midY) > 0.02 {
                return lhs.box.midY > rhs.box.midY
            }
            return lhs.box.minX < rhs.box.minX
        }

        let useful = ordered.compactMap { fragment -> String? in
            let line = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, isUseful(fragment) else { return nil }
            return line
        }
        let body = join(useful)
        return body.isEmpty ? nil : body
    }

    private static func isUseful(_ fragment: OCRFragment) -> Bool {
        let line = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let verdict = classify(line)
        if verdict == .chrome { return false }
        if fragment.confidence < 0.35, verdict != .sentence { return false }
        if fragment.box.height < 0.018, verdict != .sentence { return false }
        // Часы и иконки статус-бара почти всегда в самой верхней полосе.
        if fragment.box.minY > 0.88, line.count <= 8 { return false }
        // Кнопки и счётчики соцсетей — в нижней кромке кадра.
        if fragment.box.maxY < 0.12, line.count <= 18 { return false }
        return verdict.isUseful
    }
    #endif

    private enum LineKind {
        case sentence
        case heading
        case chrome
        case junk

        var isUseful: Bool {
            self == .sentence || self == .heading
        }
    }

    private static let chromePhrases: Set<String> = [
        "подписаться", "subscribe", "follow", "unfollow",
        "like", "comment", "share", "отправить",
        "нравится", "комментарии", "поделиться",
        "смотреть перевод", "see translation", "перевод",
        "реклама", "sponsored", "продвижение",
        "reels", "explore", "for you", "для вас",
        "главная", "поиск", "профиль",
        "смотреть", "смотреть ещё", "ещё"
    ]

    private static func classify(_ raw: String) -> LineKind {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .junk }

        let folded = fold(line)
        if chromePhrases.contains(folded) { return .chrome }
        if isClock(line) { return .chrome }
        if isHandle(line) { return .chrome }
        if isCounter(line) { return .chrome }
        if isSymbolNoise(line) { return .junk }
        if isAllCapsLatinWatermark(line) { return .chrome }

        let letters = line.filter(\.isLetter)
        let words = line.split { $0.isWhitespace || $0.isNewline }

        if letters.count >= 18 || words.count >= 5 { return .sentence }
        if words.count >= 3, letters.count >= 10 { return .sentence }
        if isLikelyAbbreviation(line) { return .heading }
        if letters.count >= 4, words.count <= 6, !line.contains("_") { return .heading }
        return .junk
    }

    private static func join(_ lines: [String]) -> String {
        var result: [String] = []
        for line in lines {
            let cleaned = line
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if result.last == cleaned { continue }
            result.append(cleaned)
        }
        return result.joined(separator: "\n")
    }

    private static func fold(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isClock(_ line: String) -> Bool {
        line.range(of: #"^\d{1,2}[:.]\d{2}$"#, options: .regularExpression) != nil
    }

    private static func isHandle(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        if compact.hasPrefix("@") { return true }
        // ando_boxing, name.surname — не предложение и не медицинский термин.
        if compact.contains("_"), compact.count <= 32, compact.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) {
            return true
        }
        return false
    }

    private static func isCounter(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        if compact.range(of: #"^\d{1,6}$"#, options: .regularExpression) != nil { return true }
        if compact.range(of: #"^\d+[kкм]?$"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func isSymbolNoise(_ line: String) -> Bool {
        let letters = line.filter(\.isLetter)
        let meaningful = line.filter { $0.isLetter || $0.isNumber }
        if letters.isEmpty, meaningful.count <= 4 { return true }
        if line.count <= 3, letters.count <= 1 { return true }
        return false
    }

    private static func isAllCapsLatinWatermark(_ line: String) -> Bool {
        let words = line.split(whereSeparator: \.isWhitespace)
        guard (1...3).contains(words.count) else { return false }
        let letters = line.filter(\.isLetter)
        guard letters.count >= 4, letters.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return letters.allSatisfy(\.isUppercase)
    }

    private static func isLikelyAbbreviation(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard (2...6).contains(compact.count) else { return false }
        return compact.allSatisfy({ $0.isLetter && $0.isUppercase })
    }
}

// MARK: - Текст из Office XML

enum XMLText {
    static func plain(from data: Data) -> String {
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            return ""
        }
        var text = raw
        text = text.replacingOccurrences(of: "</a:p>", with: "\n")
        text = text.replacingOccurrences(of: "</w:p>", with: "\n")
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#10;", with: "\n")
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Минимальный ZIP (PPTX)

enum ZipReader {
    struct Entry { let name: String; let data: Data }

    static func extract(_ data: Data, matching prefix: String) -> [Entry] {
        var entries: [Entry] = []
        var offset = 0
        let bytes = [UInt8](data)
        while offset + 30 < bytes.count {
            guard u32(bytes, offset) == 0x04034b50 else { break }
            let method = Int(u16(bytes, offset + 8))
            let flags = Int(u16(bytes, offset + 6))
            var compSize = Int(u32(bytes, offset + 18))
            let nameLen = Int(u16(bytes, offset + 26))
            let extraLen = Int(u16(bytes, offset + 28))
            let nameStart = offset + 30
            let nameEnd = nameStart + nameLen
            guard nameEnd + extraLen <= bytes.count else { break }
            let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .utf8) ?? ""
            var payloadStart = nameEnd + extraLen
            if flags & 0x08 != 0, compSize == 0 {
                // Размер после данных — ищем дескриптор, иначе пропускаем архив.
                break
            }
            let payloadEnd = payloadStart + compSize
            guard payloadEnd <= bytes.count else { break }
            if name.hasPrefix(prefix), name.hasSuffix(".xml") {
                let payload = Data(bytes[payloadStart..<payloadEnd])
                if let decoded = decode(payload, method: method) {
                    entries.append(Entry(name: name, data: decoded))
                }
            }
            offset = payloadEnd
        }
        return entries
    }

    private static func decode(_ data: Data, method: Int) -> Data? {
        if method == 0 { return data }
        if method == 8 { return inflate(data) }
        return nil
    }

    private static func inflate(_ source: Data) -> Data? {
        let destinationCapacity = max(source.count * 8, 16_384)
        var destination = Data(count: destinationCapacity)
        let decoded = destination.withUnsafeMutableBytes { dest -> Int in
            source.withUnsafeBytes { src in
                guard let srcPtr = src.bindMemory(to: UInt8.self).baseAddress,
                      let destPtr = dest.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destPtr, destinationCapacity, srcPtr, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard decoded > 0 else { return nil }
        destination.count = decoded
        return destination
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}
