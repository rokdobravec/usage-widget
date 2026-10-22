import Foundation

/// Aggregates token usage from Claude Code transcripts in ~/.claude/projects/**/*.jsonl.
///
/// One model reply is written as several lines (one per content block), each carrying the
/// same usage, so replies are de-duplicated by `message.id` across all files. Parsed files are
/// cached by modification date + size, so periodic rescans only re-read files that changed.
final class UsageScanner {
    private struct Reply {
        let date: Date
        let model: String
        let session: String
        var tokens: TokenCounts
    }

    private struct UserMessage {
        let date: Date
        let session: String
    }

    private struct ParsedFile {
        let modified: Date
        let size: Int
        let replies: [String: Reply]
        let userMessages: [String: UserMessage]
    }

    private let projectsDir: URL
    private var cache: [String: ParsedFile] = [:]
    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()

    init() {
        projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// Returns usage keyed by local-time day ("yyyy-MM-dd"). Call off the main thread.
    func scan() -> [String: DayUsage] {
        var seenPaths = Set<String>()
        for file in jsonlFiles() {
            seenPaths.insert(file.path)
            let values = try? file.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            if let cached = cache[file.path], cached.modified == modified, cached.size == size { continue }
            cache[file.path] = autoreleasepool { parse(file.url, modified: modified, size: size) }
        }
        cache = cache.filter { seenPaths.contains($0.key) }
        return aggregate()
    }

    // MARK: - Private

    private func jsonlFiles() -> [(url: URL, path: String)] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [(URL, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append((url, url.path))
        }
        return files
    }

    private func parse(_ url: URL, modified: Date, size: Int) -> ParsedFile {
        var replies: [String: Reply] = [:]
        var userMessages: [String: UserMessage] = [:]
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return ParsedFile(modified: modified, size: size, replies: [:], userMessages: [:])
        }

        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "assistant" || type == "user",
                  let ts = obj["timestamp"] as? String,
                  let date = isoFractional.date(from: ts) ?? isoPlain.date(from: ts),
                  let message = obj["message"] as? [String: Any] else { continue }
            let session = obj["sessionId"] as? String ?? url.deletingPathExtension().lastPathComponent

            if type == "assistant" {
                guard let id = message["id"] as? String,
                      let usage = message["usage"] as? [String: Any],
                      let model = message["model"] as? String,
                      model != "<synthetic>" else { continue }
                let tokens = TokenCounts(
                    input: usage["input_tokens"] as? Int ?? 0,
                    output: usage["output_tokens"] as? Int ?? 0,
                    cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                    cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0
                )
                if var existing = replies[id] {
                    existing.tokens = existing.tokens.merged(max: tokens)
                    replies[id] = existing
                } else {
                    replies[id] = Reply(date: date, model: model, session: session, tokens: tokens)
                }
            } else {
                // Count only prompts the user typed: skip meta lines, subagent prompts and tool results
                if obj["isMeta"] as? Bool == true || obj["isSidechain"] as? Bool == true { continue }
                guard isTypedPrompt(message["content"]), let uuid = obj["uuid"] as? String else { continue }
                userMessages[uuid] = UserMessage(date: date, session: session)
            }
        }
        return ParsedFile(modified: modified, size: size, replies: replies, userMessages: userMessages)
    }

    private func isTypedPrompt(_ content: Any?) -> Bool {
        if content is String { return true }
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { ($0["type"] as? String) == "text" }
    }

    private func aggregate() -> [String: DayUsage] {
        var replies: [String: Reply] = [:]
        var userMessages: [String: UserMessage] = [:]
        for file in cache.values {
            for (id, reply) in file.replies {
                if let existing = replies[id] {
                    var merged = existing
                    merged.tokens = existing.tokens.merged(max: reply.tokens)
                    replies[id] = merged
                } else {
                    replies[id] = reply
                }
            }
            userMessages.merge(file.userMessages) { first, _ in first }
        }

        let calendar = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = .current

        var days: [String: DayUsage] = [:]
        for reply in replies.values {
            let key = dayFormatter.string(from: reply.date)
            days[key, default: DayUsage()].tokensByModel[reply.model, default: TokenCounts()] += reply.tokens
            days[key]!.replies += 1
            days[key]!.sessions.insert(reply.session)
            days[key]!.hourlyActivity[calendar.component(.hour, from: reply.date)] += 1
        }
        for message in userMessages.values {
            let key = dayFormatter.string(from: message.date)
            days[key, default: DayUsage()].userMessages += 1
            days[key]!.sessions.insert(message.session)
            days[key]!.hourlyActivity[calendar.component(.hour, from: message.date)] += 1
        }
        return days
    }
}

private extension TokenCounts {
    /// Streaming can log partial counts before the final ones; keep the largest value seen.
    func merged(max other: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: Swift.max(input, other.input),
            output: Swift.max(output, other.output),
            cacheRead: Swift.max(cacheRead, other.cacheRead),
            cacheWrite: Swift.max(cacheWrite, other.cacheWrite)
        )
    }
}
