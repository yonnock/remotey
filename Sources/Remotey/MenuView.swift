import SwiftUI

/// The status item's panel, laid out like the Wi-Fi or Bluetooth menu: a switch in the head, who is connected,
/// the status of what the phone needs, then the menu's entries. Rows highlight under the pointer and with the
/// arrow keys, as menu items do, and act on a click or Return.
struct MenuView: View {
    @ObservedObject var model: MacModel
    /// The row lit when the panel opens: none, as in a menu. Pictures light one to show how it looks.
    var highlight: Item?
    @State private var highlighted: Item?
    @FocusState private var focused: Bool

    static let width: CGFloat = 320

    enum Item: Hashable {
        case status(StatusLine.Kind), addPhone, faceID, settings, quit
    }

    private var state: MacState { model.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            sessions
            separator
            Text(Texts.Menu.status)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 3)
                .padding(.bottom, 3)
                .accessibilityAddTraits(.isHeader)
            ForEach(state.statusLines) { line in status(line) }
            separator
            row(.addPhone, symbol: "macbook.and.iphone", title: Texts.Menu.addPhone)
            row(.faceID, symbol: "faceid", title: Texts.Menu.faceID,
                trailing: state.faceUnlock ? Texts.Menu.faceIDOn : Texts.Menu.faceIDOff)
            row(.settings, symbol: "gearshape", title: Texts.Menu.settings, trailing: "⌘,")
            separator
            row(.quit, symbol: nil, title: Texts.Menu.quit, trailing: "⌘Q")
        }
        .padding(6)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.return) { activateHighlighted() }
        .onKeyPress(.space) { activateHighlighted() }
        .onKeyPress(.escape) {
            model.actions.closeMenu()
            return .handled
        }
        .onAppear {
            highlighted = highlight
            focused = true
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(Texts.Menu.name)
                    .font(.system(size: 13, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Toggle(Texts.Menu.remoteControl, isOn: Binding(
                    get: { !state.paused },
                    set: { on in model.attempt { try model.actions.setPaused(!on) } }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel(Texts.Menu.remoteControl)
            }
            if state.paused {
                Text(Texts.Menu.paused)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.top, 5)
        .padding(.bottom, 7)
    }

    @ViewBuilder
    private var sessions: some View {
        if state.sessions.isEmpty {
            HStack(spacing: 9) {
                badge("iphone", filled: false)
                Text(Texts.Menu.noPhone).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        } else {
            ForEach(state.sessions) { session in
                let name = MacState.name(of: session)
                HStack(spacing: 9) {
                    badge(MacState.symbol(forDevice: session.name), filled: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.system(size: 13))
                        Text(state.subtitle(of: session)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 8)
                    Button(Texts.Menu.end) { model.actions.end(session.id) }
                        .buttonStyle(InlineButtonStyle())
                        .help(Texts.Menu.endHelp(name))
                        .accessibilityLabel(Texts.Menu.endHelp(name))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
        }
    }

    /// The device in a circle: in the accent colour while it is connected.
    private func badge(_ symbol: String, filled: Bool) -> some View {
        ZStack {
            Circle().fill(filled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }

    private var separator: some View {
        Divider().padding(.horizontal, 10).padding(.vertical, 5)
    }

    private func status(_ line: StatusLine) -> some View {
        let item = Item.status(line.kind)
        let lit = highlighted == item && line.fix != nil
        return MenuRow(symbol: line.symbol, title: line.title, subtitle: line.subtitle, highlighted: lit) {
            StateMark(state: line.state, highlighted: lit)
        }
        .modifier(Interactive(item: item, enabled: line.fix != nil, highlighted: $highlighted, activate: activate))
        .accessibilityValue(Self.spoken(line.state))
    }

    private func row(_ item: Item, symbol: String?, title: String, trailing: String? = nil) -> some View {
        let lit = highlighted == item
        return MenuRow(symbol: symbol, title: title, subtitle: nil, highlighted: lit) {
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12))
                    .foregroundStyle(lit ? AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor)) : AnyShapeStyle(.secondary))
            }
        }
        .modifier(Interactive(item: item, enabled: true, highlighted: $highlighted, activate: activate))
    }

    private static func spoken(_ state: Setup.State) -> String {
        switch state {
        case .ok: return Texts.Menu.ok
        case .actionNeeded: return Texts.Menu.needsAction
        case .failed: return Texts.Menu.failed
        case .working: return Texts.Menu.checking
        }
    }

    // MARK: Keys

    /// The rows a click or Return acts on, top to bottom.
    private var items: [Item] {
        state.statusLines.filter { $0.fix != nil }.map { .status($0.kind) } + [.addPhone, .faceID, .settings, .quit]
    }

    private func step(_ by: Int) -> KeyPress.Result {
        let items = items
        guard !items.isEmpty else { return .handled }
        if let highlighted, let index = items.firstIndex(of: highlighted) {
            self.highlighted = items[(index + by + items.count) % items.count]
        } else {
            self.highlighted = by > 0 ? items.first : items.last
        }
        return .handled
    }

    private func activateHighlighted() -> KeyPress.Result {
        guard let highlighted else { return .ignored }
        activate(highlighted)
        return .handled
    }

    private func activate(_ item: Item) {
        let actions = model.actions
        actions.closeMenu()
        switch item {
        case .status(let kind):
            switch state.statusLines.first(where: { $0.kind == kind })?.fix {
            case .perform(let action): actions.perform(action)
            case .assistant: actions.openAssistant()
            case nil: break
            }
        case .addPhone: actions.addPhone()
        case .faceID: actions.setUpFaceUnlock()
        case .settings: actions.openSettings(nil)
        case .quit: actions.quit()
        }
    }
}

/// One line of the menu: symbol, title with an optional line under it, and what stands at its end.
struct MenuRow<Trailing: View>: View {
    var symbol: String?
    var title: String
    var subtitle: String?
    var highlighted: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 9) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(highlighted ? AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor).opacity(0.8)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            trailing.fixedSize()
        }
        .foregroundStyle(highlighted ? AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor)) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minHeight: 26)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .selectedContentBackgroundColor))
            }
        }
        .contentShape(Rectangle())
    }
}

/// A row that highlights under the pointer and acts on a click, as a menu item does.
private struct Interactive: ViewModifier {
    var item: MenuView.Item
    var enabled: Bool
    @Binding var highlighted: MenuView.Item?
    var activate: (MenuView.Item) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .onHover { inside in
                    if inside { highlighted = item } else if highlighted == item { highlighted = nil }
                }
                .onTapGesture { activate(item) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { activate(item) }
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}

/// A row's state at its end: a tick, a mark that asks for something, or a spinner.
struct StateMark: View {
    var state: Setup.State
    var highlighted = false

    var body: some View {
        Group {
            switch state {
            case .ok:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(highlighted ? AnyShapeStyle(Color(nsColor: .selectedMenuItemTextColor)) : AnyShapeStyle(.secondary))
            case .actionNeeded:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, highlighted ? Color(nsColor: .selectedMenuItemTextColor).opacity(0.35) : Color.orange)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, highlighted ? Color(nsColor: .selectedMenuItemTextColor).opacity(0.35) : Color.red)
            case .working:
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// A small key inside a row, like "Trennen": text until the pointer is on it.
struct InlineButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.08 : 0)))
            .onHover { hovering = $0 }
    }
}
