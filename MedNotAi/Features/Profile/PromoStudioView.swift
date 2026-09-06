import SwiftUI

/// Генератор промокодов для владельца приложения.
/// Экран скрыт: открывается семью нажатиями на строку версии в профиле
/// и требует код издателя. Коды выпускаются офлайн, их количество не ограничено.
struct PromoStudioView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var isUnlocked = false
    @State private var passcode = ""
    @State private var passcodeError = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if isUnlocked {
                    generator
                } else {
                    lockScreen
                }
            }
            .navigationTitle(isUnlocked ? "Выпуск промокодов" : "Доступ издателя")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }

    // MARK: - Замок

    private var lockScreen: some View {
        VStack(spacing: 18) {
            GradientIcon(systemName: "lock.shield.fill", size: 76)
            Text("Введите код издателя")
                .font(.title3.bold())
                .foregroundStyle(Theme.textPrimary)
            Text("Этот раздел выпускает промокоды на бесплатный доступ. Он предназначен только для вас.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            SecureField("Код издателя", text: $passcode)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)
                .background(Theme.surfaceTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onSubmit(unlock)

            if passcodeError {
                Label("Неверный код", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }

            Button("Открыть", action: unlock)
                .buttonStyle(BrandButtonStyle())
                .disabled(passcode.isEmpty)
        }
        .padding(.horizontal, 26)
        .readableWidth(420)
    }

    private func unlock() {
        if PromoCodeService.isStudioPasscodeValid(passcode) {
            withAnimation(.spring(duration: 0.3)) { isUnlocked = true }
            passcode = ""
            passcodeError = false
        } else {
            withAnimation { passcodeError = true }
        }
    }

    // MARK: - Генератор

    @State private var kind: BenefitKind = .limited
    @State private var days = 365
    @State private var hasDeadline = false
    @State private var deadline = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
    @State private var count = 1
    @State private var issued: [String] = []
    @State private var didCopy = false
    @State private var qrCode: String?

    private enum BenefitKind: String, CaseIterable, Identifiable {
        case unlimited, limited
        var id: String { rawValue }
        var title: String { self == .unlimited ? "Навсегда" : "На срок" }
    }

    /// Готовые сроки: раздавать коды обычно нужно ровно на год или на семестр.
    private static let presets: [(title: String, days: Int?)] = [
        ("Год", 365), ("Семестр", 180), ("Месяц", 30), ("Навсегда", nil)
    ]

    private var benefit: PromoBenefit {
        kind == .unlimited ? .unlimited : .days(days)
    }

    private var generator: some View {
        ScrollView {
            VStack(spacing: 16) {
                settingsCard
                Button(count == 1 ? "Выпустить код" : "Выпустить \(pluralRu(count, "код", "кода", "кодов"))") {
                    withAnimation(.spring(duration: 0.3)) {
                        issued = PromoCodeService.generateBatch(count: count,
                                                                benefit: benefit,
                                                                redeemableUntil: hasDeadline ? deadline : nil)
                        didCopy = false
                    }
                }
                .buttonStyle(BrandButtonStyle())

                if !issued.isEmpty { resultCard }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .readableWidth(520)
        }
        .sheet(item: Binding(get: { qrCode.map(IdentifiableCode.init) },
                             set: { qrCode = $0?.value })) { item in
            QRPosterView(code: item.value, benefit: benefit)
                .macSheetSize(width: 460, height: 620)
        }
    }

    private var settingsCard: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Что даёт код")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 7) {
                        ForEach(Self.presets, id: \.title) { preset in
                            FilterChip(title: preset.title, isOn: isActive(preset.days)) {
                                withAnimation(.spring(duration: 0.2)) { apply(preset.days) }
                            }
                        }
                    }
                    Picker("Что даёт код", selection: $kind) {
                        ForEach(BenefitKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if kind == .limited {
                    Stepper(value: $days, in: 1...3650, step: 15) {
                        Text("Доступ на \(pluralRu(days, "день", "дня", "дней"))")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                    }
                } else {
                    Label("Полный доступ без ограничения по времени", systemImage: "infinity")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                }

                Divider().overlay(Theme.hairline)

                Toggle(isOn: $hasDeadline.animation()) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ограничить срок активации")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("После этой даты код перестанет приниматься")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .tint(Theme.primary)

                if hasDeadline {
                    DatePicker("Активировать до", selection: $deadline, in: Date()..., displayedComponents: .date)
                        .font(.subheadline)
                }

                Divider().overlay(Theme.hairline)

                Stepper(value: $count, in: 1...200) {
                    Text("Выпустить сразу: \(count)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    private var resultCard: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text(pluralRu(issued.count, "код", "кода", "кодов") + " · " + benefit.shortTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button {
                        Clipboard.copy(issued.joined(separator: "\n"))
                        didCopy = true
                    } label: {
                        Label(didCopy ? "Скопировано" : "Копировать всё",
                              systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(didCopy ? Theme.success : Theme.primary)
                }

                ForEach(issued, id: \.self) { code in
                    HStack(spacing: 8) {
                        Button {
                            Clipboard.copy(code)
                            didCopy = false
                        } label: {
                            HStack {
                                Text(code)
                                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.vertical, 9)
                            .padding(.horizontal, 12)
                            .background(Theme.surfaceTint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Скопировать код \(code)")

                        Button {
                            qrCode = code
                        } label: {
                            Image(systemName: "qrcode")
                                .font(.title3)
                                .foregroundStyle(Theme.primary)
                                .frame(width: 44, height: 44)
                                .background(Theme.surfaceTint, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Показать QR-код")
                    }
                }

                Text("Коды работают офлайн на любом устройстве. Повторная активация одного кода на том же устройстве блокируется.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)

                Label("Проверка одноразовости идёт на устройстве, поэтому один код можно активировать на разных устройствах. Чтобы код гарантированно срабатывал ровно один раз, выпускайте по отдельному коду на человека.",
                      systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func isActive(_ presetDays: Int?) -> Bool {
        guard let presetDays else { return kind == .unlimited }
        return kind == .limited && days == presetDays
    }

    private func apply(_ presetDays: Int?) {
        if let presetDays {
            kind = .limited
            days = presetDays
        } else {
            kind = .unlimited
        }
    }
}

/// Обёртка, чтобы строку кода можно было передать в `sheet(item:)`.
private struct IdentifiableCode: Identifiable {
    let value: String
    var id: String { value }
}

// MARK: - Карточка с QR-кодом

/// Готовая к раздаче карточка: крупный QR, код текстом и что он даёт.
/// Её удобно отправить в мессенджер скриншотом или распечатать.
private struct QRPosterView: View {
    let code: String
    let benefit: PromoBenefit

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                VStack(spacing: 20) {
                    GradientIcon(systemName: "ticket.fill", size: 64)

                    Text("MedNoteAi Premium")
                        .font(.title2.bold())
                        .foregroundStyle(Theme.textPrimary)
                    Text(benefit.title)
                        .font(.headline)
                        .foregroundStyle(Theme.primary)

                    QRCodeImage(text: QRCode.payload(for: code), size: 220)

                    Text(code)
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)

                    Text("Отсканируйте код камерой телефона или в приложении: «Профиль → Промокод». Код одноразовый — после активации повторно не принимается.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Button {
                        Clipboard.copy(code)
                        didCopy = true
                    } label: {
                        Label(didCopy ? "Код скопирован" : "Скопировать код",
                              systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(SoftButtonStyle())

                    Spacer()
                }
                .padding(.top, 24)
                .padding(.horizontal, 20)
            }
            .navigationTitle("QR-код")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    PromoStudioView()
}
