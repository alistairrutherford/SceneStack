import Foundation

/// Pure transport/beat math, extracted from `TransportEngine` so it can be
/// unit-tested without instantiating the audio engine.
enum BeatMath {

    /// Next launch/quantise boundary at or after `currentBeats`, always nudged
    /// slightly into the future (`lead`) so the player start stays schedulable.
    static func quantizedBoundary(afterBeats currentBeats: Double,
                                  tempo: Double,
                                  beatsPerBar: Int,
                                  quantize: LaunchQuantize) -> Double {
        let lead = 0.05 * tempo / 60
        let beats = max(0, currentBeats) + lead
        switch quantize {
        case .none: return beats
        case .beat: return beats.rounded(.up)
        case .bar:
            let bars = Double(max(1, beatsPerBar))
            return bars * (beats / bars).rounded(.up)
        }
    }

    /// How many whole bars a take becomes. A fixed length is returned as-is;
    /// free mode rounds the recorded span up to whole bars (minimum 1). The
    /// small epsilon is *subtracted* so a take that stops a hair short of a
    /// bar boundary still counts as that whole bar (rather than rounding up to
    /// an extra one).
    static func recordedBars(beatsRecorded: Double, beatsPerBar: Int, fixed: Int?) -> Int {
        if let fixed { return fixed }
        let bars = (beatsRecorded - 0.05) / Double(max(1, beatsPerBar))
        return max(1, Int(bars.rounded(.up)))
    }

    /// Where a row index ends up after moving the row at `source` to
    /// `destination` (identical permutation applied to every track).
    static func sceneIndexAfterMove(_ index: Int, from source: Int, to destination: Int) -> Int {
        if index == source { return destination }
        if source < destination, index > source, index <= destination { return index - 1 }
        if source > destination, index >= destination, index < source { return index + 1 }
        return index
    }
}
