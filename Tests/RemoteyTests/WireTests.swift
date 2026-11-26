import XCTest
@testable import Remotey

/// The layout Web/live-view.js reads. scripts/live-view.test.mjs builds the same bytes for the page's half.
final class WireTests: XCTestCase {
    func testLayoutOfAnUpdateWithAPicture() {
        let update = LiveUpdate(pointer: CGPoint(x: 0.5, y: 0.25), focus: CGPoint(x: 0.75, y: 1.5), followsText: true,
                                fitted: false, request: 9, view: CGRect(x: -1200, y: 300, width: 614, height: 921), framesPerSecond: 120, sequence: 0x0102_0304,
                                picture: (number: 7, content: .h264(Data([66, 192, 31, 1]))))
        let data = update.data
        func float(_ offset: Int) -> Float32 {
            Float32(bitPattern: data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        }
        XCTAssertEqual(Array(data[0..<3]), [2, 120, 1])
        XCTAssertEqual([float(3), float(7), float(11), float(15)], [0.5, 0.25, 0.75, 1.5])
        XCTAssertEqual([float(19), float(23), float(27), float(31)], [614, 921, -1200, 300], "the view: its size, then its place")
        XCTAssertEqual(Array(data[35..<47]), [4, 3, 2, 1, 9, 0, 0, 0, 7, 0, 0, 0])
        XCTAssertEqual(Array(data[LiveUpdate.headerSize...]), [66, 192, 31, 1])
    }

    func testKinds() {
        var update = LiveUpdate(pointer: .zero, focus: .zero, followsText: false, fitted: false, request: 0, view: CGRect(x: 0, y: 0, width: 614, height: 0),
                                framesPerSecond: 60, sequence: 1, picture: nil)
        XCTAssertEqual(Array(update.data), [0, 60, 0] + [UInt8](repeating: 0, count: 16) + [0, 0x80, 0x19, 0x44]
                       + [UInt8](repeating: 0, count: 12) + [1, 0, 0, 0] + [UInt8](repeating: 0, count: 8),
                       "only the pointer moved: a header and nothing else")
        update.picture = (number: 1, content: .jpeg(Data([0xff, 0xd8])))
        XCTAssertEqual(update.data[0], 1)
        XCTAssertEqual(update.data.count, LiveUpdate.headerSize + 2)
    }

    func testFlagsSayWhatTheViewIsCutAround() {
        var update = LiveUpdate(pointer: .zero, focus: .zero, followsText: false, fitted: true, request: 0, view: CGRect(x: 0, y: 0, width: 614, height: 0),
                                framesPerSecond: 60, sequence: 1, picture: nil)
        XCTAssertEqual(update.data[2], 2, "fitted to the window in front")
        update.followsText = true
        XCTAssertEqual(update.data[2], 3, "and showing the text typed into it")
    }

    func testTextMessagesAreJSON() throws {
        func object(_ text: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let accepted = try object(Wire.accepted(accessibility: true, page: "abc", mac: #"Yannicks "Mac""#, device: "iPhone"))
        XCTAssertEqual(accepted["t"] as? String, "ok")
        XCTAssertEqual(accepted["ax"] as? Bool, true)
        XCTAssertEqual(accepted["page"] as? String, "abc")
        XCTAssertEqual(accepted["name"] as? String, #"Yannicks "Mac""#, "a name with quotes stays a string")
        XCTAssertEqual(accepted["device"] as? String, "iPhone")
        let byToken = try object(Wire.accepted(accessibility: false, page: "abc", mac: "Mac", device: nil))
        XCTAssertTrue(byToken["device"] is NSNull, "null, not missing, with the old token")
        XCTAssertEqual(try object(Wire.denied(.revoked)) as NSDictionary, ["t": "denied", "why": "revoked"])
        XCTAssertEqual(try object(Wire.denied(.ticket)) as NSDictionary, ["t": "denied", "why": "ticket"])
        XCTAssertEqual(try object(Wire.denied(.token)) as NSDictionary, ["t": "denied", "why": "token"])
        XCTAssertEqual(try object(Wire.mac(accessibility: true, screen: false, paused: true)) as NSDictionary,
                       ["t": "mac", "ax": true, "screen": false, "paused": true])
        XCTAssertEqual(try object(Wire.viewPaused) as NSDictionary, ["t": "view", "ok": false, "why": "paused"])
        XCTAssertEqual(try object(Wire.viewRefused)["ok"] as? Bool, false)
        XCTAssertEqual(try object(Wire.lock(true)) as NSDictionary, ["t": "lock", "on": true])
        XCTAssertEqual(try object(Wire.lock(false))["on"] as? Bool, false)
        XCTAssertEqual(try object(Wire.unlockFailed(.password)) as NSDictionary, ["t": "unlock", "ok": false, "why": "password"])
        XCTAssertEqual(try object(Wire.unlockFailed(.field))["why"] as? String, "field")
        let picture = Pointer.Picture(pixels: Data(repeating: 255, count: 4 * 6 * 9), width: 6, height: 9,
                                      size: CGSize(width: 2, height: 3), hotSpot: CGPoint(x: 1, y: 0.5))
        let cursor = try object(try XCTUnwrap(Wire.cursor(picture)))
        XCTAssertEqual(cursor["t"] as? String, "cursor")
        XCTAssertEqual([cursor["w"], cursor["h"], cursor["x"], cursor["y"]].map { $0 as? Double }, [2, 3, 1, 0.5])
        let png = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(cursor["png"] as? String)))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4e, 0x47])
    }

    /// Names and titles come from apps and web pages: whatever they hold, the message stays one JSON object.
    func testALockedMacNamesThePasskeyAndAnOfferNamesTheMac() throws {
        func object(_ text: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let key = FaceUnlock.Key(passkey: Passkey(id: Data([251, 255]), publicKey: Data([1]), origin: "https://mac.example.ts.net:8443"),
                                 salt: Data([1, 2]), sealed: Data([9]))
        let ask = FaceUnlock.Ask(challenge: Data([3, 4]), next: Data([7]))
        let locked = try object(Wire.lock(true, passkey: (key, ask)))
        XCTAssertEqual(locked as NSDictionary, ["t": "lock", "on": true, "key": ["id": "-_8", "salt": "AQI", "next": "Bw", "challenge": "AwQ"]])
        XCTAssertEqual(try object(Wire.lock(false, passkey: (key, ask))) as NSDictionary, ["t": "lock", "on": false],
                       "an open Mac asks for no passkey")
        XCTAssertEqual(try object(Wire.passkeyRefused) as NSDictionary, ["t": "unlock", "ok": false, "why": "key"])
        let offer = FaceUnlock.Offer(challenge: Data([5]), salt: Data([6]))
        XCTAssertEqual(try object(Wire.enrolment(offer, mac: #"Annas "Mac""#)) as NSDictionary,
                       ["t": "enrol", "challenge": "BQ", "salt": "Bg", "name": #"Annas "Mac""#])
        XCTAssertEqual(try object(Wire.enrolment(nil, mac: "")) as NSDictionary, ["t": "enrol", "off": true])
        XCTAssertEqual(try object(Wire.enrolled(true)) as NSDictionary, ["t": "enrolled", "ok": true])
    }

    func testThePasskeysMessagesOfThePage() throws {
        func command(_ json: String) throws -> Wire.Command { try Wire.command(from: Data(json.utf8)) }
        guard case .unlockWithPasskey(let answer, let secret, let next) =
            try command(#"{"t":"unlock","auth":"AQI","client":"Aw","sig":"BA","prf":"BQ","next":"Bg"}"#) else {
            return XCTFail("not an unlock by passkey")
        }
        XCTAssertEqual(answer, Passkey.Answer(authenticator: Data([1, 2]), client: Data([3]), signature: Data([4])))
        XCTAssertEqual(secret, Data([5]))
        XCTAssertEqual(next, Data([6]))
        for (json, why) in [(#"{"t":"unlock","auth":"AQI","client":"Aw","sig":"BA","prf":"BQ"}"#, "from a page that asks for one secret"),
                            (#"{"t":"unlock","auth":"AQI","client":"Aw","sig":"BA","prf":"BQ","next":"!"}"#, "a second secret that is none")] {
            guard case .unlockWithPasskey(_, Data([5]), nil) = try command(json) else { return XCTFail(why) }
        }
        guard case .unlock("geheim") = try command(#"{"t":"unlock","s":"geheim","auth":"AQI","client":"Aw","sig":"BA","prf":"BQ"}"#) else {
            return XCTFail("a typed password counts as one")
        }
        guard case .enrol(let id, let publicKey, let authenticator, let client, let prf) =
            try command(#"{"t":"enrol","cred":"AQ","key":"Ag","auth":"Aw","client":"BA","prf":"BQ"}"#) else { return XCTFail("not an enrol") }
        XCTAssertEqual([id, publicKey, authenticator, client, prf], [1, 2, 3, 4, 5].map { Data([$0]) })
        for json in [#"{"t":"unlock","auth":"AQI","client":"Aw","sig":"BA"}"#, #"{"t":"unlock","auth":"AQI","client":"Aw","sig":"!","prf":"BQ"}"#,
                     #"{"t":"unlock","auth":"","client":"Aw","sig":"BA","prf":"BQ"}"#, #"{"t":"enrol","cred":"AQ","key":"Ag","auth":"Aw","client":"BA"}"#,
                     #"{"t":"unlock","auth":"\#(String(repeating: "A", count: 4100))","client":"Aw","sig":"BA","prf":"BQ"}"#] {
            guard case .ignored = try command(json) else { return XCTFail(json) }
        }
    }

    func testTheListOfAppsIsJSONWhateverATitleHolds() throws {
        let title = #"He said "hi" \ </script>"# + "\n🎉"
        let list = [
            Apps.App(pid: 412, name: "Safari", icon: "com.apple.Safari", front: true, hidden: false,
                     windows: [Apps.Window(id: 7, title: title, minimized: true, main: true)]),
            Apps.App(pid: 9, name: "Finder", icon: "com.apple.finder", front: false, hidden: true, windows: []),
        ]
        let data = Data(Wire.apps(list).utf8)
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(message["t"] as? String, "apps")
        let apps = try XCTUnwrap(message["list"] as? [[String: Any]])
        XCTAssertEqual(apps.map { $0["name"] as? String }, ["Safari", "Finder"])
        XCTAssertEqual(apps.map { $0["pid"] as? Int }, [412, 9])
        XCTAssertEqual(apps.map { $0["icon"] as? String }, ["com.apple.Safari", "com.apple.finder"])
        XCTAssertEqual(apps.map { $0["front"] as? Bool }, [true, false])
        XCTAssertEqual(apps.map { $0["hidden"] as? Bool }, [false, true])
        let window = try XCTUnwrap((apps[0]["windows"] as? [[String: Any]])?.first)
        XCTAssertEqual(window["id"] as? Int, 7)
        XCTAssertEqual(window["title"] as? String, title)
        XCTAssertEqual(window["min"] as? Bool, true)
        XCTAssertEqual(window["main"] as? Bool, true)
        XCTAssertEqual((apps[1]["windows"] as? [Any])?.count, 0)
    }

    func testTheListOfDisplaysNamesTheirPlacesAndThePointers() throws {
        let list = [
            Displays.Display(id: 1, name: #"Built-in "Retina""#, x: 0, y: 0, w: 2056, h: 1329, pointer: false),
            Displays.Display(id: 69_734_662, name: "Studio Display", x: -1939, y: 1329, w: 3008, h: 1692, pointer: true),
        ]
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Wire.displays(list).utf8)) as? [String: Any])
        XCTAssertEqual(message["t"] as? String, "displays")
        let displays = try XCTUnwrap(message["list"] as? [[String: Any]])
        XCTAssertEqual(displays.map { $0["id"] as? Int }, [1, 69_734_662])
        XCTAssertEqual(displays.map { $0["name"] as? String }, [#"Built-in "Retina""#, "Studio Display"])
        XCTAssertEqual(displays.map { $0["pointer"] as? Bool }, [false, true])
        XCTAssertEqual(["x", "y", "w", "h"].map { displays[1][$0] as? Double }, [-1939, 1329, 3008, 1692])
        XCTAssertEqual(Set(displays[0].keys), ["id", "name", "x", "y", "w", "h", "pointer"])
    }

    func testAnIconTravelsAsPNGUnderItsName() throws {
        let png = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        let data = Data(Wire.icon(#"com.example."odd""#, png: png).utf8)
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(message["t"] as? String, "icon")
        XCTAssertEqual(message["id"] as? String, #"com.example."odd""#)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(message["png"] as? String)), png)
    }

    private func message(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func command(_ json: String) throws -> Wire.Command {
        try Wire.command(from: Data(json.utf8))
    }

    func testCommandsOfThePage() throws {
        guard case .auth(.token("abc")) = try command(#"{"t":"auth","token":"abc"}"#) else { return XCTFail("auth") }
        guard case .auth(.ticket("t1", standalone: true)) = try command(#"{"t":"auth","ticket":"t1","standalone":true}"#) else { return XCTFail("ticket") }
        guard case .auth(.ticket("t1", standalone: false)) = try command(#"{"t":"auth","ticket":"t1"}"#) else { return XCTFail("ticket in a tab") }
        guard case .auth(.ticket("t1", standalone: false)) = try command(#"{"t":"auth","ticket":"t1","token":"abc"}"#) else { return XCTFail("a ticket first") }
        guard case .ignored = try command(#"{"t":"auth"}"#) else { return XCTFail("auth without either") }
        guard case .move(dx: 3.5, dy: -2, sequence: 7) = try command(#"{"t":"m","dx":3.5,"dy":-2,"q":7}"#) else { return XCTFail("move") }
        guard case .move(dx: 1, dy: 1, sequence: nil) = try command(#"{"t":"m","dx":1,"dy":1}"#) else { return XCTFail("move without a number") }
        guard case .scroll(dx: 0, dy: 12) = try command(#"{"t":"s","dx":0,"dy":12}"#) else { return XCTFail("scroll") }
        guard case .scrollEnded = try command(#"{"t":"se"}"#) else { return XCTFail("end of a scroll") }
        guard case .click(.right, mods: []) = try command(#"{"t":"c","b":"right"}"#) else { return XCTFail("click") }
        guard case .click(.left, mods: ["alt"]) = try command(#"{"t":"c","b":"left","mods":["alt"]}"#) else { return XCTFail("click with a modifier") }
        guard case .click(.back, mods: []) = try command(#"{"t":"c","b":"back"}"#) else { return XCTFail("back") }
        guard case .click(.forward, mods: ["cmd"]) = try command(#"{"t":"c","b":"forward","mods":["cmd"]}"#) else { return XCTFail("forward") }
        guard case .button(.left, down: true, mods: ["cmd", "shift"]) = try command(#"{"t":"b","b":"left","d":true,"mods":["cmd","shift"]}"#) else { return XCTFail("button") }
        guard case .button(.left, down: false, mods: []) = try command(#"{"t":"b","b":"left","d":false}"#) else { return XCTFail("release") }
        guard case .text("hä") = try command(#"{"t":"text","s":"hä"}"#) else { return XCTFail("text") }
        guard case .key("w", mods: ["cmd"], count: 2) = try command(#"{"t":"key","k":"w","mods":["cmd"],"n":2}"#) else { return XCTFail("key") }
        guard case .media("play") = try command(#"{"t":"media","k":"play"}"#) else { return XCTFail("media") }
        guard case .shown(41) = try command(#"{"t":"shown","n":41}"#) else { return XCTFail("shown") }
        guard case .apps = try command(#"{"t":"apps"}"#) else { return XCTFail("apps") }
        guard case .focus(pid: 412, window: 7) = try command(#"{"t":"focus","pid":412,"win":7}"#) else { return XCTFail("focus a window") }
        guard case .focus(pid: 412, window: nil) = try command(#"{"t":"focus","pid":412}"#) else { return XCTFail("focus an app") }
        guard case .displays = try command(#"{"t":"displays"}"#) else { return XCTFail("displays") }
        guard case .display(69734662) = try command(#"{"t":"display","id":69734662}"#) else { return XCTFail("display") }
        guard case .unlock(#"pä"ss \wort"#) = try command(#"{"t":"unlock","s":"pä\"ss \\wort"}"#) else { return XCTFail("unlock") }
    }

    func testViewRequest() throws {
        let on = #"{"t":"view","on":true,"w":390,"h":844,"zoom":0.5,"dpr":3,"codec":"h264","fps":120,"v":4}"#
        guard case .view(let request?) = try command(on) else { return XCTFail("view on") }
        XCTAssertEqual(request, ScreenView.Request(width: 390, height: 844, zoom: 0.5, pixelRatio: 3, h264: true, fps: 120, number: 4))
        guard case .view(let jpeg?) = try command(on.replacingOccurrences(of: "h264", with: "jpeg")) else { return XCTFail("jpeg") }
        XCTAssertFalse(jpeg.h264)
        XCTAssertFalse(request.fit, "the region around the pointer, unless the page asks for the window")
        // A mode instead of a number: the agent picks the region. The zoom stays for a Mac that shows no window.
        guard case .view(let fitted?) = try command(on.replacingOccurrences(of: #""v":4"#, with: #""fit":"window","v":5"#)) else { return XCTFail("fit") }
        XCTAssertEqual(fitted, ScreenView.Request(width: 390, height: 844, zoom: 0.5, pixelRatio: 3, h264: true, fps: 120, fit: true, number: 5))
        guard case .view(let unknown?) = try command(on.replacingOccurrences(of: #""v":4"#, with: #""fit":"moon""#)) else { return XCTFail("unknown mode") }
        XCTAssertFalse(unknown.fit)
        XCTAssertNil(fitted.shape, "the windows on the Mac stay as they are, unless the page asks")
        // The window in front is to take the phone's shape, at the size that shows at this zoom.
        func shaped(_ fields: String) throws -> ScreenView.Request? {
            guard case .view(let request) = try command(on.replacingOccurrences(of: #""v":4"#, with: fields)) else { return nil }
            return request
        }
        XCTAssertEqual(try shaped(#""fit":"window","shape":0.6"#)?.shape, 0.6)
        XCTAssertEqual(try shaped(#""fit":"window","shape":9"#)?.shape, 2, "at twice its size at most, as a fitted window")
        XCTAssertEqual(try shaped(#""fit":"window","shape":0"#)?.shape, 0.05)
        XCTAssertNil(try shaped(#""shape":0.6"#)?.shape, "only a window the view is fitted to")
        XCTAssertEqual(try shaped(#""inset":[60,0,120,8.5]"#)?.inset, ScreenView.Inset(top: 60, right: 0, bottom: 120, left: 8.5))
        XCTAssertEqual(try shaped(#""v":4"#)?.inset, .zero, "a page that sends none")
        for odd in [#""inset":[60,0,120]"#, #""inset":[]"#, #""inset":[1,2,3,4,5]"#] {
            XCTAssertEqual(try shaped(odd)?.inset, .zero, odd)
        }
        XCTAssertEqual(try shaped(#""inset":[-60,0,9000,0]"#)?.inset, ScreenView.Inset(top: 0, right: 0, bottom: 794, left: 0), "bounded")
        for off in [#"{"t":"view","on":false}"#, #"{"t":"view"}"#] {
            guard case .view(nil) = try command(off) else { return XCTFail(off) }
        }
        // Before, these switched the view off. A request to switch it on that the agent cannot follow is refused.
        for malformed in [#"{"t":"view","on":true,"w":390,"h":844}"#, on.replacingOccurrences(of: "390", with: "5"),
                          on.replacingOccurrences(of: #""fps":120"#, with: #""fps":"120""#)] {
            guard case .ignored = try command(malformed) else { return XCTFail(malformed) }
        }
    }

    func testWhatTheAgentDoesNotActOn() throws {
        for json in [#"{"t":"noop"}"#, #"{"t":"m","dx":6000,"dy":0}"#, #"{"t":"m","dx":1}"#, #"{"t":"auth"}"#,
                     #"{"t":"shown","n":-1}"#, #"{"t":"key","k":"w"}"#, #"{"t":"focus","win":7}"#, #"{"t":"focus","pid":0}"#,
                     #"{"t":"display"}"#, #"{"t":"display","id":-1}"#,
                     #"{"t":"text","s":"\#(String(repeating: "x", count: 2001))"}"#, #"{"t":"unlock"}"#, #"{"t":"unlock","s":""}"#,
                     #"{"t":"unlock","s":"\#(String(repeating: "x", count: 257))"}"#] {
            guard case .ignored = try command(json) else { return XCTFail(json) }
        }
        XCTAssertThrowsError(try command("not json"))
        XCTAssertThrowsError(try command("[1,2]"), "a message is an object")
        for nameless in [#"{"dx":1}"#, #"{"t":7}"#, #"{"t":null,"dx":1}"#] {
            guard case .ignored = try command(nameless) else { return XCTFail(nameless) }
        }
    }

    /// Before, one field of the wrong type made the whole message fail to decode, and the agent hung up.
    func testAFieldOfTheWrongTypeCostsOnlyTheMessageThatNeedsIt() throws {
        guard case .move(dx: 3, dy: 4, sequence: nil) = try command(#"{"t":"m","dx":3,"dy":4,"q":"seven"}"#) else {
            return XCTFail("a move with a number that is none is still a move")
        }
        guard case .move(dx: 1, dy: 2, sequence: 5) = try command(#"{"t":"m","dx":1,"dy":2,"q":5,"n":1.5,"mods":"cmd"}"#) else {
            return XCTFail("fields a move does not read")
        }
        for json in [#"{"t":"m","dx":"3","dy":4}"#, #"{"t":"shown","n":1.5}"#, #"{"t":"shown","n":-1}"#,
                     #"{"t":"key","k":"w","mods":"cmd","n":1}"#, #"{"t":"b","b":"left","d":"yes"}"#, #"{"t":"auth","token":42}"#] {
            guard case .ignored = try command(json) else { return XCTFail(json) }
        }
    }

    func testHeartbeatKeyFramesAndTheIconsThePageHas() throws {
        guard case .ping = try command(#"{"t":"ping"}"#) else { return XCTFail("ping") }
        XCTAssertEqual(try message(Wire.pong)["t"] as? String, "pong")
        guard case .keyFrame = try command(#"{"t":"idr"}"#) else { return XCTFail("idr") }
        guard case .apps(have: nil) = try command(#"{"t":"apps"}"#) else { return XCTFail("apps without a word of the icons") }
        guard case .apps(have: let have?) = try command(#"{"t":"apps","have":["com.apple.finder","pid-12"]}"#) else {
            return XCTFail("apps with icons")
        }
        XCTAssertEqual(have, ["com.apple.finder", "pid-12"])
        let many = (0..<300).map { #""app\#($0)""# }.joined(separator: ",")
        guard case .apps(have: let capped?) = try command(#"{"t":"apps","have":[\#(many)]}"#) else { return XCTFail("many") }
        XCTAssertEqual(capped.count, 256)
        guard case .apps(have: nil) = try command(#"{"t":"apps","have":"all"}"#) else { return XCTFail("a list that is none") }
    }

    func testARefusedViewSaysWhy() throws {
        XCTAssertEqual(try message(Wire.viewRefused)["why"] as? String, "permission")
        let taken = try message(Wire.viewTaken)
        XCTAssertEqual(taken["t"] as? String, "view")
        XCTAssertEqual(taken["ok"] as? Bool, false)
        XCTAssertEqual(taken["why"] as? String, "taken")
    }
}
