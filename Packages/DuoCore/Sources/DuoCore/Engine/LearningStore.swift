import Foundation

/// One vote recorded in the ``LearningStore``, kept by the engine so it can be cancelled exactly
/// (flipping back cancels the vote, critique R7).
public struct LearningVote: Sendable, Hashable {
    public var raw: String
    public var context: LanguageContext
    public var hypothesis: Hypothesis
    /// Votes added (3 for a flip, 1 for an ambiguous implicit commit).
    public var amount: Double

    /// A vote of `amount` for `hypothesis` at `(raw, context)`.
    public init(raw: String, context: LanguageContext, hypothesis: Hypothesis, amount: Double) {
        self.raw = raw
        self.context = context
        self.hypothesis = hypothesis
        self.amount = amount
    }
}

/// In-memory learned votes keyed by `(raw, context)` (critique R7). Read synchronously while
/// scoring; persistence is DuoKit.LearningWriter's job (subscribe via `onChange`).
///
/// - Values are exponentially decayed votes with a 60-day half-life: an entry stores its votes as of
///   `updatedAt`, and a read multiplies them by `0.5^(age / 60 d)`. The detector receives
///   `n_eff = Int(value.rounded())` per hypothesis, so scoring stays integer.
/// - Votes are kept within `0 < v ≤` ``maxVotes`` and keys within ``maxRawLength``: a corrupted or
///   hand-edited `learning.json` must not trap `Int(_:)` on a keystroke (the IME would crash-loop).
/// - At most ``capacity`` entries; the least recently updated ones are evicted first.
@MainActor
public final class LearningStore {
    /// Decay half-life (critique R7).
    public static let halfLife: TimeInterval = 60 * 24 * 60 * 60
    /// LRU cap (detection.md §5.5).
    public static let capacity = 20_000
    /// Votes for an explicit flip.
    public static let flipVotes: Double = 3
    /// Votes for an ambiguous commit accepted without a flip (final margin ≤ `Margins.hudAlternative`).
    public static let implicitVotes: Double = 1
    /// Most votes one hypothesis can hold. The detector's user bonus saturates at 15 (`USER_LOG2`),
    /// so nothing is lost; real use stays far below (votes grow by 1 or 3 and decay).
    public static let maxVotes: Double = 1_000
    /// Longest key string kept: tokens are capped at 32 keys, so anything longer is junk.
    public static let maxRawLength = 64

    /// Called after every change (recorded vote, removal, replacement).
    public var onChange: (() -> Void)?

    private struct Key: Hashable {
        var raw: String
        var context: LanguageContext
    }

    private var table: [Key: LearningEntry] = [:]
    private let now: () -> Date

    /// - Parameters:
    ///   - snapshot: entries loaded from `learning.json`.
    ///   - now: the clock (tests inject one).
    public init(snapshot: LearningSnapshot = LearningSnapshot(), now: @escaping () -> Date = Date.init) {
        self.now = now
        load(snapshot)
    }

    /// Number of `(raw, context)` entries.
    public var count: Int { table.count }

    /// Effective decayed counts for the detector, or `nil` if nothing is learned for this key.
    public func counts(raw: String, context: LanguageContext) -> UserCounts? {
        guard let entry = table[Key(raw: raw, context: context)] else { return nil }
        let factor = decayFactor(since: entry.updatedAt)
        var counts: [Hypothesis: Int] = [:]
        for (key, votes) in entry.votes {
            let v = votes * factor
            guard v.isFinite, v > 0 else { continue }
            let n = Int(min(v, Self.maxVotes).rounded())
            if n > 0, let h = Hypothesis(key: key) { counts[h] = n }
        }
        return counts.isEmpty ? nil : UserCounts(counts)
    }

    /// Decayed (unrounded) votes per hypothesis, for Settings ▸ 학습.
    public func effectiveVotes(raw: String, context: LanguageContext) -> [Hypothesis: Double] {
        guard let entry = table[Key(raw: raw, context: context)] else { return [:] }
        let factor = decayFactor(since: entry.updatedAt)
        var out: [Hypothesis: Double] = [:]
        for (key, votes) in entry.votes {
            if let h = Hypothesis(key: key) { out[h] = votes * factor }
        }
        return out
    }

    /// Adds `votes` for `hypothesis` at `(raw, context)`. Returns the vote so it can be cancelled.
    @discardableResult
    public func record(raw: String, context: LanguageContext, hypothesis: Hypothesis,
                       votes: Double) -> LearningVote {
        let vote = LearningVote(raw: raw, context: context, hypothesis: hypothesis, amount: votes)
        apply(vote, sign: 1)
        return vote
    }

    /// Takes back a vote recorded earlier (never below zero).
    public func cancel(_ vote: LearningVote) {
        apply(vote, sign: -1)
    }

    /// All entries, most recently updated first (stable order for the file and the UI).
    public func snapshot() -> LearningSnapshot {
        LearningSnapshot(entries: entriesNewestFirst())
    }

