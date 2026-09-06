import Foundation
import CryptoKit

/// Что даёт промокод.
enum PromoBenefit: Equatable, Hashable {
    /// Полный доступ навсегда.
    case unlimited
    /// Полный доступ на указанное число дней.
    case days(Int)

    var title: String {
        switch self {
        case .unlimited: "Безлимитный доступ"
        case .days(let d): "Доступ на \(pluralRu(d, "день", "дня", "дней"))"
        }
    }

    var shortTitle: String {
        switch self {
        case .unlimited: "навсегда"
        case .days(let d): "\(d) дн."
        }
    }
}

/// Расшифрованный промокод.
struct PromoCode: Equatable {
    let benefit: PromoBenefit
    /// До какой даты код можно активировать. `nil` — бессрочно.
    let redeemableUntil: Date?
    /// Случайный номер выпуска, различает коды с одинаковыми условиями.
    let serial: UInt32
    /// Канонический вид без дефисов — по нему проверяем повторную активацию.
    let normalized: String

    var formatted: String { PromoCodeService.format(normalized) }
}

enum PromoCodeError: LocalizedError, Equatable {
    case malformed
    case invalid
    case expired(Date)
    case alreadyUsed

    var errorDescription: String? {
        switch self {
        case .malformed: "Код введён не полностью или содержит лишние символы."
        case .invalid: "Такого кода не существует. Проверьте символы и попробуйте снова."
        case .expired(let date): "Срок активации кода истёк \(date.localized(Date.FormatStyle(date: .abbreviated, time: .omitted)))."
        case .alreadyUsed: "Этот код одноразовый и уже был активирован."
        }
    }
}

/// Генерация и проверка промокодов без сервера.
///
/// Код — это упакованные условия доступа плюс усечённая подпись HMAC-SHA256.
/// Приложение проверяет подпись локально, поэтому активация работает офлайн
/// и не требует заранее зашитого списка кодов: их можно выпустить сколько угодно.
///
/// ВАЖНО: секрет подписи лежит внутри приложения, значит теоретически его можно
/// извлечь из бинарника и выпускать коды в обход вас. Для раздачи промокодов
/// студентам этого достаточно; если промокоды станут каналом продаж,
/// проверку стоит перенести на сервер (см. `PromoCodeService.verify`).
enum PromoCodeService {

    // MARK: - Настройки выпуска

    /// Секрет подписи. Смените перед публикацией — все ранее выпущенные коды при этом перестанут работать.
    private static let signingSecret = SymmetricKey(data: Data([
        0xe5, 0xf6, 0x62, 0x09, 0xaa, 0x90, 0x0d, 0x03,
        0xc2, 0x0b, 0x38, 0x3c, 0x49, 0x4e, 0x78, 0x5e,
        0x14, 0x21, 0x08, 0x3c, 0x94, 0x0d, 0x7f, 0x04,
        0x6e, 0x67, 0xf3, 0x5e, 0xde, 0x54, 0x8b, 0x00
    ]))

    /// SHA-256 от кода доступа к генератору. По умолчанию это `mednote-admin-2026`.
    /// Замените хеш, чтобы задать свой код (`echo -n "ваш-код" | shasum -a 256`).
    private static let studioPasscodeHash = "27290d19fdfa575eb741eeb62acae261de51889702dbc0cdaa7abb6919aa00f7"

    private static let version: UInt8 = 1
    /// Случайный номер выпуска: он же соль маскировки, поэтому коды не похожи друг на друга.
    private static let serialSize = 3
    /// Условия доступа: версия и тип (1 байт), срок доступа и дедлайн активации (по 12 бит).
    private static let dataSize = 4
    /// Подпись занимает остаток кода — 44 из 48 бит участвуют в проверке.
    private static let tagSize = 6
    private static let codeLength = 20
    private static let groupSize = 5
    /// 12 бит на каждое из полей срока.
    private static let maxDays = 4095

