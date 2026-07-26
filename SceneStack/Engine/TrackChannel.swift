import AVFoundation

/// Audio nodes for one track: two alternating players feeding the track's
/// mixer, so a queued clip can be scheduled sample-accurately on the idle
/// player while the current one keeps sounding until the boundary.
/// All clip buffers are normalised to the engine's standard format, so both
/// players are connected once and never reconnected.
@MainActor
final class TrackChannel {
    let players = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    /// Collects both players so the effect chain has a single input;
    /// effects run between this and `mixer` (the post-fx fader/pan stage).
    let inputMixer = AVAudioMixerNode()
    let mixer = AVAudioMixerNode()
    let meter = MeterTap()
    var activeIndex = 0
    /// Pending boundary task (clip switch or queued stop).
    var pendingTask: Task<Void, Never>?

    func stopAllPlayers() {
        players[0].stop()
        players[1].stop()
    }
}
