import XCTest
@testable import Arena

final class PresentationTests: XCTestCase {
    @MainActor
    func testCompactPaperColumnWidthsSurviveResizeAndDetailsToggle() {
        let columns = ArenaColumns.ColumnsView()
        columns.frame.size = .init(width: 1120, height: 760)
        columns.showsDetails = true
        columns.adjustSubviews()
        XCTAssertEqual(columns.left.frame.width, 215)
        XCTAssertEqual(columns.center.frame.width, 604)
        XCTAssertEqual(columns.right.frame.width, 299)
        columns.frame.size.width = 1440
        columns.adjustSubviews()
        XCTAssertEqual(columns.left.frame.width, 215)
        XCTAssertEqual(columns.right.frame.width, 299)
        columns.showsDetails = false
        XCTAssertEqual(columns.center.frame.width, 1224)
        columns.showsDetails = true
        XCTAssertEqual(columns.center.frame.width, 924)
    }

    func testMessageSidesFollowFirstSpeechAndSurviveHistoryReload() throws {
        var session = ArenaSession(id: "session", name: "Review", brief: "Brief", status: .active, revision: 0,
                                   createdAt: .now, updatedAt: .now, participants: [], events: [], attachments: [])
        for (kind, speaker) in [("joined", "second"), ("proposed", "second"), ("message", "first"),
                                ("message", "first"), ("message", "second"), ("message", "third"),
                                ("message", "fourth"), ("reopened", "third"), ("message", "second")] {
            session.events.append(ArenaEvent(cursor: session.events.count + 1, kind: kind, text: "", participantID: speaker))
        }
        XCTAssertEqual(session.rightAlignedParticipantIDs, ["second", "fourth"])
        let restored = try JSONDecoder().decode(ArenaSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.rightAlignedParticipantIDs, session.rightAlignedParticipantIDs)
    }

    func testCompactActivityTimeBoundaries() {
        let now = Date(timeIntervalSince1970: 200_000)
        for (age, expected) in [(-1, "Now"), (59, "Now"), (60, "1m"), (3_599, "59m"),
                                (3_600, "1h"), (86_400, "Yesterday"), (172_800, "2d")] {
            XCTAssertEqual(now.addingTimeInterval(-Double(age)).arenaRelativeTime(to: now), expected)
        }
    }
}
