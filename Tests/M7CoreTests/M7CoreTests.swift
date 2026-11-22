import Foundation
import Testing
@testable import M7Core

@Suite struct RequestBodyTests {
    @Test func readRequestCarriesOnlyTheToken() {
        let body = RPC.requestBody(id: 3, method: "backlightControl", token: "abc")
        #expect(String(decoding: body, as: UTF8.self)
            == #"{"jsonrpc":"2.0","id":"3","method":"backlightControl","params":{"AccessToken":"abc"}}"#)
    }

    @Test func setRequestPutsTokenFirstThenParams() {
        let body = RPC.requestBody(id: 1, method: "backlightControl", token: "abc", params: [("backlight", .int(30))])
        #expect(String(decoding: body, as: UTF8.self)
            == #"{"jsonrpc":"2.0","id":"1","method":"backlightControl","params":{"AccessToken":"abc","backlight":30}}"#)
    }

    @Test func pairingRequestHasNoParams() {
        let body = RPC.requestBody(id: 1, method: "createAccessToken", token: nil)
        #expect(String(decoding: body, as: UTF8.self) == #"{"jsonrpc":"2.0","id":"1","method":"createAccessToken"}"#)
    }

    @Test func stringsAreEscaped() {
        let body = RPC.requestBody(id: 1, method: "m", token: "a\"b\\c")
        #expect(JSONValue.parse(body)?.objectValue?["params"]?.objectValue?["AccessToken"] == .string("a\"b\\c"))
    }
}

@Suite struct ReplyTests {
    private func parse(_ text: String) -> Result<[String: JSONValue], RPC.Failure> {
        RPC.parseReply(Data(text.utf8))
    }

    @Test func successReturnsResultObject() {
        let reply = parse(#"{"jsonrpc":"2.0","id":"1","result":{"backlight":48}}"#)
        #expect(reply == .success(["backlight": .int(48)]))
    }

    @Test func statesReplyKeepsStringsAndNumbers() throws {
        let reply = parse(#"{"jsonrpc":"2.0","id":"1","result":{"volume":11,"mute":"muteOff","inputSource":"USB-C"}}"#)
        let states = try reply.get()
        #expect(states["volume"]?.intValue == 11)
        #expect(states["mute"]?.stringValue == "muteOff")
    }

    @Test func flatParseErrorMeansUnauthorized() {
        #expect(parse(#"{"code": -32700, "message": "Parse error"}"#) == .failure(.unauthorized))
    }

    @Test func declinedPairingMeansUnauthorized() {
        #expect(parse(#"{"jsonrpc":"2.0","id":"1","error":{"code":-32010,"message":"Unauthorized access"}}"#)
            == .failure(.unauthorized))
    }

    @Test func outOfRangeValueIsAServerError() {
        #expect(parse(#"{"code": -32002, "message": "Server error", "data": "Failed"}"#)
            == .failure(.server(code: -32002, message: "Server error")))
    }

    @Test func nonJSONIsMalformed() {
        #expect(parse("<html>") == .failure(.malformed))
        #expect(parse("[1,2]") == .failure(.malformed))
    }
}

@Suite struct MediaKeyTests {
    private func data1(key: Int, down: Bool, isRepeat: Bool = false) -> Int {
        (key << 16) | ((down ? 0x0A : 0x0B) << 8) | (isRepeat ? 1 : 0)
    }

    @Test func decodesVolumeAndBrightnessKeys() {
        #expect(MediaKeyDecoder.decode(data1: data1(key: 0, down: true))
            == MediaKeyEvent(key: .volumeUp, isDown: true, isRepeat: false))
        #expect(MediaKeyDecoder.decode(data1: data1(key: 1, down: false))
            == MediaKeyEvent(key: .volumeDown, isDown: false, isRepeat: false))
        #expect(MediaKeyDecoder.decode(data1: data1(key: 7, down: true))?.key == .mute)
        #expect(MediaKeyDecoder.decode(data1: data1(key: 2, down: true))?.key == .brightnessUp)
        #expect(MediaKeyDecoder.decode(data1: data1(key: 3, down: true, isRepeat: true))
            == MediaKeyEvent(key: .brightnessDown, isDown: true, isRepeat: true))
    }

    @Test func mapsBrightnessKeyCodesFromOrdinaryKeyEvents() {
        #expect(MediaKeyDecoder.brightnessKey(forKeyCode: 107) == .brightnessDown) // F14, as Logitech sends
        #expect(MediaKeyDecoder.brightnessKey(forKeyCode: 113) == .brightnessUp) // F15
        #expect(MediaKeyDecoder.brightnessKey(forKeyCode: 145) == .brightnessDown)
        #expect(MediaKeyDecoder.brightnessKey(forKeyCode: 144) == .brightnessUp)
        #expect(MediaKeyDecoder.brightnessKey(forKeyCode: 0) == nil) // the letter A
        #expect(MediaKeyDecoder.brightnessKey(forKeyCode: 105) == nil) // F13
    }

    @Test func ignoresOtherSpecialKeys() {
        #expect(MediaKeyDecoder.decode(data1: data1(key: 16, down: true)) == nil) // play/pause
        #expect(MediaKeyDecoder.decode(data1: data1(key: 17, down: true)) == nil) // next track
    }
}

@Suite struct LevelTests {
    @Test func stepsClampToTheRange() {
        #expect(Level.stepped(11, by: 1, in: Level.volumeRange) == 12)
        #expect(Level.stepped(0, by: -1, in: Level.volumeRange) == 0)
        #expect(Level.stepped(100, by: 1, in: Level.volumeRange) == 100)
        #expect(Level.stepped(49, by: 2, in: Level.backlightRange) == 50)
        #expect(Level.stepped(1, by: -2, in: Level.backlightRange) == 0)
    }
}
