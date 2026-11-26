import CoreGraphics
import Foundation

/// Everything the agent and the page say to each other. On the page each message lives in the module it serves:
/// `Web/live-view.js` reads the live view's updates, `Web/apps.js` the switcher's lists, `Web/displays.js` the list
/// of displays, `Web/passkey.js` writes what the phone's passkey says, and `Web/remote.js` sends the commands and
/// routes what arrives.
enum Wire {
    /// What the page says. A message is JSON; `t` names its kind, the other fields belong to one kind or another.
    /// What opens the socket: the first message.
    enum Credential: Equatable {
        /// From `POST /session`, for a paired device. `standalone`: the page runs from the Home Screen.
        case ticket(String, standalone: Bool)
        /// The old shared token, while the Mac still takes it.
        case token(String)
    }

    enum Command {
        case auth(Credential)
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
        /// The page asks for the open apps and their windows, see `Apps`. `have` names the icons it has
        /// already, from an earlier connection; nil if it does not say.
        case apps(have: Set<String>?)
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
        /// password kept on the Mac, and `next`, its secret for the salt `lock` named next. See `FaceUnlock`.
        case unlockWithPasskey(Passkey.Answer, secret: Data, next: Data?)
        /// The phone made a passkey for the enrolment the agent offers. `publicKey`, `authenticator` and
        /// `client` are what the browser gave the page about it, `secret` what the passkey gives out.
        case enrol(id: Data, publicKey: Data, authenticator: Data, client: Data, secret: Data)
        /// The page is alive: it says so every 5 s while it is visible, and hears `pong`.
        case ping
        /// The phone's decoder lost its state: the next picture of an H.264 stream must be a key frame.
        case keyFrame
        /// Nothing the agent acts on: an unknown kind, a missing field or one of the wrong type, a value out of range.
        case ignored
    }

    private struct Fields: Decodable {
        let t: String
        var token: String?
        var ticket: String?
        var standalone: Bool?
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
        /// What the page's controls cover of the display element: top, right, bottom, left.
        var inset: [Double]?
        var id: Int64?
        // Of a passkey, each base64url: its id, its public key, the authenticator's and the browser's data,
        // the signature, the secret, the secret for the next salt.
        var cred: String?
        var key: String?
        var auth: String?
        var client: String?
        var sig: String?
        var prf: String?
        var next: String?
        var have: [String]?
    }

    private static let decoder = JSONDecoder()

    /// Throws for anything that is not a JSON object.
    static func command(from data: Data) throws -> Command {
        let m = try fields(from: data)
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
        // A ticket counts before a token: a page that sends both is a paired one.
        case "auth": m.ticket.map { .auth(.ticket($0, standalone: m.standalone == true)) } ?? m.token.map { .auth(.token($0)) }
        case "m": delta.map { .move(dx: $0.dx, dy: $0.dy, sequence: m.q) }
        case "s": delta.map { .scroll(dx: $0.dx, dy: $0.dy) }
        case "se": .scrollEnded
        case "c": .click(button, mods: m.mods ?? [])
        case "b": m.d.map { .button(button, down: $0, mods: m.mods ?? []) }
        case "text": m.s.flatMap { $0.count <= 2000 ? .text($0) : nil }
        case "key": if let key = m.k, let mods = m.mods, let count = m.n { .key(key, mods: mods, count: count) } else { nil }
        case "media": m.k.map { .media($0) }
        // A request to switch it on that lacks a field is refused, not taken as one to switch it off.
        case "view": m.on == true ? view(m).map { .view($0) } : .view(nil)
        case "shown": m.n.flatMap(UInt32.init(exactly:)).map { .shown($0) }
        case "apps": .apps(have: m.have.map { Set($0.prefix(256)) })
        case "focus": m.pid.flatMap { $0 > 0 ? .focus(pid: $0, window: m.win) : nil }
        case "displays": .displays
        case "display": m.id.flatMap(UInt32.init(exactly:)).map { .display($0) }
        case "unlock":
            if let password = m.s {
                (1...256).contains(password.count) ? .unlock(password) : nil
            } else if let authenticator = bytes(m.auth), let client = bytes(m.client), let signature = bytes(m.sig),
                      let secret = bytes(m.prf) {
                .unlockWithPasskey(Passkey.Answer(authenticator: authenticator, client: client, signature: signature),
                                   secret: secret, next: bytes(m.next))
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
        case "ping": .ping
        case "idr": .keyFrame
        default: nil
        }
        return command ?? .ignored
    }

    private struct NotAnObject: Error {}

    /// What a message calls itself, for a log that must not hold what the message carries.
    static func kind(of data: Data) -> String {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["t"] as? String ?? "?"
    }

