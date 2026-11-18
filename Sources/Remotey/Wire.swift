import CoreGraphics
import Foundation

/// Everything the agent and the page say to each other. On the page each message lives in the module it serves:
/// `Web/live-view.js` reads the live view's updates, `Web/apps.js` the switcher's lists, `Web/displays.js` the list
/// of displays, `Web/passkey.js` writes what the phone's passkey says, and `Web/remote.js` sends the commands and
/// routes what arrives.
enum Wire {
    /// What the page says. A message is JSON; `t` names its kind, the other fields belong to one kind or another.
    enum Command {
        case auth(token: String)
        /// `sequence` numbers the move, so that the page can time it until a `LiveUpdate` includes it.
        case move(dx: Double, dy: Double, sequence: UInt32?)
        /// Part of a two-finger scroll; the first one after `scrollEnded` begins a new gesture.
        case scroll(dx: Double, dy: Double)
        case scrollEnded
        /// `mods` are the modifiers held during the click, named as for `key`. Besides left and right, the page
        /// clicks a mouse's side buttons, `back` and `forward`.
        case click(CGMouseButton, mods: [String])
        /// A press names its `mods`; the agent keeps them until the release.
        case button(CGMouseButton, down: Bool, mods: [String])
        case text(String)
        case key(String, mods: [String], count: Int)
        case media(String)
        /// Nil switches the live view off. The page asks for 30 to 120 frames per second, as it measures its display,
        /// and numbers its requests: every update names the one it was cut for. With `fit` set to `window` the
        /// agent picks the region itself, around the window in front; `zoom` counts where there is none. With
        /// `shape`, a zoom, that window also takes the phone's shape, at the size that shows at this zoom.
        case view(ScreenView.Request?)
        /// The page has drawn or discarded the picture with this number.
        case shown(UInt32)
        /// The page asks for the open apps and their windows, see `Apps`.
        case apps
        /// Brings an app to the front. `window` names one of its windows by its id in the list; without it the
        /// app comes forward as after a click in the Dock.
        case focus(pid: Int32, window: Int?)
        /// The page asks for the Mac's displays, see `Displays`, and hears of every change to them from then on.
        case displays
        /// Puts the pointer on the display with this id in the list.
        case display(CGDirectDisplayID)
        /// The password of the Mac's user, for the lock screen. See `LockScreen`.
        case unlock(String)
        /// The phone's passkey answers the challenge of the last `lock`, with the secret that opens the
        /// password kept on the Mac. See `FaceUnlock`.
        case unlockWithPasskey(Passkey.Answer, secret: Data)
        /// The phone made a passkey for the enrolment the agent offers. `publicKey`, `authenticator` and
        /// `client` are what the browser gave the page about it, `secret` what the passkey gives out.
        case enrol(id: Data, publicKey: Data, authenticator: Data, client: Data, secret: Data)
        /// Nothing the agent acts on: an unknown kind, a missing field, a value out of range.
        case ignored
    }

    private struct Fields: Decodable {
        let t: String
        var token: String?
        var dx: Double?
        var dy: Double?
        var b: String?
        var d: Bool?
        var s: String?
        var k: String?
        var n: Int?
        var mods: [String]?
        var on: Bool?
        var w: Double?
        var h: Double?
        var zoom: Double?
        var dpr: Double?
        var codec: String?
        var fps: Int?
        var q: UInt32?
        var v: UInt32?
        var pid: Int32?
        var win: Int?
        var fit: String?
        var shape: Double?
        var id: Int64?
        // Of a passkey, each base64url: its id, its public key, the authenticator's and the browser's data,
        // the signature, the secret.
        var cred: String?
        var key: String?
        var auth: String?
        var client: String?
        var sig: String?
        var prf: String?
    }

    private static let decoder = JSONDecoder()

