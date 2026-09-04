import Foundation

/// Pure decision helper for "is this incoming transcript about to silently
/// replace a much longer existing one?". Used by both the diarization apply
/// path and the retranscribe completion path so the shrink heuristic lives in
/// exactly one place (never re-implemented inside a View).
enum TranscriptOverwriteGuard {
    /// Incoming shorter than this fraction of the existing text counts as a
    /// destructive shrink. Strictly-less comparison: exactly at the ratio is
    /// NOT destructive.
    static let shrinkRatioThreshold = 0.5

    /// Existing texts shorter than this are never guarded — small entries
    /// legitimately change size a lot and nagging on them is noise.
    static let minExistingCharsToGuard = 200

    /// Whether applying `incomingText` over `existingText` would shrink the
    /// transcript enough to warrant a confirmation prompt.
    ///
    /// `true` only when both hold:
    ///   - `existingText.count >= minExistingCharsToGuard`
    ///   - `incomingText.count < Int(Double(existingText.count) * shrinkRatioThreshold)`
    static func isDestructiveShrink(existingText: String, incomingText: String) -> Bool {
        guard existingText.count >= minExistingCharsToGuard else { return false }
        let threshold = Int(Double(existingText.count) * shrinkRatioThreshold)
        return incomingText.count < threshold
    }
}