    /// The fields of a message. One of the wrong type counts as missing, so it costs only a message of a kind
    /// that needs it, not the connection; so does a kind that is not a string.
    private static func fields(from data: Data) throws -> Fields {
        if let fields = try? decoder.decode(Fields.self, from: data) { return fields }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NotAnObject() }
        func decode(_ object: [String: Any]) throws -> Fields {
            try decoder.decode(Fields.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let kind = object["t"] as? String ?? ""
        object["t"] = kind
        // Field by field: a number out of range fails without naming its field.
        object = object.filter { key, value in key == "t" || (try? decode(["t": kind, key: value])) != nil }
        return try decode(object)
    }

    private static func view(_ m: Fields) -> ScreenView.Request? {
        guard m.on == true, let width = m.w, let height = m.h, let zoom = m.zoom, let pixelRatio = m.dpr,
              let codec = m.codec, let fps = m.fps else { return nil }
        // Anything but four margins covers nothing; `Request` bounds each.
        let inset = m.inset.flatMap { $0.count == 4 ? ScreenView.Inset(top: $0[0], right: $0[1], bottom: $0[2], left: $0[3]) : nil }
        return ScreenView.Request(width: width, height: height, zoom: zoom, pixelRatio: pixelRatio, h264: codec == "h264",
                                  fps: fps, fit: m.fit == "window", shape: m.shape, number: m.v ?? 0, inset: inset ?? .zero)
    }

    /// The ticket or the token was right. `page` is `Web.version`: a page that was loaded from an older agent
    /// reloads itself. `mac` is the Mac's name, `device` the name this phone paired under; nil with the old token.
    static func accepted(accessibility: Bool, page: String, mac: String, device: String?) -> String {
        #"{"t":"ok","ax":\#(accessibility),"page":\#(quoted(page)),"name":\#(quoted(mac)),"device":\#(device.map(quoted) ?? "null")}"#
    }

    enum Denial: String, Error {
        /// The device was revoked at the Mac: it pairs again.
        case revoked
        /// Unknown, used or expired: the page asks for another.
        case ticket
        /// Not the token, or the Mac no longer takes the old token.
        case token
    }

    static func denied(_ why: Denial) -> String { #"{"t":"denied","why":"\#(why.rawValue)"}"# }

    /// What the Mac allows now: after `accepted`, and again whenever one of them changes. While `paused`, the
    /// Mac takes no input and shows no live view, and every phone stays paired.
    static func mac(accessibility: Bool, screen: Bool, paused: Bool) -> String {
        #"{"t":"mac","ax":\#(accessibility),"screen":\#(screen),"paused":\#(paused)}"#
    }

    /// The live view is off while remote control is paused at the Mac.
    static let viewPaused = #"{"t":"view","ok":false,"why":"paused"}"#

    /// The live view needs the Screen Recording permission.
    static let viewRefused = #"{"t":"view","ok":false,"why":"permission"}"#

    /// Another phone took the live view: this one gets no more pictures.
    static let viewTaken = #"{"t":"view","ok":false,"why":"taken"}"#

    /// The answer to `ping`.
    static let pong = #"{"t":"pong"}"#

    /// The Mac's user ended this session. The page does not connect again until its user asks for it.
    static let bye = #"{"t":"bye"}"#

    /// Whether the Mac's lock screen is up. Follows `accepted`, and comes again whenever it changes. With a
    /// phone enrolled for Face ID, a locked Mac names the passkey to ask for, the salt of the secret that
    /// opens the password and a challenge, which counts for one `unlock` on this connection; the next one
    /// comes with another `lock`. `next` is a fresh salt: the passkey's secret for it seals the password once
    /// this try has opened the Mac.
    static func lock(_ on: Bool, passkey: (key: FaceUnlock.Key, ask: FaceUnlock.Ask)? = nil) -> String {
        guard on, let passkey else { return #"{"t":"lock","on":\#(on)}"# }
        return #"{"t":"lock","on":true,"key":{"id":"\#(passkey.key.passkey.id.base64URL)","#
            + #""salt":"\#(passkey.key.salt.base64URL)","next":"\#(passkey.ask.next.base64URL)","#
            + #""challenge":"\#(passkey.ask.challenge.base64URL)"}}"#
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

    /// A string as JSON writes it, quotes and all.
    private static func quoted(_ text: String) -> String {
        String(decoding: (try? JSONEncoder().encode(text)) ?? Data(#""""#.utf8), as: UTF8.self)
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
    static let headerSize = 47

    /// One binary message, little endian: UInt8 kind (0 pointer only, 1 JPEG, 2 H.264), UInt8 frames per second,
    /// UInt8 flags (1: the view follows the text caret, 2: it is fitted to the window in front), Float32 pointer x
    /// and y, Float32 focus x and y, Float32 width and height of the view, Float32 its left and top edge, UInt32
    /// sequence, UInt32 number of the view request, UInt32 picture number, then the picture.
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
        let floats = [pointer.x, pointer.y, focus.x, focus.y, view.width, view.height, view.minX, view.minY]
        for value in floats.map({ Float32($0).bitPattern }) + [sequence, request, picture?.number ?? 0] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(payload)
        return data
    }
}
