import SwiftUI

/// The take's waveform, drawn live as it is captured. Shared by the grid cell
/// being recorded into and the clip inspector.
///
/// Fixed length: the full width represents the whole clip, so the waveform
/// fills left-to-right and the empty remainder shows how much is still to
/// record. Free length: it grows from the left until it reaches the right-hand
/// edge, then scrolls, always showing the most recent `windowBars`.
struct LiveRecordingWaveform: View {
    @Environment(TransportEngine.self) private var engine

    /// How many bars the full width spans once a free take starts scrolling.
    var windowBars: Double = 2
    var color: Color = .white
    /// Draws bar/beat lines behind the waveform (used by the larger inspector).
    var showsGrid = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { _ in
            // Computed per tick, outside the GeometryReader — a GeometryReader
            // won't re-run its content on a tick unless a captured value changes.
            let secondsPerBeat = 60.0 / max(1, engine.tempo)
            let elapsed = max(0, engine.recordedBeats) * secondsPerBeat
            let fixedBeats = engine.recordFixedLengthBeats
            let windowBeats = fixedBeats ?? windowBars * Double(engine.beatsPerBar)
            let window = windowBeats * secondsPerBeat
            let fraction = window > 0 ? min(1, elapsed / window) : 0
            // A free take scrolls once it has filled the width; a fixed one
            // keeps filling towards its end.
            let scrolling = fixedBeats == nil && fraction >= 1

            GeometryReader { proxy in
                let bins = max(8, Int(proxy.size.width / 2.5))
                let drawnWidth = scrolling ? proxy.size.width : proxy.size.width * fraction
                let peaks = engine.liveRecordingWaveform(
                    bins: max(4, Int(Double(bins) * (scrolling ? 1 : fraction))),
                    lastSeconds: scrolling ? window : nil)

                ZStack(alignment: .leading) {
                    if showsGrid {
                        grid(beats: Int(windowBeats.rounded()))
                    } else if !scrolling {
                        // Faint bed showing the space still to be filled.
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.black.opacity(0.14))
                            .frame(height: 2)
                    }

                    WaveformShape(peaks: peaks)
                        .fill(color.opacity(0.9))
                        .frame(width: drawnWidth)

                    // Write head at the leading edge of the untouched space.
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 1.5)
                        .offset(x: max(0, drawnWidth - 1.5))
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            }
        }
        .allowsHitTesting(false)
    }

    private func grid(beats: Int) -> some View {
        Canvas { context, size in
            guard beats > 0 else { return }
            for beat in 0...beats {
                let x = size.width * CGFloat(beat) / CGFloat(beats)
                let isBarLine = beat % max(1, engine.beatsPerBar) == 0
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                             with: .color(.white.opacity(isBarLine ? 0.18 : 0.06)))
            }
        }
    }
}
