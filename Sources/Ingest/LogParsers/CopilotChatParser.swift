import Foundation

/// Parses VS Code's append-only native chat-session journal.
///
/// The journal contains the full conversation and tool output, but this decoder
/// deliberately whitelists only request identity, time, model and server-reported
/// usage. Unknown fields are skipped by `Decodable` and never enter AI Pulse.
struct CopilotChatParser {
    struct State {
        private(set) var sessionId: String?
        let repoPath: String?
        private var sessionIsCopilot = false
        private var requests: [RequestState] = []

        init(repoPath: String?) {
            self.repoPath = repoPath
        }

        mutating func consume(line: String) -> [UsageEvent] {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(JournalEntry.self, from: data)
            else { return [] }

            switch entry.kind {
            case 0:
                guard let snapshot = entry.snapshot else { return [] }
                sessionId = snapshot.sessionId ?? sessionId
                sessionIsCopilot = snapshot.responderUsername?
                    .localizedCaseInsensitiveContains("copilot") == true
                requests = snapshot.requests.map {
                    RequestState($0, sessionIsCopilot: sessionIsCopilot)
                }
                return requests.compactMap(makeEvent)

            case 1:
                guard entry.path.count >= 3,
                      entry.path[0].string == "requests",
                      let index = entry.path[1].integer,
                      requests.indices.contains(index),
                      let field = entry.path.last?.string
                else { return [] }

                switch field {
                case "promptTokens":
                    // Only assign on a real integer: a float payload decodes
                    // to nil integerValue, and assigning nil would clobber a
                    // previously observed value.
                    if let value = entry.integerValue { requests[index].promptTokens = value }
                case "completionTokens":
                    if let value = entry.integerValue { requests[index].completionTokens = value }
                case "copilotCredits":
                    // Presence, including a zero value, identifies Copilot's
                    // request accounting without retaining the credit amount.
                    requests[index].hasCopilotEvidence = entry.doubleValue != nil
                case "result":
                    if let result = entry.resultValue {
                        requests[index].merge(result: result)
                    }
                default:
                    return []
                }
                return makeEvent(requests[index]).map { [$0] } ?? []

            case 2:
                guard entry.path.count == 1,
                      entry.path[0].string == "requests",
                      let additions = entry.requestValues,
                      !additions.isEmpty
                else { return [] }
                let states = additions.map {
                    RequestState($0, sessionIsCopilot: sessionIsCopilot)
                }
                if let insertionIndex = entry.insertionIndex,
                   insertionIndex >= 0, insertionIndex <= requests.count {
                    requests.insert(contentsOf: states, at: insertionIndex)
                } else {
                    requests.append(contentsOf: states)
                }
                return states.compactMap(makeEvent)

            default:
                return []
            }
        }

        private func makeEvent(_ request: RequestState) -> UsageEvent? {
            guard let requestId = request.requestId, !requestId.isEmpty,
                  let timestamp = request.timestamp, timestamp > 0,
                  request.hasCopilotEvidence
            else { return nil }
            let input = max(request.promptTokens ?? 0, 0)
            let output = max(request.completionTokens ?? 0, 0)
            guard input > 0 || output > 0 else { return nil }
            return UsageEvent(
                ts: timestamp,
                source: "copilot",
                model: request.model,
                inTokens: input,
                outTokens: output,
                cacheTokens: min(max(request.cacheReadTokens ?? 0, 0), input),
                repoPath: repoPath,
                sessionId: sessionId,
                dedupeKey: "copilot|\(sessionId ?? "unknown")|\(requestId)",
                cacheCreationTokens: request.cacheWriteTokens.map { max($0, 0) },
                reportedOutputTokens: output,
                reasoningTokens: request.reasoningTokens.map { min(max($0, 0), output) }
            )
        }
    }

    private struct RequestState {
        var requestId: String?
        var timestamp: Int?
        var model: String?
        var promptTokens: Int?
        var completionTokens: Int?
        var cacheReadTokens: Int?
        var cacheWriteTokens: Int?
        var reasoningTokens: Int?
        var hasCopilotEvidence: Bool

        init(_ snapshot: RequestSnapshot, sessionIsCopilot: Bool) {
            requestId = snapshot.requestId
            timestamp = snapshot.timestamp
            model = snapshot.modelId
            promptTokens = snapshot.promptTokens
            completionTokens = snapshot.completionTokens
            hasCopilotEvidence = sessionIsCopilot || snapshot.copilotCredits != nil
            merge(result: snapshot.result)
        }

        mutating func merge(result: ResultSnapshot?) {
            guard let result else { return }
            let usage = result.metadata?.usageBreakdown
            hasCopilotEvidence = hasCopilotEvidence || usage?.hasCopilotEvidence == true
            model = result.metadata?.resolvedModel ?? usage?.model ?? model
            promptTokens = promptTokens ?? usage?.promptTokens
            completionTokens = completionTokens ?? usage?.completionTokens
            cacheReadTokens = usage?.cacheReadTokens ?? cacheReadTokens
            cacheWriteTokens = usage?.cacheWriteTokens ?? cacheWriteTokens
            reasoningTokens = usage?.reasoningTokens ?? reasoningTokens
        }
    }

    private struct UsageBreakdown {
        var promptTokens = 0
        var completionTokens = 0
        private var promptDetailCacheReadTokens = 0
        private var copilotCacheReadTokens = 0
        var cacheWriteTokens = 0
        var reasoningTokens = 0
        var model: String?
        var hasCopilotEvidence = false

