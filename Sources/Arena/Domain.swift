import Foundation

enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), int(Int), double(Double), string(String), array([JSONValue]), object([String: JSONValue])
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var intValue: Int? { if case .int(let value) = self { value } else { nil } }
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
}

struct ToolImage: Codable, Sendable { var data: Data; var mimeType: String }
struct ArenaToolResult: Codable, Sendable { var data: JSONValue; var images: [ToolImage] = [] }
enum ArenaError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}
enum SessionStatus: String, Codable, Sendable {
    case waiting, active, consensus, impasse, stopped
    var isClosed: Bool { self == .consensus || self == .impasse || self == .stopped }
    var title: String { rawValue.capitalized }
}
struct Participant: Identifiable, Codable, Sendable {
    var id: String; var name: String; var invitation: String; var credential: String; var index: Int
    var client: String?; var model: String?; var joinedAt: Date?
    var registrationToken: String?
    var publicValue: JSONValue { .object(["id": .string(id), "name": .string(name), "index": .int(index), "client": client.map(JSONValue.string) ?? .null, "model": model.map(JSONValue.string) ?? .null, "joined": .bool(joinedAt != nil)]) }
}
struct ArenaEvent: Identifiable, Codable, Sendable {
    var id: String = UUID().uuidString; var cursor: Int; var kind: String; var text: String
    var participantID: String?; var createdAt: Date = .now; var replyTo: String?
    var mentions: [String] = []; var attachmentIDs: [String] = []
    var messageType: String?
}
struct Attachment: Identifiable, Codable, Sendable {
    var id: String; var name: String; var mimeType: String; var storedName: String; var byteCount: Int; var isBrief: Bool
    var publicValue: JSONValue { .object(["id": .string(id), "name": .string(name), "mime_type": .string(mimeType), "byte_count": .int(byteCount), "is_brief": .bool(isBrief)]) }
}
struct OutcomeProposal: Identifiable, Codable, Sendable {
    var id: String; var outcome: SessionStatus; var assessment: String; var revision: Int; var confirmations: [String]
    var acceptedEventID: String?
    var sourceEventID: String?
}
struct DiscussionTurn: Identifiable, Codable, Sendable {
    var id: String = UUID().uuidString
    var participantID: String
    var phase: Phase = .thinking
    var updatedAt: Date = .now
    enum Phase: String, Codable, Sendable { case offered, thinking, speaking }
    func isThinking(at date: Date) -> Bool { phase == .thinking && date.timeIntervalSince(updatedAt) < 120 }
}
struct ArenaSession: Identifiable, Codable, Sendable {
    var id: String; var name: String; var brief: String; var status: SessionStatus; var revision: Int
    var createdAt: Date; var updatedAt: Date; var participants: [Participant]; var events: [ArenaEvent]
    var attachments: [Attachment]; var proposal: OutcomeProposal?
    var turn: DiscussionTurn?
    var archivedAt: Date?
    var deletedAt: Date?
    static let archiveLifetime: TimeInterval = 90 * 24 * 60 * 60
    static let deletionLifetime: TimeInterval = 7 * 24 * 60 * 60
    var isStoredAway: Bool { archivedAt != nil || deletedAt != nil }
    var retentionDeadline: Date? {
        if let deletedAt { return deletedAt.addingTimeInterval(Self.deletionLifetime) }
        return archivedAt?.addingTimeInterval(Self.archiveLifetime)
    }
    var joinedParticipants: [Participant] { participants.filter { $0.joinedAt != nil } }
    var latestCursor: Int { events.last?.cursor ?? 0 }
    func publicValue(participant: Participant) throws -> JSONValue {
        .object(["id": .string(id), "name": .string(name), "brief": .string(brief), "status": .string(status.rawValue), "revision": .int(revision), "latest_cursor": .int(latestCursor), "participants": .array(joinedParticipants.map(\.publicValue)), "participant": participant.publicValue, "attachments": .array(attachments.map(\.publicValue)), "proposal": try proposal.map(JSONValue.encode) ?? .null, "turn": try turn.map(JSONValue.encode) ?? .null])
    }
}
