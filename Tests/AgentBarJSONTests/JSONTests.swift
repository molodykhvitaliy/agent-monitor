import Foundation
import Testing

@testable import AgentBarJSON

@Suite("JSON reading")
struct JSONParserTests {

    @Test("Reads every kind of value")
    func readsValues() throws {
        let value = try JSONParser.parse(
            Data(#"{"s":"x","n":-1.5e3,"t":true,"f":false,"z":null,"a":[1,2],"o":{"k":1}}"#.utf8))
        let object = try #require(value.object)
        #expect(object["s"]?.string == "x")
        #expect(object["n"] == .number("-1.5e3"))
        #expect(object["t"]?.bool == true)
        #expect(object["f"]?.bool == false)
        #expect(object["z"] == JSONValue.null)
        #expect(object["a"]?.array?.count == 2)
        #expect(object["o"]?.object?["k"]?.integer == 1)
    }

    @Test("Keeps the order keys were written in")
    func keepsOrder() throws {
        let object = try #require(
            JSONParser.parse(Data(#"{"z":1,"a":2,"m":3}"#.utf8)).object)
        #expect(object.keys == ["z", "a", "m"])
    }

    @Test("Keeps a number exactly as it was spelled")
    func keepsNumberSpelling() throws {
        let object = try #require(JSONParser.parse(Data(#"{"a":5,"b":5.0,"c":1e2}"#.utf8)).object)
        #expect(object["a"] == .number("5"))
        #expect(object["b"] == .number("5.0"))
        #expect(object["c"] == .number("1e2"))
        // A timeout of 5 must not be able to come back as 5.0.
        #expect(object["a"]?.integer == 5)
        #expect(object["b"]?.integer == nil)
    }

    @Test("Reads escapes, including a character outside the basic plane")
    func readsEscapes() throws {
        let object = try #require(
            JSONParser.parse(Data(#"{"a":"q\"\\\/\b\f\n\r\t\u00e9\ud83d\ude80"}"#.utf8)).object)
        #expect(object["a"]?.string == "q\"\\/\u{08}\u{0C}\n\r\té🚀")
    }

    @Test(
        "Refuses malformed documents rather than guessing",
        arguments: [
            "", "   ", "{", "[1,]", "{\"a\"}", "{\"a\":}", "{'a':1}", "tru", "01",
            "{\"a\":1}x", "\"unterminated", "{\"a\":\"\\q\"}", "{\"a\":\"\\ud800\"}",
            "[1 2]", "{\"a\":+1}", "{\"a\":.5}",
            // Surrogate handling, which is where a hand-written reader goes wrong.
            "{\"a\":\"\\udc00\"}", "{\"a\":\"\\ud83d\\u0041\"}",
            "{\"a\":\"\\ud83dX\"}", "{\"a\":\"\\ud83d\\n\"}", "{\"a\":\"\\u00\"}",
        ]
    )
    func refusesMalformed(text: String) {
        #expect(throws: (any Error).self) { try JSONParser.parse(Data(text.utf8)) }
    }

    @Test("Refuses a raw control character inside a string")
    func refusesRawControlCharacters() {
        let text = "{\"a\":\"line" + String(UnicodeScalar(10)) + "break\"}"
        #expect(throws: (any Error).self) { try JSONParser.parse(Data(text.utf8)) }
    }

    @Test("Refuses bytes that are not valid UTF-8 inside a string")
    func refusesInvalidUTF8() {
        // A lone continuation byte, which no decoder can turn into a scalar.
        var bytes = Array(#"{"a":"x"#.utf8)
        bytes.append(0x80)
        bytes.append(contentsOf: Array(#""}"#.utf8))
        #expect(throws: (any Error).self) { try JSONParser.parse(Data(bytes)) }
    }

    @Test("Keeps a number no Double could hold, because it never becomes one")
    func keepsUnrepresentableNumbers() throws {
        let object = try #require(JSONParser.parse(Data(#"{"big":1e309,"neg":-0}"#.utf8)).object)
        #expect(object["big"] == .number("1e309"))
        #expect(object["neg"] == .number("-0"))
        #expect(JSONWriter.render(.object(object)).contains("1e309"))
    }

    @Test("Refuses nesting deep enough to exhaust the stack")
    func refusesDeepNesting() {
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        #expect(throws: JSONParsingError.self) { try JSONParser.parse(Data(deep.utf8)) }
    }

    @Test("Accepts nesting up to the limit")
    func acceptsNestingToTheLimit() throws {
        let depth = JSONParser.maximumDepth
        let text = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        _ = try JSONParser.parse(Data(text.utf8))
    }
}

@Suite("JSON writing")
struct JSONWriterTests {

    @Test("Renders the shape the tools that own these files render")
    func rendersFamiliarShape() throws {
        let value = try JSONParser.parse(Data(#"{"a":[1,{"b":"c"}],"d":{},"e":[]}"#.utf8))
        #expect(
            JSONWriter.render(value) == """
                {
                  "a": [
                    1,
                    {
                      "b": "c"
                    }
                  ],
                  "d": {},
                  "e": []
                }

                """)
    }

    @Test("Escapes what JSON requires and nothing else")
    func escapesMinimally() {
        let value = JSONValue.object(
            JSONObject([("k", .string("a/b\"c\\d\ne\u{01}f é"))]))
        #expect(JSONWriter.render(value).contains(#""a/b\"c\\d\ne\u0001f é""#))
    }
}