        var cacheReadTokens: Int {
            max(promptDetailCacheReadTokens, copilotCacheReadTokens)
        }

        mutating func add(_ usage: UsageSnapshot) {
            promptTokens = Self.saturatingAdd(promptTokens, usage.promptTokens ?? 0)
            completionTokens = Self.saturatingAdd(completionTokens, usage.completionTokens ?? 0)
            promptDetailCacheReadTokens = Self.saturatingAdd(
                promptDetailCacheReadTokens, usage.promptTokenDetails?.cachedTokens ?? 0)
            reasoningTokens = Self.saturatingAdd(
                reasoningTokens, usage.completionTokenDetails?.reasoningTokens ?? 0)
            if usage.copilotUsage != nil { hasCopilotEvidence = true }
            for detail in usage.copilotUsage?.tokenDetails ?? [] {
                model = detail.model ?? model
                if detail.tokenType == "cache_read" {
                    copilotCacheReadTokens = Self.saturatingAdd(
                        copilotCacheReadTokens, detail.tokenCount ?? 0)
                } else if detail.tokenType == "cache_write" {
                    cacheWriteTokens = Self.saturatingAdd(cacheWriteTokens, detail.tokenCount ?? 0)
                }
            }
        }

        private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
            let result = max(lhs, 0).addingReportingOverflow(max(rhs, 0))
            return result.overflow ? Int.max : result.partialValue
        }
    }

    private struct JournalEntry: Decodable {
        let kind: Int
        let path: [PathComponent]
        let insertionIndex: Int?
        let snapshot: SessionSnapshot?
        let requestValues: [RequestSnapshot]?
        let integerValue: Int?
        let doubleValue: Double?
        let resultValue: ResultSnapshot?

        private enum CodingKeys: String, CodingKey { case kind, k, i, v }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(Int.self, forKey: .kind)
            path = (try? container.decode([PathComponent].self, forKey: .k)) ?? []
            insertionIndex = try? container.decode(Int.self, forKey: .i)
            snapshot = kind == 0 ? try? container.decode(SessionSnapshot.self, forKey: .v) : nil
            requestValues = kind == 2 && path.count == 1 && path[0].string == "requests"
                ? try? container.decode([RequestSnapshot].self, forKey: .v) : nil
            if kind == 1, let field = path.last?.string {
                integerValue = field == "promptTokens" || field == "completionTokens"
                    ? try? container.decode(Int.self, forKey: .v) : nil
                doubleValue = field == "copilotCredits"
                    ? try? container.decode(Double.self, forKey: .v) : nil
                resultValue = field == "result"
                    ? try? container.decode(ResultSnapshot.self, forKey: .v) : nil
            } else {
                integerValue = nil
                doubleValue = nil
                resultValue = nil
            }
        }
    }

    private enum PathComponent: Decodable {
        case stringValue(String)
        case integerValue(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self = .integerValue(value)
            } else {
                self = .stringValue(try container.decode(String.self))
            }
        }

        var string: String? {
            guard case .stringValue(let value) = self else { return nil }
            return value
        }

        var integer: Int? {
            guard case .integerValue(let value) = self else { return nil }
            return value
        }
    }

    private struct SessionSnapshot: Decodable {
        let sessionId: String?
        let responderUsername: String?
        let requests: [RequestSnapshot]

        private enum CodingKeys: String, CodingKey { case sessionId, responderUsername, requests }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try? container.decode(String.self, forKey: .sessionId)
            responderUsername = try? container.decode(String.self, forKey: .responderUsername)
            requests = (try? container.decode([RequestSnapshot].self, forKey: .requests)) ?? []
        }
    }

    private struct RequestSnapshot: Decodable {
        let requestId: String?
        let timestamp: Int?
        let modelId: String?
        let promptTokens: Int?
        let completionTokens: Int?
        let copilotCredits: Double?
        let result: ResultSnapshot?
    }

    private struct ResultSnapshot: Decodable {
        let metadata: ResultMetadata?
    }

    private struct ResultMetadata: Decodable {
        let resolvedModel: String?
        let summaries: [UsageSummary]?

        var usageBreakdown: UsageBreakdown? {
            guard let summaries, !summaries.isEmpty else { return nil }
            var result = UsageBreakdown()
            for summary in summaries {
                if let usage = summary.usage { result.add(usage) }
            }
            return result
        }
    }

    private struct UsageSummary: Decodable {
        let usage: UsageSnapshot?
    }

    private struct UsageSnapshot: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let promptTokenDetails: PromptTokenDetails?
        let completionTokenDetails: CompletionTokenDetails?
        let copilotUsage: CopilotUsage?

        private enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case promptTokenDetails = "prompt_tokens_details"
            case completionTokenDetails = "completion_tokens_details"
            case copilotUsage = "copilot_usage"
        }
    }

    private struct PromptTokenDetails: Decodable {
        let cachedTokens: Int?
        private enum CodingKeys: String, CodingKey { case cachedTokens = "cached_tokens" }
    }

    private struct CompletionTokenDetails: Decodable {
        let reasoningTokens: Int?
        private enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
    }

    private struct CopilotUsage: Decodable {
        let tokenDetails: [CopilotTokenDetail]?
        private enum CodingKeys: String, CodingKey { case tokenDetails = "token_details" }
    }

    private struct CopilotTokenDetail: Decodable {
        let model: String?
        let tokenCount: Int?
        let tokenType: String?
        private enum CodingKeys: String, CodingKey {
            case model
            case tokenCount = "token_count"
            case tokenType = "token_type"
        }
    }
}