    /// Throws for anything that is not a message at all.
    static func command(from data: Data) throws -> Command {
        let m = try decoder.decode(Fields.self, from: data)
        var delta: (dx: Double, dy: Double)? {
            guard let dx = m.dx, let dy = m.dy, dx.isFinite, dy.isFinite, abs(dx) <= 5000, abs(dy) <= 5000 else { return nil }
            return (dx, dy)
        }
        let button: CGMouseButton = switch m.b {
        case "right": .right
        case "back": .back
        case "forward": .forward
        default: .left
        }
        func bytes(_ text: String?) -> Data? {
            guard let text, text.count <= 4096, let data = Data(base64URL: text), !data.isEmpty else { return nil }
            return data
        }
        let command: Command? = switch m.t {
        case "auth": m.token.map { .auth(token: $0) }
        case "m": delta.map { .move(dx: $0.dx, dy: $0.dy, sequence: m.q) }
        case "s": delta.map { .scroll(dx: $0.dx, dy: $0.dy) }
        case "se": .scrollEnded
        case "c": .click(button, mods: m.mods ?? [])
        case "b": m.d.map { .button(button, down: $0, mods: m.mods ?? []) }
        case "text": m.s.flatMap { $0.count <= 2000 ? .text($0) : nil }
        case "key": if let key = m.k, let mods = m.mods, let count = m.n { .key(key, mods: mods, count: count) } else { nil }
        case "media": m.k.map { .media($0) }
        case "view": .view(view(m))
        case "shown": m.n.flatMap(UInt32.init(exactly:)).map { .shown($0) }
        case "apps": .apps
        case "focus": m.pid.flatMap { $0 > 0 ? .focus(pid: $0, window: m.win) : nil }
        case "displays": .displays
        case "display": m.id.flatMap(UInt32.init(exactly:)).map { .display($0) }
        case "unlock":
            if let password = m.s {
                (1...256).contains(password.count) ? .unlock(password) : nil
            } else if let authenticator = bytes(m.auth), let client = bytes(m.client), let signature = bytes(m.sig),
                      let secret = bytes(m.prf) {
                .unlockWithPasskey(Passkey.Answer(authenticator: authenticator, client: client, signature: signature),
                                   secret: secret)
            } else {
                nil
            }
        case "enrol":
            if let id = bytes(m.cred), let publicKey = bytes(m.key), let authenticator = bytes(m.auth),
               let client = bytes(m.client), let secret = bytes(m.prf) {
                .enrol(id: id, publicKey: publicKey, authenticator: authenticator, client: client, secret: secret)
            } else {
                nil
            }
        default: nil
        }
        return command ?? .ignored
    }

    private static func view(_ m: Fields) -> ScreenView.Request? {
        guard m.on == true, let width = m.w, let height = m.h, let zoom = m.zoom, let pixelRatio = m.dpr,
              let codec = m.codec, let fps = m.fps else { return nil }
        return ScreenView.Request(width: width, height: height, zoom: zoom, pixelRatio: pixelRatio, h264: codec == "h264",
                                  fps: fps, fit: m.fit == "window", shape: m.shape, number: m.v ?? 0)
    }

    /// The token was right. `page` is `Web.version`: a page that was loaded from an older agent reloads itself.
    static func accepted(accessibility: Bool, page: String) -> String {
        #"{"t":"ok","ax":\#(accessibility),"page":"\#(page)"}"#
    }

    static let denied = #"{"t":"denied"}"#

    /// The live view needs the Screen Recording permission.
    static let viewRefused = #"{"t":"view","ok":false}"#

