import Foundation

// Mirrors of the core types the read-only shell uses. Fields the shell
// doesn't read are left out; the decoder ignores them.

struct Account: Decodable, Identifiable, Hashable {
    let id: Int64
    let email: String
    let name: String?
    let status: String?
    let statusDetail: String?
    let provider: String?
    let folders: Int?
    let receiveOnly: Bool?
}

struct ThreadPage: Decodable {
    let items: [ThreadSummary]?
    let nextCursor: String?
}

struct ThreadSummary: Decodable, Identifiable, Hashable {
    let id: Int64
    let subject: String
    let snippet: String
    let from: String
    let participants: [String]?
    let count: Int
    let unread: Int
    let flagged: Int
    let lastDate: Date
    let hasAttachments: Bool
}

struct MailThread: Decodable {
    let id: Int64
    let subject: String
    let messages: [MessageSummary]?
}

struct MessageSummary: Decodable, Identifiable, Hashable {
    let id: Int64
    let threadID: Int64
    let subject: String
    let from: String
    let snippet: String
    let to: [String]?
    let cc: [String]?
    let date: Date
    let flags: [String]?
    let hasAttachments: Bool

    var isUnread: Bool { !(flags ?? []).contains("\\Seen") }
    var isStarred: Bool { (flags ?? []).contains("\\Flagged") }
}

struct AttachmentInfo: Decodable, Hashable {
    let id: Int64
    let filename: String?
    let size: Int?
    let inline: Bool?
}

struct Message: Decodable {
    let id: Int64
    let from: String
    let to: [String]?
    let cc: [String]?
    let date: Date
    let html: String?
    let text: String?
    let remoteImagesBlocked: Int?
    let trackersBlocked: Int?
    let attachments: [AttachmentInfo]?
}

struct ServerEntry: Decodable {
    let `protocol`: String
    let host: String
    let port: Int
    let security: String
    let login: String?
}

struct Provider: Decodable {
    let id: String
    let name: String
    let entries: [ServerEntry]?
    let helpURL: String?
    let username: String?

    func entry(_ proto: String) -> ServerEntry? { entries?.first { $0.protocol == proto } }
}

struct CheckStep: Decodable, Identifiable {
    let name: String
    let ok: Bool
    let skipped: Bool
    let kind: String?
    let detail: String?
    var id: String { name }
}

struct CheckReport: Decodable {
    let steps: [CheckStep]?
    let folders: Int?
}

struct CoreEvent: Decodable {
    let type: String
    let accountID: Int64?
    let error: String?
    let kind: String?
}

/// "Name <addr@host>" → "Name"; a bare address stays as it is.
func displayName(_ from: String) -> String {
    if let lt = from.firstIndex(of: "<") {
        let name = from[..<lt].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !name.isEmpty { return name }
        return String(from[from.index(after: lt)...].dropLast(from.hasSuffix(">") ? 1 : 0))
    }
    return from
}
