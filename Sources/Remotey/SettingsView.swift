import AppKit
import SwiftUI

/// The settings' panes, each a grouped form as in System Settings. Everything that cannot be undone with
/// one click asks first, and says what happens.
struct SettingsPane: View {
    @ObservedObject var model: MacModel
    var pane: MacModel.Pane

    static let width: CGFloat = 560

    var body: some View {
        Group {
            switch pane {
            case .general: GeneralPane(model: model)
            case .phones: PhonesPane(model: model)
            case .security: SecurityPane(model: model)
            case .permissions: PermissionsPane(model: model)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .tint(Accent.color)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func title(_ pane: MacModel.Pane) -> String {
        switch pane {
        case .general: return Texts.Settings.general
        case .phones: return Texts.Settings.phones
        case .security: return Texts.Settings.security
        case .permissions: return Texts.Settings.permissions
        }
    }

    static func symbol(_ pane: MacModel.Pane) -> String {
        switch pane {
        case .general: return "gearshape"
        case .phones: return "iphone"
        case .security: return "lock.shield"
        case .permissions: return "hand.raised"
        }
    }
}

// MARK: Allgemein

private struct GeneralPane: View {
    @ObservedObject var model: MacModel
    private var state: MacState { model.state }

    var body: some View {
        Form {
            Section {
                let login = state.facts.loginItem
                Toggle(isOn: Binding(get: { login == .on || login == .needsApproval },
                                     set: { model.actions.perform(.setLoginItem($0)) })) {
                    Text(Texts.Settings.startAtLogin)
                    Text(login == .unavailable ? Texts.Settings.loginItemUnavailable : Texts.Settings.startAtLoginNote)
                }
                .disabled(login == .unavailable)
                if login == .needsApproval {
                    LabeledContent {
                        Button(Texts.Settings.openLoginItems) { model.actions.perform(.openLoginItems) }
                    } label: {
                        Label(Texts.Settings.loginItemApproval, systemImage: "exclamationmark.circle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
                Toggle(isOn: Binding(get: { !state.paused },
                                     set: { on in model.attempt { try model.actions.setPaused(!on) } })) {
                    Text(Texts.Settings.remoteControl)
                    Text(Texts.Settings.remoteControlNote)
                }
            }
            Section {
                LabeledContent(Texts.Settings.address) {
                    Text(state.address ?? Texts.Settings.addressMissing).textSelection(.enabled)
                }
                LabeledContent(Texts.Settings.agent) {
                    Text(state.healthText)
                }
                LabeledContent {
                    Button(Texts.Settings.openAssistant) { model.actions.openAssistant() }
                } label: {
                    Text(Texts.Settings.setup)
                    Text(Setup.summary(state.rows).text)
                }
            }
        }
    }
}

// MARK: iPhones

private struct PhonesPane: View {
    @ObservedObject var model: MacModel
    @State private var revoking: Device?
    @State private var editing: Device?
    @State private var disconnectingAll = false
    @State private var droppingToken = false
    private var state: MacState { model.state }

    var body: some View {
        Form {
            Section(Texts.Settings.pairedPhones) {
                if state.devices.isEmpty {
                    LabeledContent {
                        Button(Texts.Settings.addPhone) { model.actions.addPhone() }
                    } label: {
                        Text(Texts.Settings.noPhones).foregroundStyle(.secondary)
                    }
                }
                ForEach(state.devices) { device in
                    DeviceRow(device: device, subtitle: state.subtitle(of: device, now: model.now),
                              connected: state.session(of: device.id) != nil,
                              edit: { editing = device }, revoke: { revoking = device })
                }
                if !state.devices.isEmpty {
                    HStack {
                        Spacer()
                        Button(Texts.Settings.addPhone) { model.actions.addPhone() }
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { state.acceptsToken }, set: { on in
                    if on || tokenSessions == 0 {
                        model.attempt { try model.actions.setAcceptsToken(on) }
                    } else {
                        droppingToken = true
                    }
                })) {
                    Text(Texts.Settings.sharedKey)
                    Text(Texts.Settings.sharedKeyNote)
                }
            } footer: {
                HStack {
                    Text(Texts.Settings.ownKeys).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(Texts.Settings.disconnectAll) { disconnectingAll = true }
                        .disabled(state.devices.isEmpty && !state.acceptsToken)
                }
            }
        }
        .confirmationDialog(Texts.Settings.revokeTitle(revoking?.name ?? ""), isPresented: Binding(
            get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible, presenting: revoking) { device in
            Button(Texts.Settings.revokeConfirm, role: .destructive) { model.attempt { try model.actions.revoke(device.id) } }
            Button(Texts.Settings.cancel, role: .cancel) {}
        } message: { _ in
            Text(Texts.Settings.revokeText)
        }
        .confirmationDialog(Texts.Settings.disconnectAllTitle, isPresented: $disconnectingAll, titleVisibility: .visible) {
            Button(Texts.Settings.disconnectAllConfirm, role: .destructive) { model.attempt { try model.actions.disconnectAll() } }
            Button(Texts.Settings.cancel, role: .cancel) {}
        } message: {
            Text(Texts.Settings.disconnectAllText)
        }
        .confirmationDialog(Texts.Settings.sharedKeyOffTitle, isPresented: $droppingToken, titleVisibility: .visible) {
            Button(Texts.Settings.sharedKeyOff, role: .destructive) { model.attempt { try model.actions.setAcceptsToken(false) } }
            Button(Texts.Settings.cancel, role: .cancel) {}
        } message: {
            Text(Texts.Settings.sharedKeyOffText(tokenSessions))
        }
        .sheet(item: $editing) { device in
            DeviceSheet(model: model, device: device, revoke: {
                editing = nil
                revoking = device
            })
        }
    }

    /// Phones connected with the old token, which switching it off drops.
    private var tokenSessions: Int { state.sessions.filter { $0.device == nil }.count }
}

private struct DeviceRow: View {
    var device: Device
    var subtitle: String
    var connected: Bool
    var edit: () -> Void
    var revoke: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            RowSymbol(name: MacState.symbol(forDevice: device.name))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).fontWeight(.semibold)
                HStack(spacing: 5) {
                    if connected {
                        Circle().fill(Color.green).frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                    Text(subtitle)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button(action: edit) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(Texts.Settings.details)
            .accessibilityLabel("\(Texts.Settings.details): \(device.name)")
            Button(Texts.Settings.revoke, action: revoke)
                .accessibilityLabel("\(device.name) \(Texts.Settings.revoke)")
        }
        .padding(.vertical, 2)
    }
}

/// A device's details, and its name to change.
private struct DeviceSheet: View {
    @ObservedObject var model: MacModel
    var device: Device
    var revoke: () -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(Texts.Settings.name, text: $name)
                        .onSubmit(save)
                    LabeledContent(Texts.Settings.pairedAt, value: MacState.day(device.paired, now: model.now))
                    LabeledContent(Texts.Settings.seenAt, value: device.seen.map { MacState.day($0, now: model.now) } ?? Texts.Settings.never)
                    if let login = device.login {
                        LabeledContent(Texts.Settings.pairedFrom, value: login)
                    }
                } header: {
                    Label(device.name, systemImage: MacState.symbol(forDevice: device.name)).font(.headline)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Button(Texts.Settings.revoke, action: revoke)
                Spacer()
                Button(Texts.Settings.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(Texts.Settings.done, action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { name = device.name }
    }

    private func save() {
        if name != device.name { model.attempt { try model.actions.rename(device.id, name) } }
        dismiss()
    }
}

// MARK: Sicherheit

private struct SecurityPane: View {
    @ObservedObject var model: MacModel
    @State private var removingFaceUnlock = false
    @State private var removingServe = false
    private var state: MacState { model.state }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if state.faceUnlock {
                        Button(Texts.Settings.faceIDRemove) { removingFaceUnlock = true }
                    } else {
                        Button(Texts.Settings.faceIDSetUp) { model.actions.setUpFaceUnlock() }
                    }
                } label: {
                    Label {
                        Text(Texts.Settings.faceID)
                        Text(state.faceUnlock ? Texts.Settings.faceIDOn : Texts.Settings.faceIDOff)
                    } icon: {
                        RowSymbol(name: "faceid")
                    }
                }
            } footer: {
                Text(Texts.Settings.faceIDNote).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section(Texts.Settings.tailnet) {
                ForEach([Setup.Item.tailscale, .https, .serve], id: \.self) { item in
                    SettingsSetupRow(row: state.row(item), perform: model.actions.perform)
                }
                LabeledContent {
                    Text(state.owner.map(Texts.Settings.onlyOwner) ?? Texts.Settings.ownerUnknown).textSelection(.enabled)
                } label: {
                    // With a symbol like the rows above it, so its title stands where theirs do.
                    Label { Text(Texts.Settings.allowed) } icon: { RowSymbol(name: "person.crop.circle") }
                }
                if state.facts.tailscale?.serve?.mapping == .ours {
                    HStack {
                        Spacer()
                        Button(Texts.Settings.removeServe) { removingServe = true }
                    }
                }
            }
        }
        .confirmationDialog(Texts.Settings.faceIDRemoveTitle, isPresented: $removingFaceUnlock, titleVisibility: .visible) {
            Button(Texts.Settings.faceIDRemoveConfirm, role: .destructive) { model.actions.removeFaceUnlock() }
            Button(Texts.Settings.cancel, role: .cancel) {}
        } message: {
            Text(Texts.Settings.faceIDRemoveText)
        }
        .confirmationDialog(Texts.Settings.removeServeTitle, isPresented: $removingServe, titleVisibility: .visible) {
            Button(Texts.Settings.removeServeConfirm, role: .destructive) { model.actions.perform(.removeServe) }
            Button(Texts.Settings.cancel, role: .cancel) {}
        } message: {
            Text(Texts.Settings.removeServeText)
        }
    }
}

// MARK: Berechtigungen

private struct PermissionsPane: View {
    @ObservedObject var model: MacModel

    var body: some View {
        Form {
            Section {
                SettingsSetupRow(row: model.state.row(.accessibility), perform: model.actions.perform)
                SettingsSetupRow(row: model.state.row(.screenRecording), perform: model.actions.perform)
            } footer: {
                Text(Texts.Settings.permissionsNote).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

/// A checklist row in a settings form: its symbol, title, sentence, and its state or its key.
private struct SettingsSetupRow: View {
    var row: Setup.Row
    var perform: (Setup.Action) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            RowSymbol(name: Self.symbol(row.item))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text(row.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if row.state == .ok, row.action.map(SetupRowView.showsWhenOK) != true {
                Check.Mark(state: .done, size: Self.mark)
            } else if let action = row.action, row.state != .working {
                HStack(spacing: 8) {
                    Check.Mark(state: Check.State(row.state), size: Self.mark)
                    Button(action.title) { perform(action) }
                }
            } else {
                Check.Mark(state: Check.State(row.state), size: Self.mark)
            }
        }
        .padding(.vertical, 2)
    }

    /// A state beside a form's controls: the size of a switch's knob, not of a heading.
    static let mark: CGFloat = 17

    /// The menu's symbols, so a line looks the same in both.
    static func symbol(_ item: Setup.Item) -> String {
        switch item {
        case .accessibility: return "hand.raised"
        case .screenRecording: return "display"
        case .tailscale: return "network"
        case .https: return "lock"
        case .serve: return "point.3.filled.connected.trianglepath.dotted"
        case .pairing: return "qrcode"
        case .firstMove: return "hand.draw"
        case .loginItem: return "power"
        }
    }
}

/// A row's symbol in the settings: one size, weight and column for every row, so the titles line up.
private struct RowSymbol: View {
    var name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }
}

/// The settings window: a toolbar with the four panes, as Mac apps have.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let model: MacModel
    private(set) var window: NSWindow?
    private var tabs: NSTabViewController?
    var opened: (() -> Void)?
    var closed: (() -> Void)?

    init(model: MacModel) {
        self.model = model
    }

    var isOpen: Bool { window?.isVisible == true }

    func show(_ pane: MacModel.Pane? = nil) {
        if !isOpen { opened?() }
        let window = window ?? makeWindow()
        self.window = window
        if let pane { tabs?.selectedTabViewItemIndex = pane.rawValue }
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func makeWindow(selecting pane: MacModel.Pane = .general) -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        for pane in MacModel.Pane.allCases {
            let host = NSHostingController(rootView: SettingsPane(model: model, pane: pane))
            host.sizingOptions = .preferredContentSize
            host.title = SettingsPane.title(pane)
            let item = NSTabViewItem(viewController: host)
            item.label = SettingsPane.title(pane)
            item.image = NSImage(systemSymbolName: SettingsPane.symbol(pane), accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = pane.rawValue
        self.tabs = tabs
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        closed?()
    }
}