    /// Whether the Mac's lock screen is up. Follows `accepted`, and comes again whenever it changes. With a
    /// phone enrolled for Face ID, a locked Mac names the passkey to ask for and gives it a challenge, which
    /// counts for one `unlock` on this connection; the next one comes with another `lock`.
    static func lock(_ on: Bool, passkey: (key: FaceUnlock.Key, challenge: Data)? = nil) -> String {
        guard on, let passkey else { return #"{"t":"lock","on":\#(on)}"# }
        return #"{"t":"lock","on":true,"key":{"id":"\#(passkey.key.passkey.id.base64URL)","#
            + #""salt":"\#(passkey.key.salt.base64URL)","challenge":"\#(passkey.challenge.base64URL)"}}"#
    }

    /// The Mac is still locked after an `unlock`. One that unlocks says so with `lock`.
    static func unlockFailed(_ failure: LockScreen.Failure) -> String {
        #"{"t":"unlock","ok":false,"why":"\#(failure.rawValue)"}"#
    }

    /// An `unlock` by passkey that the agent did not take: not the passkey's answer to the last challenge,
    /// or its secret does not open the password. Nothing was typed.
    static let passkeyRefused = #"{"t":"unlock","ok":false,"why":"key"}"#

    /// The agent offers to enrol this phone for Face ID, started from its menu: the page makes a passkey
    /// for the challenge, named after the Mac, and answers with `enrol`. Nil: the offer is over.
    static func enrolment(_ offer: FaceUnlock.Offer?, mac: String) -> String {
        struct Message: Encodable {
            let t = "enrol"
            let challenge: String
            let salt: String
            let name: String
        }
        guard let offer else { return #"{"t":"enrol","off":true}"# }
        return json(Message(challenge: offer.challenge.base64URL, salt: offer.salt.base64URL, name: mac))
    }

    /// How an `enrol` ended. A phone that is enrolled ends the offer for every other one too.
    static func enrolled(_ ok: Bool) -> String { #"{"t":"enrolled","ok":\#(ok)}"# }

    /// The open apps and their windows, front to back.
    static func apps(_ list: [Apps.App]) -> String {
        struct Message: Encodable {
            let t = "apps"
            let list: [Apps.App]
        }
        return json(Message(list: list))
    }

    /// The icon the list names `id`, sent once per connection.
    static func icon(_ id: String, png: Data) -> String {
        struct Message: Encodable {
            let t = "icon"
            let id: String
            let png: Data
        }
        return json(Message(id: id, png: png))
    }

    /// The displays as they are arranged, and which one holds the pointer.
    static func displays(_ list: [Displays.Display]) -> String {
        struct Message: Encodable {
            let t = "displays"
            let list: [Displays.Display]
        }
        return json(Message(list: list))
    }

    /// For messages that carry text from outside the agent: names of apps and displays, titles of windows.
    private static func json(_ message: some Encodable) -> String {
        String(decoding: (try? JSONEncoder().encode(message)) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// The pointer's picture, which the page draws at the place every `LiveUpdate` names. Sizes are in points.
    static func cursor(_ picture: Pointer.Picture) -> String? {
        picture.png.map {
            #"{"t":"cursor","png":"\#($0.base64EncodedString())","w":\#(Double(picture.size.width)),"#
                + #""h":\#(Double(picture.size.height)),"x":\#(Double(picture.hotSpot.x)),"y":\#(Double(picture.hotSpot.y))}"#
        }
    }
}

extension LiveUpdate {
    static let headerSize = 35

    /// One binary message, little endian: UInt8 kind (0 pointer only, 1 JPEG, 2 H.264), UInt8 frames per second,
    /// UInt8 flags (1: the view follows the text caret, 2: it is fitted to the window in front), Float32 pointer x
    /// and y, Float32 focus x and y, Float32 width, UInt32 sequence, UInt32 number of the view request, UInt32
    /// picture number, then the picture.
    var data: Data {
        let (kind, payload): (UInt8, Data) = switch picture?.content {
        case nil: (0, Data())
        case .jpeg(let data): (1, data)
        case .h264(let data): (2, data)
        }
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(kind)
        data.append(UInt8(clamping: framesPerSecond))
        data.append((followsText ? 1 : 0) | (fitted ? 2 : 0))
        for value in [Float32(pointer.x).bitPattern, Float32(pointer.y).bitPattern, Float32(focus.x).bitPattern,
                      Float32(focus.y).bitPattern, Float32(width).bitPattern, sequence, request, picture?.number ?? 0] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(payload)
        return data
    }
}
