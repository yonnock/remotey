import AppKit
import SwiftUI

/// The setup assistant: the Mac's checklist, then pairing with the code and the checklist beside it, the first
/// move and the Home Screen. Everything in it ticks itself as the model changes.
struct AssistantView: View {
    @ObservedObject var model: MacModel
    @ObservedObject var flow: AssistantFlow
    var close: () -> Void = {}

    static let width: CGFloat = 600
    /// Every step has this much room, so the window keeps its size from step to step. The checklist fills it;
    /// the steps with a picture stand in its middle.
    static let contentHeight: CGFloat = 318

    private var state: MacState { model.state }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Logo().frame(width: 64, height: 64)
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .padding(.top, 14)
                    .accessibilityAddTraits(.isHeader)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                    .padding(.top, 6)
                content
                    .frame(maxWidth: .infinity, minHeight: Self.contentHeight, alignment: flow.phase == .prepare ? .top : .center)
                    .padding(.top, 22)
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .padding(.bottom, 20)
            Divider()
            footer
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var title: String {
        switch flow.phase {
        case .prepare: return Texts.Assistant.prepareTitle
        case .pair: return Texts.Assistant.pairTitle
        case .move: return flow.moved ? Texts.Assistant.movedTitle : Texts.Assistant.moveTitle
        case .homeScreen: return Texts.Assistant.homeTitle
        }
    }

    private var text: String {
        switch flow.phase {
        case .prepare: return Texts.Assistant.prepareText
        case .pair: return Texts.Assistant.pairText
        case .move: return flow.moved ? Texts.Assistant.movedText : Texts.Assistant.moveText
        case .homeScreen: return Texts.Assistant.homeText
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .prepare: prepare
        case .pair: HStack(alignment: .center, spacing: 30) { codeCard; checklist }
        case .move: HStack(alignment: .center, spacing: 30) { moveCard; checklist }
        case .homeScreen: HStack(alignment: .center, spacing: 30) { homeCard; homeSteps }
        }
    }

    // MARK: Prepare

