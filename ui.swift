import SwiftUI
import AppKit

// MARK: - Цвет бренда

/// Основной цвет DownMax — розовый #FF4D80 (500). Палитра — 11 ступеней в OKLCH с тем же оттенком
/// (8°), здесь только нужные. Роли (инспекция по ui-color-system):
/// - заливки, выбор, галочки, прогресс, рамка фокуса — 500 в обеих темах;
/// - ссылки мелким текстом — 600 в светлой, 400 в тёмной (500 как текст не проходит по контрасту);
///   наведение — на ступень дальше: 700 / 300;
/// - ошибки — системный красный, не бренд.
/// `.tint(.brand)` ставится на каждый элемент, не на корень окна: на macOS 27 общий оттенок
/// красит и обычные кнопки, которые синими не были.
extension NSColor {
    static let brand300 = NSColor(srgbRed: 0.996, green: 0.647, blue: 0.710, alpha: 1)  // #FEA5B5
    static let brand400 = NSColor(srgbRed: 1, green: 0.490, blue: 0.600, alpha: 1)      // #FF7D99
    static let brand = NSColor(srgbRed: 1, green: 0.302, blue: 0.502, alpha: 1)         // #FF4D80, 500
    static let brand600 = NSColor(srgbRed: 0.886, green: 0.227, blue: 0.427, alpha: 1)  // #E23A6D
    static let brand700 = NSColor(srgbRed: 0.745, green: 0.184, blue: 0.357, alpha: 1)  // #BE2F5B

    /// Цвет ссылки: 600 в светлой теме, 400 в тёмной.
    static let brandLink = NSColor(name: nil) { $0.isDark ? .brand400 : .brand600 }
    /// Ссылка под курсором: на ступень дальше от фона — 700 / 300.
    static let brandLinkHover = NSColor(name: nil) { $0.isDark ? .brand300 : .brand700 }
}

// MARK: - Серые

/// Нейтральные серые в тёмной теме — как в Claude: без них macOS подмешивает к окну цвет обоев
/// (у пользователя серый уходил в розовый). В светлой теме — системные цвета.
extension NSColor {
    /// Фон окна, всплывающих панелей и листов.
    static let surface = NSColor(name: nil) { $0.isDark ? NSColor(white: 0x15 / 255.0, alpha: 1) : .windowBackgroundColor }
    /// Всплывающие панели («Оценить», «Поддержать») — светлее окна, иначе сливаются с ним.
    static let popover = NSColor(name: nil) { $0.isDark ? NSColor(white: 0x26 / 255.0, alpha: 1) : .windowBackgroundColor }
    /// Строка загрузки под курсором — на ступень светлее строки (в светлой теме — чуть темнее).
    static let surfaceHover = NSColor(name: nil) { $0.isDark ? NSColor(white: 0x27 / 255.0, alpha: 1) : NSColor(white: 0.965, alpha: 1) }
    /// Строки загрузок и карточки.
    static let surfaceRaised = NSColor(name: nil) { $0.isDark ? NSColor(white: 0x21 / 255.0, alpha: 1) : .controlBackgroundColor }
    /// Поля ввода.
    static let field = NSColor(name: nil) { $0.isDark ? NSColor(white: 0x21 / 255.0, alpha: 1) : .textBackgroundColor }
    /// Нижняя строка окна — полоса чуть светлее фона, чтобы отделялась от списка.
    static let footer = NSColor(name: nil) { $0.isDark ? NSColor(white: 0x1D / 255.0, alpha: 1) : NSColor(white: 0.9, alpha: 1) }
    /// Рамки строк и полей — на ступень светлее карточки.
    static let hairline = NSColor(name: nil) { $0.isDark ? NSColor(white: 0x30 / 255.0, alpha: 1) : .separatorColor }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Color {
    static let brand = Color(nsColor: .brand)
    static let brandLink = Color(nsColor: .brandLink)
    static let brandLinkHover = Color(nsColor: .brandLinkHover)
    static let surface = Color(nsColor: .surface)
    static let surfaceRaised = Color(nsColor: .surfaceRaised)
    static let surfaceHover = Color(nsColor: .surfaceHover)
    static let popover = Color(nsColor: .popover)
    static let footer = Color(nsColor: .footer)
    static let field = Color(nsColor: .field)
    static let hairline = Color(nsColor: .hairline)
}

/// Ссылка-кнопка («Изменить…», «выберите на диске…»): розовая, под курсором и при нажатии — темнее
/// в светлой теме и светлее в тёмной.
struct BrandLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BrandLink(configuration: configuration)
    }

    private struct BrandLink: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering || configuration.isPressed ? Color.brandLinkHover : Color.brandLink)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == BrandLinkStyle {
    static var brandLink: BrandLinkStyle { BrandLinkStyle() }
}

