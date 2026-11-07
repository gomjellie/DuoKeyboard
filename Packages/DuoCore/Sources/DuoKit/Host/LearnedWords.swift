import DuoCore
import Foundation

/// One row of Settings ▸ 학습: a learned key string in one context (critique R7, P2).
public struct LearnedWord: Identifiable, Hashable, Sendable {
    /// Rows are unique per `(raw, context)` (critique R7).
    public struct ID: Hashable, Sendable {
        /// The keys as typed.
        public var raw: String
        /// The context the votes apply in.
        public var context: LanguageContext

        /// The row for `raw` in `context`.
        public init(raw: String, context: LanguageContext) {
            self.raw = raw
            self.context = context
        }
    }

    /// `(raw, context)`.
    public var id: ID { ID(raw: raw, context: context) }
    /// The keys as typed (ABC layout), e.g. `"dkssud"`.
    public var raw: String
    /// The context the votes apply in (문맥).
    public var context: LanguageContext
    /// The reading with the most votes; ties go to the earlier candidate (K, E, M1, M2, …).
    public var winner: Hypothesis
    /// Sum of all votes, decayed to `now` (60-day half-life). Bounded: every vote is clamped to
    /// ``LearnedWords/maxVote`` first.
    public var weight: Double
    /// The winner's own votes, decayed to `now`: what the detector's user bonus is computed from.
    public var winnerWeight: Double
    /// When the entry last changed (`LearningEntry.updatedAt`).
    public var lastUsed: Date

    /// Creates a row. `winnerWeight` defaults to `weight` (a row whose votes all agree).
    public init(raw: String, context: LanguageContext, winner: Hypothesis, weight: Double,
                winnerWeight: Double? = nil, lastUsed: Date) {
        self.raw = raw
        self.context = context
        self.winner = winner
        self.weight = weight
        self.winnerWeight = winnerWeight ?? weight
        self.lastUsed = lastUsed
    }

    /// How strongly the learned votes pull the detector towards ``winner``, from 0 to 1.
    ///
    /// The detector adds `USER_LOG2[min(n, 15)]` = log2(1 + n) for the winner's `n` votes, so the
    /// pull grows logarithmically and stops growing at 15 votes: one flip (+3) is already half of it.
    public var strength: Double {
        let n = winnerWeight.isFinite ? min(max(winnerWeight, 0), LearnedWords.saturatingVotes) : 0
        return log2(1 + n) / log2(1 + LearnedWords.saturatingVotes)
    }
}

/// Pure helpers over `LearningSnapshot` for the host app.
public enum LearnedWords {
    /// Vote half-life (critique R7).
    public static let halfLife: TimeInterval = 60 * 24 * 60 * 60
    /// The largest vote one reading can carry. A larger (corrupt or hand-edited) value is clamped,
    /// so the table's arithmetic and integer conversions stay in range (safety-2). Nothing real is
    /// lost: the detector's bonus saturates at ``saturatingVotes``.
    public static let maxVote: Double = 1_000
    /// The vote count at which the detector's user bonus stops growing (`USER_LOG2[min(n, 15)]`).
    public static let saturatingVotes: Double = 15
    /// Longer key strings are not words a person typed; the table leaves them out.
    public static let maxRawLength = 64

    /// `votes · 0.5^((now − since) / 60 d)`; never grows for dates in the future.
    public static func decayed(_ votes: Double, since: Date, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(since))
        return votes * pow(0.5, age / halfLife)
    }

    /// A stored vote as the table uses it: positive and finite, clamped to ``maxVote``; else `nil`.
    static func sanitized(_ vote: Double) -> Double? {
        vote.isFinite && vote > 0 ? min(vote, maxVote) : nil
    }

    /// Candidate order used for ties (detection.md §5.4): K, E, then M(b) by ascending b.
    static func order(_ h: Hypothesis) -> Int {
        switch h {
        case .korean: 0
        case .english: 1
        case .mixed(let b): 1 + b
        }
    }

    /// The hypothesis with the most (positive, finite) votes, or `nil` when no key parses or nothing
    /// is positive.
    public static func winner(of votes: [String: Double]) -> Hypothesis? {
        winnerAndVotes(of: votes)?.0
    }

    static func winnerAndVotes(of votes: [String: Double]) -> (Hypothesis, Double)? {
        let candidates = votes.compactMap { key, value -> (Hypothesis, Double)? in
            guard let h = Hypothesis(key: key), let v = sanitized(value) else { return nil }
            return (h, v)
        }
        return candidates.min { a, b in
            a.1 != b.1 ? a.1 > b.1 : order(a.0) < order(b.0)
        }
    }

    /// Display rows, grouped by key string (sorted by `raw`, then context order START, KO, EN, NUM).
    public static func words(in snapshot: LearningSnapshot, now: Date = Date()) -> [LearnedWord] {
        let contexts = LanguageContext.allCases
        return snapshot.entries.compactMap { entry -> LearnedWord? in
            guard !entry.raw.isEmpty, entry.raw.count <= maxRawLength,
                  let (winner, winnerVotes) = winnerAndVotes(of: entry.votes) else { return nil }
            let total = entry.votes.values.compactMap(sanitized).reduce(0, +)
            return LearnedWord(raw: entry.raw, context: entry.context, winner: winner,
                               weight: decayed(total, since: entry.updatedAt, now: now),
                               winnerWeight: decayed(winnerVotes, since: entry.updatedAt, now: now),
                               lastUsed: entry.updatedAt)
        }
        .sorted { a, b in
            a.raw != b.raw
                ? a.raw.localizedStandardCompare(b.raw) == .orderedAscending
                : (contexts.firstIndex(of: a.context) ?? 0) < (contexts.firstIndex(of: b.context) ?? 0)
        }
    }

    /// `snapshot` without the entries for `raw` (every context when `context` is `nil`).
    public static func removing(raw: String, context: LanguageContext?, from snapshot: LearningSnapshot) -> LearningSnapshot {
        var copy = snapshot
        copy.entries.removeAll { $0.raw == raw && (context == nil || $0.context == context) }
        return copy
    }
}

extension LearningCommand {
    /// `snapshot` with the command applied: the host's direct-write path when no IME runs.
    public func applied(to snapshot: LearningSnapshot) -> LearningSnapshot {
        switch self {
        case .remove(let raw, let context): LearnedWords.removing(raw: raw, context: context, from: snapshot)
        case .removeAll: LearningSnapshot()
        }
    }
}