    /// Алфавит Crockford Base32: без I, L, O и U, чтобы код нельзя было прочитать двояко.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Начало отсчёта для срока активации.
    private static let referenceDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 1_767_225_600)
    }()

    // MARK: - Генерация

    /// Выпускает новый код. Каждый вызов даёт новый серийный номер.
    static func generate(benefit: PromoBenefit, redeemableUntil: Date? = nil) -> String {
        let kind: UInt8
        let days: Int
        switch benefit {
        case .unlimited:
            kind = 0
            days = 0
        case .days(let value):
            kind = 1
            days = min(max(1, value), maxDays)
        }
        let deadline = redeemableUntil.map { dayOffset(for: $0) } ?? 0

        var data = [UInt8](repeating: 0, count: dataSize)
        data[0] = (version << 4) | kind
        data[1] = UInt8(days >> 4)
        data[2] = UInt8(((days & 0x0F) << 4) | (deadline >> 8))
        data[3] = UInt8(deadline & 0xFF)

        let serial = (0..<serialSize).map { _ in UInt8.random(in: 0...UInt8.max) }
        let masked = zip(data, mask(for: serial)).map(^)
        let signed = serial + masked
        return format(String(symbols(from: signed + tag(for: signed)).map { alphabet[$0] }))
    }

    /// Выпускает сразу партию кодов без повторов.
    static func generateBatch(count: Int, benefit: PromoBenefit, redeemableUntil: Date? = nil) -> [String] {
        var codes: [String] = []
        var seen = Set<String>()
        // Серийный номер занимает 24 бита, повтор практически невероятен,
        // но цикл без ограничения — это потенциальное зависание интерфейса.
        var attemptsLeft = max(count * 4, count + 32)
        while codes.count < count, attemptsLeft > 0 {
            attemptsLeft -= 1
            let code = generate(benefit: benefit, redeemableUntil: redeemableUntil)
            guard seen.insert(code).inserted else { continue }
            codes.append(code)
        }
        return codes
    }

    // MARK: - Проверка

    /// Проверяет код и возвращает его условия. Активацию (учёт уже использованных)
    /// выполняет `AppSettings.redeem(_:)` — здесь только подпись и срок.
    static func verify(_ raw: String, now: Date = Date()) -> Result<PromoCode, PromoCodeError> {
        let normalized = normalize(raw)
        guard normalized.count == codeLength else { return .failure(.malformed) }

        var received: [Int] = []
        for character in normalized {
            guard let value = alphabet.firstIndex(of: character) else { return .failure(.malformed) }
            received.append(value)
        }

        // Восстанавливаем подписанную часть и заново собираем код целиком:
        // если отличается хоть один символ, подпись не сойдётся.
        let signed = leadingBytes(received, count: serialSize + dataSize)
        guard constantTimeEquals(symbols(from: signed + tag(for: signed)), received) else {
            return .failure(.invalid)
        }

        let serial = Array(signed[0..<serialSize])
        let data = zip(signed[serialSize...], mask(for: serial)).map(^)
        guard data[0] >> 4 == version else { return .failure(.invalid) }

        let days = Int(data[1]) << 4 | Int(data[2] >> 4)
        let benefit: PromoBenefit
        switch data[0] & 0x0F {
        case 0 where days == 0:
            benefit = .unlimited
        case 1 where days > 0:
            benefit = .days(days)
        default:
            return .failure(.invalid)
        }

        var redeemableUntil: Date?
        let deadline = Int(data[2] & 0x0F) << 8 | Int(data[3])
        if deadline > 0 {
            let date = endOfDay(offset: deadline)
            if now > date { return .failure(.expired(date)) }
            redeemableUntil = date
        }

        let issue = serial.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return .success(PromoCode(benefit: benefit, redeemableUntil: redeemableUntil,
                                  serial: issue, normalized: normalized))
    }

    /// Доступ к генератору промокодов.
    static func isStudioPasscodeValid(_ passcode: String) -> Bool {
        let trimmed = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() == studioPasscodeHash
    }

    // MARK: - Формат

    /// Приводит ввод к каноническому виду: убирает разделители и похожие символы.
    static func normalize(_ raw: String) -> String {
        var result = ""
        for character in raw.uppercased() {
            switch character {
            case "O": result.append("0")
            case "I", "L": result.append("1")
            case "U": result.append("V")
            case let c where alphabet.contains(c): result.append(c)
            default: continue
            }
        }
        return result
    }

    /// Разбивает код на группы по пять символов.
    static func format(_ normalized: String) -> String {
        stride(from: 0, to: normalized.count, by: groupSize).map { offset in
            let start = normalized.index(normalized.startIndex, offsetBy: offset)
            let end = normalized.index(start, offsetBy: min(groupSize, normalized.count - offset))
            return String(normalized[start..<end])
        }
        .joined(separator: "-")
    }

    // MARK: - Внутреннее

    private static func tag(for payload: [UInt8]) -> [UInt8] {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload), using: signingSecret)
        return Array(mac.prefix(tagSize))
    }

    /// Гамма для маскировки условий: без неё все бессрочные коды начинались бы одинаково.
    private static func mask(for serial: [UInt8]) -> [UInt8] {
        let mac = HMAC<SHA256>.authenticationCode(for: Data([0xA5] + serial), using: signingSecret)
        return Array(mac.prefix(dataSize))
    }

    private static func constantTimeEquals(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff = 0
        for (l, r) in zip(lhs, rhs) { diff |= l ^ r }
        return diff == 0
    }

    private static func dayOffset(for date: Date) -> Int {
        let days = Calendar(identifier: .gregorian)
            .dateComponents([.day], from: referenceDate, to: date).day ?? 0
        return min(max(1, days), maxDays)
    }

    private static func endOfDay(offset: Int) -> Date {
        let start = referenceDate.addingTimeInterval(TimeInterval(offset) * 86_400)
        return start.addingTimeInterval(86_400 - 1)
    }

    /// Берёт первые `codeLength * 5` бит и режет их на пятибитные символы.
    /// Подписи достаётся 44 бита: так каждый символ кода несёт данные
    /// и ни один из них не оказывается предсказуемым.
    private static func symbols(from bytes: [UInt8]) -> [Int] {
        var result: [Int] = []
        var buffer = 0
        var bits = 0
        var index = 0
        while result.count < codeLength {
            if bits < 5 {
                buffer = (buffer << 8) | (index < bytes.count ? Int(bytes[index]) : 0)
                bits += 8
                index += 1
            }
            bits -= 5
            result.append((buffer >> bits) & 0x1F)
            buffer &= (1 << bits) - 1
        }
        return result
    }

    private static func leadingBytes(_ symbols: [Int], count: Int) -> [UInt8] {
        var result: [UInt8] = []
        var buffer = 0
        var bits = 0
        for symbol in symbols where result.count < count {
            buffer = (buffer << 5) | symbol
            bits += 5
            if bits >= 8 {
                bits -= 8
                result.append(UInt8((buffer >> bits) & 0xFF))
                buffer &= (1 << bits) - 1
            }
        }
        return result
    }
}
