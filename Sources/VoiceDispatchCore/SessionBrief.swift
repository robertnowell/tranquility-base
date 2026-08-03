import Foundation

/// What you need to know about one finished turn when ten sessions are in flight.
///
/// Prose alone doesn't work here. "The fix has never run in the deployed pipeline"
/// is true, but out of context it names no subject, proposes no action, and asks
/// nothing — you cannot act on it without opening the tab, which defeats the point.
/// So the model fills fields, and the spoken line is assembled from them in priority
/// order rather than being freely written.
public struct SessionBrief: Codable, Sendable, Equatable {
    /// The one sentence you actually hear, written by the model FOR THE EAR.
    ///
    /// Assembling this from the fields below produced noun-phrase salad — "Product
    /// grid images inheriting from reference email" is a ticket title, not something
    /// a person says. Six fields also cannot be spoken: reading the whole card aloud
    /// runs past a minute, and the point is a seven-second interruption.
    public var spoken: String?
    /// 3–6 words naming the subject. Always spoken first, because "which session?"
    /// is the question you have before any other.
    public var topic: String
    /// What this session set out to do. Comes from the opening ask, not the last turn.
    public var goal: String?
    /// What just concluded.
    public var happened: String
    /// The proposed next action, if there is a real one.
    public var nextStep: String?
    /// A genuine question being put to you. Blocks progress, so it outranks nextStep.
    public var question: String?
    /// A risk or uncertainty worth knowing before you answer.
    public var risk: String?

    // Deterministic — never written by the model.
    public var branch: String?
    public var pullRequest: PullRequestRef?

    public init(
        topic: String, goal: String? = nil, happened: String, nextStep: String? = nil,
        question: String? = nil, risk: String? = nil, branch: String? = nil,
        pullRequest: PullRequestRef? = nil, spoken: String? = nil
    ) {
        self.spoken = spoken
        self.topic = topic
        self.goal = goal
        self.happened = happened
        self.nextStep = nextStep
        self.question = question
        self.risk = risk
        self.branch = branch
        self.pullRequest = pullRequest
    }

    /// The ~12 seconds you actually hear. Topic first so you know which session is
    /// talking, then the outcome, then the one thing that wants a decision. A
    /// question outranks a next step because it blocks; everything else is readable
    /// on the card.
    public func spokenText() -> String {
        // Prefer the authored sentence. The assembled form is a fallback for the
        // deterministic provider, which has no model to write one.
        if let spoken, !spoken.isEmpty {
            if let pullRequest, !spoken.lowercased().contains("pull request") {
                return "\(spoken) Pull request \(pullRequest.number) is \(pullRequest.state.lowercased())."
            }
            return spoken
        }
        var parts: [String] = ["\(topic)."]
        parts.append(happened.hasSuffix(".") ? happened : happened + ".")

        if let question, !question.isEmpty {
            parts.append(question)
        } else if let nextStep, !nextStep.isEmpty {
            parts.append(nextStep.hasSuffix(".") ? nextStep : nextStep + ".")
        }

        if let pullRequest {
            parts.append("Pull request \(pullRequest.number) is \(pullRequest.state.lowercased()).")
        }
        return parts.joined(separator: " ")
    }

    /// Everything, for the card in the queue and the overlay.
    public func cardLines() -> [(String, String)] {
        var lines: [(String, String)] = [("topic", topic)]
        if let goal { lines.append(("goal", goal)) }
        lines.append(("happened", happened))
        if let question { lines.append(("question", question)) }
        if let nextStep { lines.append(("next", nextStep)) }
        if let risk { lines.append(("risk", risk)) }
        // Branch is card metadata only — nobody needs a branch name read aloud.
        if let branch { lines.append(("branch", branch)) }
        if let pullRequest {
            lines.append(("pr", "#\(pullRequest.number) \(pullRequest.state) — \(pullRequest.title)"))
        }
        return lines
    }
}

public struct PullRequestRef: Codable, Sendable, Equatable {
    public var number: Int
    public var title: String
    public var state: String
    public var url: String
}

/// Looks up a pull request for a branch. Deterministic — the model is never asked
/// whether a PR exists, because it would guess.
public enum PullRequestLookup {
    public static func forBranch(_ branch: String, cwd: String?) -> PullRequestRef? {
        guard !branch.isEmpty, branch != "main", branch != "master" else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-lc",
            "gh pr list --head \(branch.shellQuoted) --state all --limit 1 --json number,title,state,url",
        ]
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return (try? JSONDecoder().decode([PullRequestRef].self, from: data))?.first
    }
}

extension String {
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
