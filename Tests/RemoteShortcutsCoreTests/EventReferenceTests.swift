import XCTest
@testable import RemoteShortcutsCore

final class EventReferenceTests: XCTestCase {
    private let seriesID = "330D65C2-1111-2222-3333-444455556666"

    // MARK: - The epoch

    /// The epoch is the one thing here that cannot be got wrong quietly.
    ///
    /// A real detached occurrence observed on macOS carried `RID=825598800`,
    /// and that occurrence was 1 March 2027. On Apple's reference date
    /// (2001-01-01) those seconds land on 2027-03-01; on the Unix epoch they
    /// land on 1996-02-29. Using Unix would produce ids that look plausible and
    /// never match the ones EventKit emits.
    func testRIDSecondsAreOnApplesReferenceDate() {
        let reference = EventReference.parse("\(seriesID)/RID=825598800")

        guard let start = reference.occurrenceStart else {
            return XCTFail("Expected an occurrence start")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day], from: start)

        XCTAssertEqual(components.year, 2027)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 1)
    }

    func testRoundTripsThroughTheCompositeForm() {
        let start = Date(timeIntervalSinceReferenceDate: 825_598_800)
        let composite = EventReference(identifier: seriesID, occurrenceStart: start).composite

        XCTAssertEqual(composite, "\(seriesID)/RID=825598800")

        let parsed = EventReference.parse(composite)
        XCTAssertEqual(parsed.identifier, seriesID)
        XCTAssertEqual(parsed.occurrenceStart?.timeIntervalSinceReferenceDate, 825_598_800)
    }

    // MARK: - Parsing

    /// A bare id keeps its historic meaning, so clients written against the old
    /// shape are unaffected.
    func testBareIdentifierMeansTheSeries() {
        let reference = EventReference.parse(seriesID)
        XCTAssertEqual(reference.identifier, seriesID)
        XCTAssertNil(reference.occurrenceStart)
        XCTAssertFalse(reference.isOccurrencePinned)
        XCTAssertEqual(reference.composite, seriesID)
    }

    func testCompositeIdentifiesAnOccurrence() {
        let reference = EventReference.parse("\(seriesID)/RID=800000000")
        XCTAssertEqual(reference.identifier, seriesID)
        XCTAssertTrue(reference.isOccurrencePinned)
    }

    /// A non-numeric suffix is not our format, so the whole string stays an
    /// identifier rather than being silently truncated.
    func testNonNumericSuffixIsTreatedAsPartOfTheIdentifier() {
        let raw = "\(seriesID)/RID=notanumber"
        let reference = EventReference.parse(raw)
        XCTAssertEqual(reference.identifier, raw)
        XCTAssertNil(reference.occurrenceStart)
    }

    func testEmptyIdentifierBeforeTheMarkerIsRejected() {
        let reference = EventReference.parse("/RID=800000000")
        XCTAssertEqual(reference.identifier, "/RID=800000000")
        XCTAssertNil(reference.occurrenceStart)
    }

    /// Only the final marker is the suffix we appended.
    func testOnlyTheLastMarkerIsTreatedAsTheSuffix() {
        let reference = EventReference.parse("weird/RID=1/RID=800000000")
        XCTAssertEqual(reference.identifier, "weird/RID=1")
        XCTAssertEqual(reference.occurrenceStart?.timeIntervalSinceReferenceDate, 800_000_000)
    }

    func testNegativeSecondsParse() {
        // Occurrences before 2001 are legitimate.
        let reference = EventReference.parse("\(seriesID)/RID=-100000")
        XCTAssertEqual(reference.occurrenceStart?.timeIntervalSinceReferenceDate, -100_000)
    }

    // MARK: - Base identifier

    func testBaseIdentifierStripsTheSuffix() {
        XCTAssertEqual(EventReference.baseIdentifier(of: "\(seriesID)/RID=825598800"), seriesID)
        XCTAssertEqual(EventReference.baseIdentifier(of: seriesID), seriesID)
    }

    /// Comparing a detached occurrence's own identifier against a series id
    /// needs both sides bare — this is what makes that comparison work.
    func testDetachedOccurrenceIdentifierComparesEqualToItsSeries() {
        let detached = "\(seriesID)/RID=825598800"
        XCTAssertEqual(EventReference.baseIdentifier(of: detached), EventReference.baseIdentifier(of: seriesID))
    }

    func testRawIsPreservedForVerbatimLookup() {
        let raw = "\(seriesID)/RID=825598800"
        XCTAssertEqual(EventReference.parse(raw).raw, raw)
    }

    // MARK: - Routing

    /// The composite form contains a slash, so it depends on the router's
    /// greedy trailing parameter. Guard that the two features stay compatible.
    func testCompositeIdSurvivesRouting() throws {
        let router = Router()
        router.delete("/v1/calendars/events/:id") { request in
            .json(["id": try request.parameter("id")])
        }

        let composite = "\(seriesID)/RID=825598800"
        let response = try router.handle(
            HTTPRequest(method: "DELETE", path: "/v1/calendars/events/\(composite)"),
            readOnly: false
        )

        let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertEqual(payload?["id"] as? String, composite)
    }
}