// MARK: - Кнопки с наведением

/// У системных кнопок macOS нет наведения — рисуем свои. Серая кнопка светлеет под курсором (в светлой
/// теме — темнеет), розовая темнеет (600, при нажатии 700), значки и тихие кнопки из серых становятся
/// основного цвета текста. Размер — по controlSize: крупная 32 (главная строка окна, кнопки в окнах и листах),
/// обычная 28 (панели, вкладки, меню), мелкая 22 (нижняя строка). Бока — половина высоты, форма — капсула.
struct PillButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, prominent: prominent)
    }

    private struct Pill: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.controlSize) private var size
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(small ? .system(size: 12) : .body)
                .lineLimit(1)
                .padding(.horizontal, large ? 16 : small ? 10 : 14)
                .frame(minHeight: large ? Metrics.large : small ? Metrics.small : Metrics.regular)
                .foregroundStyle(foreground)
                .background(RoundedRectangle(cornerRadius: radius).fill(fill))
                .contentShape(RoundedRectangle(cornerRadius: radius))
                .onHover { hovering = $0 && enabled }
                .animation(.easeOut(duration: 0.1), value: hovering)
        }

        private var large: Bool { size == .large || size == .extraLarge }
        private var radius: CGFloat { Metrics.radius(large ? Metrics.large : small ? Metrics.small : Metrics.regular) }
        private var small: Bool { size == .small || size == .mini }

        private var foreground: AnyShapeStyle {
            if !enabled { return AnyShapeStyle(.tertiary) }
            return prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary)
        }

        private var fill: AnyShapeStyle {
            if !enabled { return AnyShapeStyle(Color.primary.opacity(0.06)) }
            if prominent {
                return AnyShapeStyle(configuration.isPressed ? Color(nsColor: .brand700)
                                     : hovering ? Color(nsColor: .brand600) : Color.brand)
            }
            return AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.28 : hovering ? 0.2 : 0.12))
        }
    }
}

/// Значки в строках загрузок и тихие кнопки («Оценить», «Поддержать»): серые, под курсором — ярче.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Quiet(configuration: configuration)
    }

    private struct Quiet: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(!enabled ? AnyShapeStyle(.tertiary) : hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    /// Обычная кнопка («Вставить», «Открыть папку»).
    static var gray: PillButtonStyle { PillButtonStyle(prominent: false) }
    /// Главная кнопка («Скачать», «Отправить»).
    static var brandFill: PillButtonStyle { PillButtonStyle(prominent: true) }
}

/// Тихая кнопка с меню («Сохранять в ~/Downloads ▾»): серый текст без плашки, под курсором — розовый, как ссылка
/// (`brandLink`, при нажатии — `brandLinkHover`). Для того, что видно всегда, но меняют редко.
struct QuietPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietPill(configuration: configuration)
    }

    private struct QuietPill: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .lineLimit(1)
                .frame(height: Metrics.regular)
                .foregroundStyle(configuration.isPressed ? AnyShapeStyle(Color.brandLinkHover)
                                 : hovering ? AnyShapeStyle(Color.brandLink) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
    }
}

