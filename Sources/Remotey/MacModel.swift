import Combine
import Foundation

/// The state the views show and what their keys do. `AppDelegate` keeps `state` current from the server and
/// the setup assistant and supplies the actions; a picture or a test gives a made-up state and no actions.
final class MacModel: ObservableObject {
    /// Settings panes, in the order of the toolbar.
    enum Pane: Int, CaseIterable {
        case general, phones, security, permissions
    }

    /// What the keys do. Each one that writes a file can fail: the model then says so in `problem`.
    struct Actions {
        var setPaused: (Bool) throws -> Void = { _ in }
        var end: (Server.Session.ID) -> Void = { _ in }
        var perform: (Setup.Action) -> Void = { _ in }
        var addPhone: () -> Void = {}
        var openAssistant: () -> Void = {}
        var setUpFaceUnlock: () -> Void = {}
        var removeFaceUnlock: () -> Void = {}
        var openSettings: (Pane?) -> Void = { _ in }
        var quit: () -> Void = {}
        var rename: (Device.ID, String) throws -> Void = { _, _ in }
        var revoke: (Device.ID) throws -> Void = { _ in }
        var disconnectAll: () throws -> Void = {}
        var setAcceptsToken: (Bool) throws -> Void = { _ in }
        /// Closes the menu panel before a key in it opens something else, as a menu closes.
        var closeMenu: () -> Void = {}
    }

    /// A key that did not do what it says, in words for an alert.
    struct Problem: Equatable, Identifiable {
        var title: String
        var text: String
        var id: String { title + text }
    }

    @Published var state: MacState
    @Published var problem: Problem?
    /// The clock the views count from: the menu and the settings show times relative to it.
    @Published var now: Date
    let actions: Actions

    init(state: MacState = MacState(), now: Date = Date(), actions: Actions = Actions()) {
        self.state = state
        self.now = now
        self.actions = actions
    }

    /// Runs a key that writes; a failure is shown, not thrown.
    func attempt(_ title: String = Texts.Problem.notSaved, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            problem = Problem(title: title, text: "\(error)")
        }
    }
}