    /// Replaces everything (host-app reset, file reload).
    public func replace(with snapshot: LearningSnapshot) {
        load(snapshot)
        onChange?()
    }

    /// Remove one key string (all contexts when `context == nil`).
    ///
    /// - Returns: whether anything was removed (nothing changes, and `onChange` is not called, otherwise).
    @discardableResult
    public func remove(raw: String, context: LanguageContext?) -> Bool {
        let before = table.count
        if let context {
            table[Key(raw: raw, context: context)] = nil
        } else {
            table = table.filter { $0.key.raw != raw }
        }
        guard table.count != before else { return false }
        onChange?()
        return true
    }

    /// Forget everything ("학습한 단어 초기화").
    ///
    /// - Returns: whether there was anything to forget.
    @discardableResult
    public func removeAll() -> Bool {
        guard !table.isEmpty else { return false }
        table.removeAll()
        onChange?()
        return true
    }

    // MARK: - Internals

    private func decayFactor(since date: Date) -> Double {
        let age = max(0, now().timeIntervalSince(date))
        return pow(0.5, age / Self.halfLife)
    }

    private func apply(_ vote: LearningVote, sign: Double) {
        guard vote.amount.isFinite, vote.amount > 0, !vote.raw.isEmpty, vote.raw.utf8.count <= Self.maxRawLength else { return }
        let key = Key(raw: vote.raw, context: vote.context)
        let date = now()
        var entry = table[key] ?? LearningEntry(raw: vote.raw, context: vote.context, votes: [:], updatedAt: date)
        // Bring the stored votes forward to `now`, so `updatedAt` can move.
        let factor = decayFactor(since: entry.updatedAt)
        if factor != 1 { entry.votes = entry.votes.mapValues { $0 * factor } }
        entry.updatedAt = date
        let h = vote.hypothesis.key
        let value = min((entry.votes[h] ?? 0) + sign * vote.amount, Self.maxVotes)
        entry.votes[h] = value > 1e-6 ? value : nil
        if entry.votes.isEmpty {
            guard table.removeValue(forKey: key) != nil else { return }
        } else {
            table[key] = entry
            evictIfNeeded()
        }
        onChange?()
    }

    private func load(_ snapshot: LearningSnapshot) {
        table.removeAll(keepingCapacity: true)
        for entry in snapshot.entries where !entry.raw.isEmpty && entry.raw.utf8.count <= Self.maxRawLength
            && entry.updatedAt.timeIntervalSinceReferenceDate.isFinite {
            let votes = entry.votes
                .filter { Hypothesis(key: $0.key) != nil && $0.value.isFinite && $0.value > 0 }
                .mapValues { min($0, Self.maxVotes) }
            let factor = decayFactor(since: entry.updatedAt)
            // Entries that decayed to nothing would only take space.
            guard votes.values.contains(where: { ($0 * factor).rounded() >= 1 }) else { continue }
            let key = Key(raw: entry.raw, context: entry.context)
            if let existing = table[key], existing.updatedAt >= entry.updatedAt { continue }
            table[key] = LearningEntry(raw: entry.raw, context: entry.context, votes: votes, updatedAt: entry.updatedAt)
        }
        evictIfNeeded()
    }

    /// LRU by `updatedAt`. Evicts down to 95 % of the cap at once, so the ordering (a few ms at the
    /// cap, on the keystroke that records the entry) runs once per thousand new entries.
    private func evictIfNeeded() {
        guard table.count > Self.capacity else { return }
        let target = Self.capacity - Self.capacity / 20
        for entry in entriesNewestFirst().dropFirst(target) {
            table[Key(raw: entry.raw, context: entry.context)] = nil
        }
    }

    /// `updatedAt` plus the entry's position, ordered newest first. Sorting these plain keys costs
    /// about a twentieth of sorting the entries with a comparator closure (≈ 60 ms at the cap on the
    /// IME's main thread before).
    private struct OrderKey: Comparable {
        var time: TimeInterval
        var index: Int

        static func < (a: OrderKey, b: OrderKey) -> Bool {
            a.time != b.time ? a.time > b.time : a.index < b.index
        }
    }

    /// Every entry, most recently updated first; equal dates (the file keeps whole seconds) are
    /// ordered by raw, then context, so the order never depends on hashing.
    private func entriesNewestFirst() -> [LearningEntry] {
        let entries = Array(table.values)
        var keys = entries.indices.map { OrderKey(time: entries[$0].updatedAt.timeIntervalSinceReferenceDate, index: $0) }
        keys.sort()
        var sorted = keys.map { entries[$0.index] }
        var start = 0
        while start < keys.count {
            var end = start + 1
            while end < keys.count, keys[end].time == keys[start].time { end += 1 }
            if end - start > 1 { sorted[start..<end].sort(by: Self.newestFirst) }
            start = end
        }
        return sorted
    }

    private static func newestFirst(_ a: LearningEntry, _ b: LearningEntry) -> Bool {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        if a.raw != b.raw { return a.raw < b.raw }
        return a.context.rawValue < b.context.rawValue
    }
}