extension ButtonStyle where Self == QuietPillStyle {
    static var quietPill: QuietPillStyle { QuietPillStyle() }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

/// Вкладки вместо системного сегментного переключателя (у него нет наведения): выбранная — розовая,
/// невыбранная под курсором подсвечивается.
struct Tabs: View {
    @Binding var selection: String
    let options: [(tag: String, title: String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.tag) { option in
                Tab(title: option.title, selected: selection == option.tag) { selection = option.tag }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Metrics.radius(Metrics.regular)).fill(Color.primary.opacity(0.1)))
    }

    private struct Tab: View {
        let title: String
        let selected: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                PressedReader { pressed in
                    Text(title)
                        .padding(.horizontal, 12)
                        .frame(height: Metrics.regular - 4)  // с полями 2 — 28, как кнопки рядом
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                        .background(RoundedRectangle(cornerRadius: Metrics.radius(Metrics.regular) - 2).fill(
                            selected ? AnyShapeStyle(pressed ? Color(nsColor: .brand700) : hovering ? Color(nsColor: .brand600) : Color.brand)
                                     : AnyShapeStyle(Color.primary.opacity(pressed ? 0.18 : hovering ? 0.1 : 0))))
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.pressReporting)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// Галочка с наведением: пустая рамка под курсором светлеет, розовая — темнеет. Щёлкать можно и по тексту.
struct BrandCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Checkbox(configuration: configuration)
    }

    private struct Checkbox: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(configuration.isOn ? AnyShapeStyle(hovering ? Color(nsColor: .brand600) : Color.brand)
                                                     : AnyShapeStyle(Color.primary.opacity(hovering ? 0.14 : 0.06)))
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.primary.opacity(hovering ? 0.45 : 0.3), lineWidth: 1)
                        }
                    }
                    .frame(width: 16, height: 16)
                    configuration.label
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
            .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
        }
    }
}

extension ToggleStyle where Self == BrandCheckboxStyle {
    static var brandCheckbox: BrandCheckboxStyle { BrandCheckboxStyle() }
}

/// Подсветка системного элемента под курсором (выпадающий список): полупрозрачный слой поверх, щелчки проходят.
struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.primary.opacity(hovering ? 0.12 : 0))
                .allowsHitTesting(false))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = Metrics.radius(Metrics.regular)) -> some View { modifier(HoverHighlight(cornerRadius: cornerRadius)) }

    /// Рамка поля ввода: розовая с курсором, светлее под мышью, иначе обычная.
    func fieldBorder(focused: Bool, hovering: Bool, cornerRadius: CGFloat = Metrics.cardRadius) -> some View {
        overlay(RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(focused ? AnyShapeStyle(Color.brand)
                          : hovering ? AnyShapeStyle(Color.primary.opacity(0.3)) : AnyShapeStyle(Color.hairline),
                          lineWidth: 1))
    }
}

// MARK: - Размеры

/// Общие размеры. Отступы — по линейке 4 · 8 · 12 · 16 · 24; внутри группы меньше, между группами — следующая
/// ступень (×1,5–2).
/// Скругление растёт медленнее размера: 6 + десятая часть высоты, не больше 12. На глаз так мелкие и крупные
/// элементы скруглены одинаково (четверть высоты делала кнопки квадратными, а строки — круглыми).
/// Кнопки и поля 32 и 28 — 9, мелкие 22 — 8; все карточки (строки, панели, листы) — 12; окно macOS — 16;
/// галочки и метки — 4. Вложенное — меньше на поле (выбранная вкладка 9 − 2 = 7), чтобы углы шли параллельно.
enum Metrics {
    static let windowRadius: CGFloat = 16

    static func radius(_ height: CGFloat) -> CGFloat { min(cardRadius, (6 + height / 10).rounded()) }
    static let large: CGFloat = 32
    static let regular: CGFloat = 28
    static let small: CGFloat = 22
    /// Скругление карточек, панелей, списков в листах и многострочных полей.
    static let cardRadius: CGFloat = 12
    /// Поля строки загрузки: по бокам 14 (как бока у кнопок 28), сверху 12 (над заголовком ещё ~3 пустоты шрифта —
    /// видно ~15), снизу 14 (метка источника — плашка, у её края пустоты нет; видно ~14).
    static let cardPadding = EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14)
}

