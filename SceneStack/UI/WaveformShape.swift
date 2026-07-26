import SwiftUI

/// Mirrored min/max bar waveform drawn from precomputed peaks. Shared by the
/// session grid cells and arrangement placements.
struct WaveformShape: Shape {
    let peaks: [Float]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !peaks.isEmpty else { return path }
        let barWidth = rect.width / CGFloat(peaks.count)
        let middle = rect.midY
        for (index, peak) in peaks.enumerated() {
            let height = max(1, CGFloat(peak) * rect.height / 2)
            let x = rect.minX + CGFloat(index) * barWidth
            path.addRect(CGRect(x: x, y: middle - height,
                                width: max(0.5, barWidth * 0.65), height: height * 2))
        }
        return path
    }
}

/// Waveform repeated once per loop iteration — arrangement placements longer
/// than their clip show the loop tiling rather than one stretched image.
struct TiledWaveformShape: Shape {
    let peaks: [Float]
    /// Number of loop repetitions across the rect (may be fractional).
    let repeats: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !peaks.isEmpty, repeats > 0 else { return path }
        let tileWidth = rect.width / CGFloat(repeats)
        guard tileWidth > 4 else { return WaveformShape(peaks: peaks).path(in: rect) }

        let middle = rect.midY
        let binWidth = tileWidth / CGFloat(peaks.count)
        var tileX = rect.minX
        while tileX < rect.maxX - 0.5 {
            let tileEnd = min(tileX + tileWidth, rect.maxX)
            var x = tileX
            for peak in peaks {
                if x >= tileEnd { break }
                let height = max(1, CGFloat(peak) * rect.height / 2)
                path.addRect(CGRect(x: x, y: middle - height,
                                    width: max(0.5, binWidth * 0.65), height: height * 2))
                x += binWidth
            }
            tileX += tileWidth
        }
        return path
    }
}
