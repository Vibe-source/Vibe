import Foundation
import UIKit
import XCTest

@testable import Vibe

/// The row-payload reader that fed the core nothing.
///
/// A parallel chat screen was built, routed and deleted on 2026-08-03 because its feed
/// read the timestamp from the top level of an engine row. Engine rows are **nested** —
/// `row["message"]["timestampMs"]` — so every row answered `nil`, every row was skipped,
/// the core was handed no messages, and the transcript came up empty with no error
/// anywhere.
///
/// These are the tests that would have caught it in seconds. They are worth more than
/// their size: the failure had no symptom other than "nothing is there", which is the
/// hardest kind to trace back to a field name.
final class VibeCoreListDriverTests: XCTestCase {

  // MARK: The bug

  func testTheTimestampIsReadFromTheNestedMessage() {
    let row: [String: Any] = [
      "kind": "message",
      "key": "row-key-1",
      "message": ["id": "m1", "timestampMs": 1_724_000_000_000, "text": "hi"],
    ]
    XCTAssertEqual(
      VibeCoreListDriver.messageTimestampMs(from: row), 1_724_000_000_000,
      "engine rows nest the epoch timestamp — reading only the top level feeds the core nothing")
  }

  func testAFlatNumericTimestampStillWorks() {
    let row: [String: Any] = ["key": "k", "timestampMs": 1_724_000_000_001]
    XCTAssertEqual(VibeCoreListDriver.messageTimestampMs(from: row), 1_724_000_000_001)
  }

  func testADisplayLabelIsNotAcceptedAsATimestamp() {
    // "22:20" is what `timestamp` holds in several row shapes. Parsing it would order
    // the transcript by nonsense and read as a core defect.
    let row: [String: Any] = ["key": "k", "timestamp": "22:20"]
    XCTAssertNil(VibeCoreListDriver.messageTimestampMs(from: row))
  }

  func testANestedDisplayLabelIsAlsoRefused() {
    let row: [String: Any] = ["key": "k", "message": ["id": "m1", "timestamp": "22:20"]]
    XCTAssertNil(VibeCoreListDriver.messageTimestampMs(from: row))
  }

  func testEveryNumericRepresentationIsAccepted() {
    let base = 1_724_000_000_000
    for value in [base as Any, Int64(base) as Any, Double(base) as Any, NSNumber(value: base) as Any]
    {
      let row: [String: Any] = ["key": "k", "message": ["id": "m", "timestampMs": value]]
      XCTAssertEqual(
        VibeCoreListDriver.messageTimestampMs(from: row), Int64(base),
        "payloads cross JSON and NSNumber boundaries; all four shapes reach this reader")
    }
  }

  // MARK: Identity

  func testTheTopLevelRowKeyIsPreferred() {
    let row: [String: Any] = ["key": "row-key", "message": ["id": "m1"]]
    XCTAssertEqual(
      VibeCoreListDriver.messageId(from: row), "row-key",
      "the list keys rows by `key`; the core must agree or the two can never be compared")
  }

  func testANestedIdIsFoundWhenThereIsNoTopLevelOne() {
    let row: [String: Any] = ["message": ["id": "m1"]]
    XCTAssertEqual(VibeCoreListDriver.messageId(from: row), "m1")
  }

  func testARowWithNoIdAtAllIsRefused() {
    XCTAssertNil(VibeCoreListDriver.messageId(from: ["kind": "message"]))
  }

  func testAnEmptyIdIsNotAnId() {
    XCTAssertNil(VibeCoreListDriver.messageId(from: ["key": "", "message": ["id": ""]]))
  }

  // MARK: Authorship

  func testAuthorshipIsReadFromEitherLevel() {
    XCTAssertTrue(VibeCoreListDriver.isMine(["isMe": true]))
    XCTAssertTrue(VibeCoreListDriver.isMine(["message": ["isMe": true]]))
    XCTAssertFalse(VibeCoreListDriver.isMine(["message": ["isMe": false]]))
    XCTAssertFalse(
      VibeCoreListDriver.isMine(["kind": "message"]),
      "unknown authorship reads as the peer's — never silently claims a message as yours")
  }

  // MARK: The frame

  func testTheFrameCarriesOrderingAndNotContent() throws {
    let data = VibeCoreListDriver.frame(
      id: "m1", chatId: "c1", tsMs: 1_724_000_000_000, isMine: true)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(object["id"] as? String, "m1")
    XCTAssertEqual(object["chat_id"] as? String, "c1")
    XCTAssertEqual((object["timestamp"] as? NSNumber)?.int64Value, 1_724_000_000_000)
    XCTAssertEqual(
      object["sender_id"] as? String, "me",
      "must match the core's configured ownUserId, or outgoing messages read as someone else's")
    XCTAssertEqual(
      object["content"] as? String, "",
      "the core orders by (ts, id) only — message text has no reason to cross the FFI")
  }

  func testAPeerFrameIsAttributedToThePeer() throws {
    let data = VibeCoreListDriver.frame(id: "m2", chatId: "c1", tsMs: 1, isMine: false)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["sender_id"] as? String, "peer")
  }

  // MARK: A real engine row

  func testARealisticEngineRowIsFullyReadable() {
    // The shape `ChatEngine` actually emits, as `ChatListRow(raw:)` consumes it.
    let row: [String: Any] = [
      "kind": "message",
      "key": "176cdf92-1",
      "message": [
        "id": "srv-9981",
        "text": "hello",
        "timestamp": "22:20",
        "timestampMs": 1_724_000_123_456,
        "isMe": true,
        "type": "text",
      ],
    ]
    XCTAssertEqual(VibeCoreListDriver.messageId(from: row), "176cdf92-1")
    XCTAssertEqual(VibeCoreListDriver.messageTimestampMs(from: row), 1_724_000_123_456)
    XCTAssertTrue(VibeCoreListDriver.isMine(row))
    XCTAssertNotNil(
      ChatListRow(raw: row),
      "if the list cannot parse this row either, the fixture has drifted from reality")
  }
}