    private var prepare: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                ForEach(Array([Setup.Item.accessibility, .screenRecording, .tailscale, .https, .serve].enumerated()), id: \.element) { index, item in
                    if index > 0 { Divider().padding(.leading, 44) }
                    SetupRowView(row: state.row(item), perform: model.actions.perform)
                }
            }
            loginItem
        }
    }

    private var loginItem: some View {
        let login = state.facts.loginItem
        return VStack(alignment: .leading, spacing: 2) {
            Toggle(Texts.Assistant.startAtLogin, isOn: Binding(
                get: { login == .on || login == .needsApproval },
                set: { model.actions.perform(.setLoginItem($0)) }))
                .toggleStyle(.checkbox)
                .disabled(login == .unavailable)
            Text(login == .unavailable ? Texts.Settings.loginItemUnavailable
                 : login == .needsApproval ? Texts.Settings.loginItemApproval : Texts.Assistant.startAtLoginNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Pair

    private var codeCard: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white)
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5)
                codeFace
            }
            .frame(width: 196, height: 196)
            digits
        }
    }

    @ViewBuilder
    private var codeFace: some View {
        switch flow.code {
        case .open(_, let link):
            Image(nsImage: QRCode.image(link))
                .interpolation(.none)
                .resizable()
                .frame(width: 172, height: 172)
                .accessibilityLabel(Texts.Assistant.qrLabel)
        case .expired, .tries:
            VStack(spacing: 10) {
                Image(systemName: "qrcode").font(.system(size: 44)).foregroundStyle(Color.black.opacity(0.2))
                Text(flow.code == .tries ? Texts.Assistant.tries : Texts.Assistant.expired)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.black.opacity(0.6))
                    .multilineTextAlignment(.center)
                Button(Texts.Assistant.newCode) { flow.renewCode() }
                    .controlSize(.small)
                    .environment(\.colorScheme, .light)
            }
            .padding(16)
        case .unavailable, nil:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small).environment(\.colorScheme, .light)
                Text(Texts.Assistant.waitingForTailscale)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.black.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var digits: some View {
        if case .open(let offer, _) = flow.code {
            VStack(spacing: 2) {
                Text(Self.grouped(offer.digits))
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .textSelection(.enabled)
                    .accessibilityLabel(offer.digits.map(String.init).joined(separator: " "))
                Text(Texts.Assistant.digitsLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// "123 456": two halves read and type more easily. The space does not break.
    static func grouped(_ digits: String) -> String { "\(digits.prefix(3))\u{00A0}\(digits.dropFirst(3))" }

    private var checklist: some View {
        let serve = state.row(.serve)
        let screen = state.row(.screenRecording)
        return VStack(alignment: .leading, spacing: 11) {
            Check(state: state.facts.accessibility ? .done : .missing,
                  title: state.facts.accessibility ? Texts.Assistant.accessibilityDone : Texts.Assistant.accessibilityMissing)
            Check(state: screen.state == .ok ? .done : .missing,
                  title: screen.state == .ok ? Texts.Assistant.screenDone : Texts.Assistant.screenMissing,
                  note: screen.state == .ok ? nil : Texts.Assistant.screenMissingNote)
            Check(state: serve.state == .ok ? .done : .missing,
                  title: serve.state == .ok ? Texts.Assistant.sharedDone : Texts.Assistant.sharedMissing,
                  note: serve.state == .ok ? sharedNote : nil)
            pairCheck
            Check(state: flow.moved ? .done : flow.phase == .move ? .current : .pending,
                  title: flow.moved ? Texts.Assistant.moveStepDone : Texts.Assistant.moveStep)
            Check(state: .pending, title: Texts.Assistant.homeStep)
        }
        .frame(width: 270, alignment: .leading)
    }

    private var sharedNote: String? {
        if case .done(.answered) = state.facts.selfTest { return Texts.Assistant.selfTestPassed }
        return state.hostname
    }

    @ViewBuilder
    private var pairCheck: some View {
        if let device = flow.device {
            Check(state: .done, title: Texts.Assistant.paired(device.name))
        } else {
            switch flow.code {
            case .open(let offer, _):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Check(state: .current, title: Texts.Assistant.waitingForPhone,
                          note: Texts.Assistant.codeValid(offer.ends.timeIntervalSince(context.date)))
                }
            case .expired: Check(state: .missing, title: Texts.Assistant.waitingForPhone, note: Texts.Assistant.expired)
            case .tries: Check(state: .missing, title: Texts.Assistant.waitingForPhone, note: Texts.Assistant.tries)
            case .unavailable, nil: Check(state: .pending, title: Texts.Assistant.waitingForPhone)
            }
        }
    }

    // MARK: Move

    private var moveCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            Image(systemName: flow.moved ? "checkmark.circle.fill" : "hand.draw")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(flow.moved ? Color.green : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
        }
        .frame(width: 196, height: 196)
    }

    // MARK: Home Screen

    private var homeCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            Image(systemName: flow.onHomeScreen ? "checkmark.circle.fill" : "apps.iphone.badge.plus")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(flow.onHomeScreen ? Color.green : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
        }
        .frame(width: 196, height: 196)
    }

    private var homeSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Texts.Assistant.homeSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.quaternary))
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Self.instruction(step).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().padding(.vertical, 2)
            if flow.onHomeScreen {
                Check(state: .done, title: Texts.Assistant.homeDone)
            } else {
                Check(state: .current, title: Texts.Assistant.homeStep,
                      note: { if case .open(let offer, _) = flow.code { return Texts.Assistant.homeDigits(Self.grouped(offer.digits)) }; return nil }())
            }
        }
        .frame(width: 270, alignment: .leading)
    }

    /// A step with the symbol of the key it names in place of `{symbol}`, as Apple's instructions show it.
    static func instruction(_ step: (text: String, symbol: String)) -> Text {
        let parts = step.text.components(separatedBy: "{symbol}")
        guard parts.count == 2 else { return Text(step.text) }
        return Text(parts[0]) + Text(Image(systemName: step.symbol)).foregroundColor(.accentColor) + Text(parts[1])
    }

    // MARK: Footer

    private var footer: some View {
        ZStack {
            PageDots(count: AssistantFlow.Phase.allCases.count, current: flow.phase.rawValue)
            HStack {
                Button(Texts.Assistant.back) { flow.back() }
                    .opacity(flow.phase == .prepare ? 0 : 1)
                    .disabled(flow.phase == .prepare)
                    .accessibilityHidden(flow.phase == .prepare)
                Spacer()
                Button(flow.phase == .homeScreen ? Texts.Assistant.done : Texts.Assistant.next) {
                    if flow.next() == nil { close() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.canGoOn)
                .help(flow.phase == .prepare && !flow.canGoOn ? Texts.Assistant.notReady : "")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// A rounded card of rows, as the lists in System Settings are.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

/// A checklist row with its state, sentence and the one key that helps.
struct SetupRowView: View {
    var row: Setup.Row
    var perform: (Setup.Action) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Check.Mark(state: Check.State(row.state))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 13, weight: .medium))
                Text(row.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if let action = row.action, row.state != .ok || Self.showsWhenOK(action) {
                Button(action.title) { perform(action) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// A fine row keeps a key only to test again.
    static func showsWhenOK(_ action: Setup.Action) -> Bool { action == .selfTest }
}

/// A line of the assistant's checklist.
struct Check: View {
    enum State: Equatable {
        case done, current, missing, failed, pending

        init(_ state: Setup.State) {
            switch state {
            case .ok: self = .done
            case .actionNeeded: self = .missing
            case .failed: self = .failed
            case .working: self = .current
            }
        }
    }

    var state: State
    var title: String
    var note: String?

    var body: some View {
        HStack(alignment: note == nil ? .center : .top, spacing: 9) {
            Mark(state: state)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .opacity(state == .pending ? 0.45 : 1)
        .accessibilityElement(children: .combine)
    }

    /// The round mark: a tick in green, a mark that asks in orange or red, a spinner, or an empty ring.
    struct Mark: View {
        var state: State

        var body: some View {
            ZStack {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                case .missing:
                    Image(systemName: "exclamationmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .orange)
                case .failed:
                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .red)
                case .current:
                    ProgressView().controlSize(.small)
                case .pending:
                    Circle().strokeBorder(.tertiary, lineWidth: 1.5).frame(width: 18, height: 18)
                }
            }
            .font(.system(size: 20))
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
        }
    }
}

/// Where the assistant is: green for the steps done, the current one in the label colour.
struct PageDots: View {
    var count: Int
    var current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index < current ? AnyShapeStyle(Color.green) : index == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(current + 1) / \(count)")
    }
}

/// The assistant's window. Watches the checklist while it is open, and gives up the code when it closes.
final class AssistantWindow: NSObject, NSWindowDelegate {
    let flow: AssistantFlow
    private let model: MacModel
    private(set) var window: NSWindow?
    var opened: (() -> Void)?
    var closed: (() -> Void)?

    init(model: MacModel, flow: AssistantFlow) {
        self.model = model
        self.flow = flow
    }

    var isOpen: Bool { window?.isVisible == true }

    func show(at phase: AssistantFlow.Phase, firstStart: Bool = false) {
        if !isOpen { opened?() }
        flow.start(at: phase, firstStart: firstStart)
        let window = window ?? makeWindow()
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: AssistantView(model: model, flow: flow) { [weak self] in self?.window?.close() })
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.title = Texts.Assistant.windowTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        flow.stop()
        closed?()
    }
}
