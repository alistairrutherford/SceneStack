import SwiftUI

/// Bottom inspector for the selected session clip: a large waveform with a
/// playback position indicator that tracks the loop while it plays.
struct ClipDetailBar: View {
    @Environment(TransportEngine.self) private var engine

    private var selection: (track: Track, clip: Clip)? {
        guard let slot = engine.selectedSlot,
              let track = engine.tracks.first(where: { $0.id == slot.trackID }),
              slot.scene < track.slots.count,
              let clip = track.slots[slot.scene] else { return nil }
        return (track, clip)
    }

    /// The track being recorded into, if any. While a take is in progress the
    /// inspector follows it — the destination slot is still empty, so there is
    /// no clip to select yet.
    private var recordingTrack: Track? {
        guard let slot = engine.recordingSlot else { return nil }
        return engine.tracks.first { $0.id == slot.trackID }
    }

    var body: some View {
        HStack(spacing: 14) {
            if let track = recordingTrack {
                recordingView(track: track)
            } else if let (track, clip) = selection {
                let color = Theme.trackPalette[clip.colorIndex % Theme.trackPalette.count]

                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.name)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(color)
                        .lineLimit(1)
                    Text("\(clip.loopBars) bar\(clip.loopBars == 1 ? "" : "s") · \(track.name)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.dimmed)
                        .lineLimit(1)
                }
                .frame(width: 110, alignment: .leading)

                divider

                waveformView(clip: clip, track: track, color: color)
            } else {
                Text("Select a clip to inspect its waveform")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.dimmed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(height: 84)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        )
    }

    private var divider: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.white.opacity(0.08))
            .frame(width: 2, height: 40)
    }

    /// Inspector contents while a take is being captured: the live waveform,
    /// over a bar grid of the target length when the length is fixed.
    private func recordingView(track: Track) -> some View {
        let bars = engine.recordFixedLengthBeats.map { Int($0) / max(1, engine.beatsPerBar) }

        return Group {
            VStack(alignment: .leading, spacing: 2) {
                // `isCountingIn` comes from the polled transport clock, not
                // observable state, so it needs a tick to refresh — otherwise
                // the label stays on "Counting in…" for the whole take.
                TimelineView(.animation(minimumInterval: 1.0 / 10, paused: false)) { _ in
                    Text(engine.isCountingIn ? "Counting in…" : "Recording")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.coral)
                        .lineLimit(1)
                }
                Text("\(bars.map { "\($0) bar\($0 == 1 ? "" : "s")" } ?? "free") · \(track.name)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.dimmed)
                    .lineLimit(1)
            }
            .frame(width: 110, alignment: .leading)

            divider

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.3))
                // No `windowBars` override: a fixed take scales to the chosen
                // REC BARS length, a free one to the shared 2-bar window.
                LiveRecordingWaveform(color: Theme.coral, showsGrid: true)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
            }
        }
    }

    private func waveformView(clip: Clip, track: Track, color: Color) -> some View {
        TimelineView(.animation) { _ in
            // Compute the play position here (per tick), OUTSIDE the
            // GeometryReader — a GeometryReader won't re-run its content on a
            // TimelineView tick unless a captured value actually changes.
            let state = engine.playback[track.id]
            let isPlaying = state?.playingClipID == clip.id
            let loopBeats = Double(clip.loopBars * engine.beatsPerBar)
            let elapsed = engine.currentBeats - (state?.playingStartBeat ?? 0)
            let fraction = (isPlaying && loopBeats > 0)
                ? max(0, elapsed.truncatingRemainder(dividingBy: loopBeats)) / loopBeats
                : 0

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.3))

                    // Bar/beat grid behind the waveform, Ableton-style.
                    Canvas { context, size in
                        let totalBeats = clip.loopBars * engine.beatsPerBar
                        guard totalBeats > 0 else { return }
                        for beat in 0...totalBeats {
                            let x = size.width * CGFloat(beat) / CGFloat(totalBeats)
                            let isBarLine = beat % engine.beatsPerBar == 0
                            context.fill(
                                Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                                with: .color(.white.opacity(isBarLine ? 0.18 : 0.06)))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    WaveformShape(peaks: clip.detailWaveform)
                        .fill(color.opacity(0.8))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 6)

                    // Ableton-style follow line sweeping the loop while it
                    // plays, with a triangle marker at the top.
                    if isPlaying {
                        let x = proxy.size.width * fraction
                        Rectangle()
                            .fill(Color.white.opacity(0.95))
                            .frame(width: 2)
                            .shadow(color: .black.opacity(0.5), radius: 1)
                            .position(x: x, y: proxy.size.height / 2)
                            .allowsHitTesting(false)
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .position(x: x, y: 4)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}
