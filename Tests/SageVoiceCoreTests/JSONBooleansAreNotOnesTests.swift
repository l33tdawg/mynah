import XCTest
@testable import SageVoiceCore

/// `true` is not `1`, on every platform this is built for.
///
/// **The discriminator used to be `CFGetTypeID(number) == CFBooleanGetTypeID()`,
/// and there is no `CFGetTypeID` off Darwin.** That one line is the only thing
/// standing between a JSON boolean and a JSON number in every model reply, every
/// MCP tool result and every SAGE payload this appliance reads — so the Linux
/// port could not simply drop it, and could not replace it with a cast either:
/// swift-corelibs-foundation bridges `Bool` to `NSNumber` in both directions
/// unconditionally, which means `NSNumber(value: 5) as? Bool` succeeds there.
/// Every question you can ask a parsed value on that platform answers yes.
///
/// What a wrong answer would look like in the field is the reason this file
/// exists rather than a comment: a tool called with `{"force": true}` would
/// arrive at the tool as `{"force": 1}`, which a schema expecting a boolean
/// rejects and a permissive one silently misreads. Nothing in the daemon would
/// log anything unusual; the tool would just do the wrong thing, once per call,
/// on one platform.
///
/// These assertions are deliberately about the *parse*, not about the
/// accessors. `JSONValue.boolValue` reads `.int(1)` as `true` on purpose — that
/// is a caller being lenient about a value it already has. This is about what
/// the document said.
final class JSONBooleansAreNotOnesTests: XCTestCase {

    // MARK: The distinction itself

    func testABooleanParsesAsABooleanAndANumberAsANumber() {
        let parsed = JSONValue.parse(#"{"force": true, "count": 1, "off": false, "zero": 0}"#)

        XCTAssertEqual(parsed?["force"], .bool(true))
        XCTAssertEqual(parsed?["count"], .int(1))
        XCTAssertEqual(parsed?["off"], .bool(false))
        XCTAssertEqual(parsed?["zero"], .int(0))

        // Said again as a shape check, because `.bool(true) == .int(1)` is false
        // by construction and the interesting failure is the case being *wrong*,
        // not the comparison.
        guard case .bool = parsed?["force"] else {
            return XCTFail("a JSON `true` decoded as \(String(describing: parsed?["force"]))")
        }
        guard case .int = parsed?["count"] else {
            return XCTFail("a JSON `1` decoded as \(String(describing: parsed?["count"]))")
        }
    }

    func testTheDistinctionSurvivesNesting() {
        let parsed = JSONValue.parse(#"{"a": {"b": [true, 1, false, 0, 1.5, null, "1"]}}"#)
        XCTAssertEqual(
            parsed?["a"]?["b"],
            .array([.bool(true), .int(1), .bool(false), .int(0), .double(1.5), .null, .string("1")])
        )
    }

    func testABareBooleanIsAFragmentThisStillReads() {
        XCTAssertEqual(JSONValue.parse("true"), .bool(true))
        XCTAssertEqual(JSONValue.parse("false"), .bool(false))
        XCTAssertEqual(JSONValue.parse("1"), .int(1))
        XCTAssertEqual(JSONValue.parse("0"), .int(0))
        XCTAssertEqual(JSONValue.parse("null"), .null)
        XCTAssertEqual(JSONValue.parse(#""true""#), .string("true"))
    }

    /// The Linux implementation wraps the bytes in `[...]` to get fragments,
    /// which would read `1, 2` as a valid document if it did not insist on
    /// exactly one element. `JSONSerialization` refuses it, so this must too.
    func testRubbishIsStillRubbish() {
        XCTAssertNil(JSONValue.parse(""))
        XCTAssertNil(JSONValue.parse("nope"))
        XCTAssertNil(JSONValue.parse("1, 2"))
        XCTAssertNil(JSONValue.parse(#"{"a": }"#))
    }

    // MARK: Going back out again

    func testABooleanIsWrittenBackAsABoolean() {
        let parsed = JSONValue.parse(#"{"force":true,"count":1}"#)
        XCTAssertEqual(parsed?.jsonString(), #"{"count":1,"force":true}"#)
    }

    func testAWholeToolArgumentSurvivesTheRoundTrip() {
        let original = JSONValue.object([
            "force": .bool(true),
            "quiet": .bool(false),
            "count": .int(1),
            "ratio": .double(0.5),
            "name": .string("mynah"),
            "nothing": .null,
            "mixed": .array([.bool(true), .int(1)])
        ])
        XCTAssertEqual(JSONValue.parse(original.jsonString()), original)
    }

    // MARK: The discriminator, asked directly

    /// `isBoolean` is what `init?(foundationObject:)` leans on, and on Darwin it
    /// is the original `CFBoolean` identity check. Off Darwin it reads the type
    /// encoding instead, and this is the assertion that says whether that
    /// reading was right about the platform's actual `NSNumber`.
    func testTheNumberDiscriminatorKnowsABooleanFromAOne() {
        XCTAssertTrue(JSONValue.isBoolean(NSNumber(value: true)))
        XCTAssertTrue(JSONValue.isBoolean(NSNumber(value: false)))
        XCTAssertFalse(JSONValue.isBoolean(NSNumber(value: 1)))
        XCTAssertFalse(JSONValue.isBoolean(NSNumber(value: 0)))
        XCTAssertFalse(JSONValue.isBoolean(NSNumber(value: 1.0)))
    }
}
