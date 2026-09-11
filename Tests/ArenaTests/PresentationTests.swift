import XCTest
@testable import Arena

final class PresentationTests: XCTestCase {
    func testDashboardCountsAndFolderSearchStayConsistentThroughRetention() {
        let now = Date(timeIntervalSince1970: 200_000)
        var sessions = [SessionStatus.active, .waiting, .consensus, .impasse, .stopped].enumerated().map { index, status in
            ArenaSession(id: "\(index)", name: index == 0 ? "Olympus" : "Review \(index)",
                         brief: index == 2 ? "Refresh tokens" : "Plan", status: status, revision: 0,
                         createdAt: now, updatedAt: now.addingTimeInterval(Double(index)), participants: [], events: [], attachments: [])
        }
        var summary = SessionSummary(sessions: sessions)
        XCTAssertEqual([summary.total, summary.open, summary.closed, summary.archived, summary.active, summary.waiting], [5, 2, 3, 0, 1, 1])
        XCTAssertEqual(SessionFolder.sessions.sessions(in: sessions).map(\.id), ["4", "3", "2", "1", "0"])
        XCTAssertEqual(SessionFolder.sessions.sessions(in: sessions, search: "  OLYMPUS \n").map(\.id), ["0"])
        XCTAssertEqual(SessionFolder.sessions.sessions(in: sessions, search: "tokens", status: .consensus).map(\.id), ["2"])
        XCTAssertTrue(SessionFolder.sessions.sessions(in: sessions, search: "tokens", status: .active).isEmpty)

        // Archive stops a discussion; archived and deleted records must not inflate Closed.
        sessions[0].status = .stopped
        sessions[0].archivedAt = now
        sessions[4].deletedAt = now
        summary = SessionSummary(sessions: sessions)
        XCTAssertEqual([summary.total, summary.open, summary.closed, summary.archived], [4, 1, 2, 1])
        XCTAssertEqual(summary.total, summary.open + summary.closed + summary.archived)
        XCTAssertEqual(SessionFolder.archive.sessions(in: sessions, search: "olympus").map(\.id), ["0"])
        XCTAssertEqual(SessionFolder.deleted.sessions(in: sessions).map(\.id), ["4"])
        sessions[0].deletedAt = now.addingTimeInterval(ArenaSession.archiveLifetime)
        XCTAssertTrue(SessionFolder.archive.sessions(in: sessions).isEmpty)
        sessions[0].archivedAt = nil
        sessions[0].deletedAt = nil
        summary = SessionSummary(sessions: sessions)
        XCTAssertEqual([summary.total, summary.open, summary.closed, summary.archived], [4, 1, 3, 0])
        XCTAssertEqual(SessionFolder.sessions.sessions(in: sessions, status: .stopped).map(\.id), ["0"])
    }

    func testDashboardThinkingExpiresAndClosedStatusOverridesAnOldTurn() {
        let now = Date(timeIntervalSince1970: 200_000)
        let participant = Participant(id: "peer", name: "Athena", invitation: "", credential: "", index: 0, joinedAt: now)
        var session = ArenaSession(id: "session", name: "Review", brief: "Plan", status: .active, revision: 0,
                                   createdAt: now, updatedAt: now, participants: [participant], events: [], attachments: [])
        XCTAssertEqual(session.dashboardActivity(at: now), "Ready for the next turn")
        session.turn = DiscussionTurn(participantID: participant.id, updatedAt: now)
        XCTAssertEqual(session.dashboardActivity(at: now.addingTimeInterval(119)), "Athena is thinking…")
        XCTAssertEqual(session.dashboardActivity(at: now.addingTimeInterval(120)), "Athena holds the turn")
        session.turn?.phase = .offered
        XCTAssertEqual(session.dashboardActivity(at: now), "Waiting for Athena")
        session.status = .consensus
        XCTAssertEqual(session.dashboardActivity(at: now), "Final answer reached")
    }

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

    func testFictionalSessionDefaultsAndCustomNames() {
        XCTAssertGreaterThanOrEqual(SessionNames.locations.count, 100)
        XCTAssertEqual(Set(SessionNames.locations).count, SessionNames.locations.count)
        XCTAssertTrue(["Asgard", "Olympus", "Metropolis", "Westeros", "Woodsboro"].allSatisfy(SessionNames.locations.contains))
        for location in SessionNames.locations {
            XCTAssertFalse(location.isEmpty)
            XCTAssertLessThanOrEqual(location.count, 200)
            XCTAssertEqual(SessionNames.resolve("", default: location), location)
            XCTAssertEqual(SessionNames.resolve(" \n\t", default: location), location)
            XCTAssertEqual(SessionNames.resolve("  My review  ", default: location), "My review")
        }
    }

    func testCompactActivityTimeBoundaries() {
        let now = Date(timeIntervalSince1970: 200_000)
        for (age, expected) in [(-1, "Now"), (59, "Now"), (60, "1m"), (3_599, "59m"),
                                (3_600, "1h"), (86_400, "Yesterday"), (172_800, "2d")] {
            XCTAssertEqual(now.addingTimeInterval(-Double(age)).arenaRelativeTime(to: now), expected)
        }
    }
}