/// Кнопка-значок (действия в строке, крестик панели): поле 28×28, под курсором — серый квадрат со скруглением 7. Значок 14 pt,
/// контурный — все одного веса. Стоят вплотную: между значками видно ~14, круг наведения их не перекрывает.
struct IconButton: View {
    let symbol: String
    let help: String
    /// Поворот значка: у скрепки SF Symbols наклон ~45°, рядом с прямым текстом поля это слишком.
    var rotation: Double = 0
    /// Кегль значка: 14 у обычных; высокие узкие (скрепка) — меньше, чтобы не торчали выше текста.
    var size: CGFloat = 14
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    init(_ symbol: String, _ help: String, rotation: Double = 0, size: CGFloat = 14, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.rotation = rotation
        self.size = size
        self.action = action
    }

    var body: some View {
        // Действие — после щелчка, а не внутри него: многие кнопки открывают Ask (модальное окно), а пока
        // щелчок по SwiftUI-кнопке не закончен, окно вопроса не получает мышь и приложение кажется зависшим.
        Button { DispatchQueue.main.async(execute: action) } label: {
            PressedReader { pressed in
                Image(systemName: symbol)
                    .font(.system(size: size))
                    .rotationEffect(.degrees(rotation))
                    .foregroundStyle(!enabled ? AnyShapeStyle(.tertiary) : hovering || pressed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(width: Metrics.regular, height: Metrics.regular)
                    .background(RoundedRectangle(cornerRadius: Metrics.radius(Metrics.regular))
                        .fill(Color.primary.opacity(pressed ? 0.18 : hovering ? 0.1 : 0)))
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.pressReporting)
        .onHover { hovering = $0 && enabled }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Полоса хода

/// Полоса хода загрузки, как системная, но умеет «ждать»: пока торрент ищет участников (скорость 0), по заполненной
/// части бежит светлый блик — видно, что загрузка жива, хотя не движется. При «Уменьшить движение» — без блика, заливка бледнее.
struct LoadBar: View {
    let value: Double
    var waiting = false
    var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let fill = max(geo.size.height, geo.size.width * min(max(value, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Color.brand)
                    .frame(width: fill)
                    .opacity(dimmed || (waiting && reduceMotion) ? 0.5 : 1)
                    // блик — только по заполненной части: от её левого края до правого, целиком
                    .overlay(alignment: .leading) {
                        if waiting && !reduceMotion {
                            TimelineView(.animation) { context in
                                let period = 1.6
                                let phase = context.date.timeIntervalSinceReferenceDate
                                    .truncatingRemainder(dividingBy: period) / period
                                let band = max(24, fill * 0.35)
                                LinearGradient(colors: [.clear, Color.white.opacity(0.4), .clear],
                                               startPoint: .leading, endPoint: .trailing)
                                    .frame(width: band)
                                    .offset(x: -band + (fill + band) * phase)
                                    .frame(width: fill, alignment: .leading)
                            }
                            .clipShape(Capsule())
                            .allowsHitTesting(false)
                        }
                    }
            }
        }
        .frame(height: 4)  // тонкая: 6 давала «черноту» и спорила с заголовком
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

// MARK: - Отклик на нажатие

/// Стиль без своего вида: только передаёт «нажата ли кнопка» внутрь, в `PressedReader`. Так своя кнопка темнеет
/// в момент нажатия, ещё до того, как её отпустили (у `.plain` этого нет).
struct PressReportingStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.buttonPressed, configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressReportingStyle {
    static var pressReporting: PressReportingStyle { PressReportingStyle() }
}

private struct ButtonPressedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var buttonPressed: Bool {
        get { self[ButtonPressedKey.self] }
        set { self[ButtonPressedKey.self] = newValue }
    }
}

struct PressedReader<Content: View>: View {
    @Environment(\.buttonPressed) private var pressed
    @ViewBuilder let content: (Bool) -> Content
    var body: some View { content(pressed) }
}

/// Фон строки загрузки: под курсором чуть меняет цвет, рамка та же (без обводки-подсветки).
private struct RowCard: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .fill(hovering ? Color.surfaceHover : Color.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(Color.hairline))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func rowCard() -> some View { modifier(RowCard()) }
}

// MARK: - Вопрос по центру

/// Замена NSAlert: у системного окна значок и текст прижаты влево, а у нас всё по центру и главная
/// кнопка розовая. Кнопки — столбиком, первая главная (Return), последняя — отказ (Esc).
/// Возвращает номер нажатой кнопки.
enum Ask {
    @discardableResult
    static func run(_ title: String, _ text: String? = nil, buttons: [String] = ["OK"]) -> Int {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .surface
        panel.isMovableByWindowBackground = true
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }
        var answer = buttons.count - 1
        let view = AskView(title: title, text: text, buttons: buttons) { index in
            answer = index
            NSApp.stopModal()
        }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return answer
    }
}

private struct AskView: View {
    let title: String
    let text: String?
    let buttons: [String]
    let choose: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .padding(.bottom, 14)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let text {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            VStack(spacing: 8) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { index, name in
                    button(name, index)
                }
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(width: 300)
    }

    @ViewBuilder
    private func button(_ name: String, _ index: Int) -> some View {
        let b = Button { choose(index) } label: { Text(name).frame(maxWidth: .infinity) }
            .controlSize(.large)
        if index == 0 {
            b.buttonStyle(.brandFill).keyboardShortcut(.defaultAction)
        } else if index == buttons.count - 1 {
            b.buttonStyle(.gray).keyboardShortcut(.cancelAction)
        } else {
            b.buttonStyle(.gray)
        }
    }
}

// MARK: - Тонкая полоса прокрутки

/// Своя полоса прокрутки: 5 px, в поле окна справа от списка, видна при прокрутке и пока курсор над списком.
/// Системная при настройке macOS «показывать полосы прокрутки: всегда» широкая, с дорожкой, и съедает
/// ширину списка; переключить её стиль у ScrollView SwiftUI не даёт (возвращает системный).
/// Нужен macOS 15 (`onScrollGeometryChange`); на 14 остаётся системная.
extension View {
    func thinScrollIndicator() -> some View { modifier(ThinScrollIndicator()) }
}

private struct ThinScrollIndicator: ViewModifier {
    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var containerHeight: CGFloat = 0
    @State private var scrolling = false
    @State private var hovering = false
    @State private var hide: Task<Void, Never>?

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: [CGFloat].self) {
                    [$0.contentOffset.y, $0.contentSize.height, $0.containerSize.height]
                } action: { old, new in
                    offset = new[0]
                    contentHeight = new[1]
                    containerHeight = new[2]
                    if old[0] != new[0] { showWhileScrolling() }
                }
                .overlay(alignment: .topTrailing) { knob }
                .onHover { hovering = $0 }
        } else {
            content
        }
    }

    @ViewBuilder private var knob: some View {
        if contentHeight > containerHeight + 1, containerHeight > 0 {
            let height = max(28, containerHeight * containerHeight / contentHeight)
            let share = min(max(offset / (contentHeight - containerHeight), 0), 1)
            Capsule()
                .fill(Color.primary.opacity(0.35))
                .frame(width: 5, height: height)
                // в поле окна справа от списка (20 px), по его середине — не поверх карточек
                .offset(x: 12, y: (containerHeight - height) * share)
                .opacity(scrolling || hovering ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: scrolling || hovering)
                .allowsHitTesting(false)
        }
    }

    private func showWhileScrolling() {
        scrolling = true
        hide?.cancel()
        hide = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { scrolling = false }
        }
    }
}

