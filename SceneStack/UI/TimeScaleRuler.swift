import SwiftUI

/// Numbered seconds ruler for a waveform window, shared by the clip inspector
/// and the live recording view.
///
/// Ticks sit on absolute second boundaries rather than fixed screen positions,
/// so when the window slides (a free-length take scrolling past its window) the
/// numbers travel with the audio instead of standing still underneath it.
struct TimeScaleRuler: View {
    /// Seconds at the left edge of the window.
    var start: Double = 0
    /// Seconds spanned by the full width.
    let window: Double

    var body: some View {
        Canvas { context, size in
            guard window > 0, size.width > 0 else { return }
            let step = Self.tickStep(forWindow: window, width: size.width)
            var seconds = (start / step).rounded(.up) * step
            while seconds <= start + window + 1e-6 {
                let x = size.width * CGFloat((seconds - start) / window)
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: 3)),
                             with: .color(.white.opacity(0.28)))
                context.draw(
                    Text(Self.label(seconds: seconds, step: step))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.dimmed),
                    at: CGPoint(x: x + 3, y: size.height / 2), anchor: .leading)
                seconds += step
            }
        }
    }

    /// A round interval — 0.25, 0.5, 1, 2, 5… — giving roughly one label every
    /// 70pt, so the numbers never collide however long the window is.
    static func tickStep(forWindow window: Double, width: CGFloat) -> Double {
        let target = window / max(2, Double(width) / 70)
        let candidates: [Double] = [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        return candidates.first { $0 >= target } ?? candidates.last!
    }

    static func label(seconds: Double, step: Double) -> String {
        step < 1 ? String(format: "%.2gs", seconds) : "\(Int(seconds.rounded()))s"
    }
}
