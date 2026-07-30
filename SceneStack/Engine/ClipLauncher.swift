import AVFoundation

/// Sample-accurate session-clip launching and stopping.
///
/// Split out of `TransportEngine`: it owns none of the observed transport state
/// (that stays on the engine so SwiftUI keeps observing it) and drives it
/// through an `unowned` back-reference. Launches are scheduled on the audio
/// thread via `AVAudioPlayerNode.play(at:)`; the boundary bookkeeping (swapping
/// the active player, updating `playback`) runs in async tasks that wake on the
/// transport clock.
@MainActor
final class ClipLauncher {
    unowned let engine: TransportEngine

    /// Length of the fade that ends an outgoing clip at a boundary. Long
    /// enough to de-click, short enough that it reads as a hard edit rather
    /// than a crossfade.
    private static let tailFadeSeconds = 0.004

    init(engine: TransportEngine) { self.engine = engine }

    func launch(clip: Clip, on track: Track) {
        if engine.recordingSlot != nil { return }
        engine.selectTrack(track)
        if engine.mode == .stopped {
            let anchor = engine.startRolling()
            scheduleLaunch(clip: clip, on: track, boundary: 0, hostTime: anchor)
        } else {
            let boundary = engine.nextQuantizedBeat()
            scheduleLaunch(clip: clip, on: track, boundary: boundary,
                           hostTime: engine.hostTime(forBeat: boundary))
        }
    }

    func stopClip(on track: Track) {
        engine.selectTrack(track)
        guard engine.mode != .stopped,
              let state = engine.playback[track.id],
              state.playingClipID != nil || state.queuedClipID != nil else { return }
        scheduleStop(on: track, boundary: engine.nextQuantizedBeat())
    }

    func launchScene(_ scene: Int) {
        engine.selectScene(scene)
        if engine.recordingSlot != nil { return }
        let clips = engine.tracks.map { $0.slots[scene] }
        guard clips.contains(where: { $0 != nil }) || engine.mode != .stopped else { return }

        let boundary: Double
        let host: UInt64
        if engine.mode == .stopped {
            host = engine.startRolling()
            boundary = 0
        } else {
            boundary = engine.nextQuantizedBeat()
            host = engine.hostTime(forBeat: boundary)
        }

        for (track, clip) in zip(engine.tracks, clips) {
            if let clip {
                scheduleLaunch(clip: clip, on: track, boundary: boundary, hostTime: host)
            } else if let state = engine.playback[track.id],
                      state.playingClipID != nil || state.queuedClipID != nil {
                scheduleStop(on: track, boundary: boundary, hostTime: host)
            }
        }
    }

    func stopAllClips() {
        guard engine.mode != .stopped else { return }
        let boundary = engine.nextQuantizedBeat()
        let host = engine.hostTime(forBeat: boundary)
        for track in engine.tracks {
            if let state = engine.playback[track.id],
               state.playingClipID != nil || state.queuedClipID != nil {
                scheduleStop(on: track, boundary: boundary, hostTime: host)
            }
        }
    }

    /// Starts the rest of a scene playing underneath a take that is beginning
    /// from stopped — every clip in `scene` except the one being recorded into.
    ///
    /// They are anchored to the same `hostTime` as the recording's bar 1, so
    /// they come in exactly when the count-in ends and the take is captured
    /// against them. Without this, recording from a stopped transport gives you
    /// a count-in and then silence to play along to; whether you heard the rest
    /// of the scene depended entirely on having pressed play beforehand.
    func launchSceneUnderRecording(_ scene: Int, startingAt boundary: Double,
                                   hostTime: UInt64, excluding trackID: UUID) {
        for track in engine.tracks where track.id != trackID {
            guard scene < track.slots.count, let clip = track.slots[scene] else { continue }
            scheduleLaunch(clip: clip, on: track, boundary: boundary, hostTime: hostTime)
        }
    }

    private func scheduleLaunch(clip: Clip, on track: Track, boundary: Double, hostTime: UInt64) {
        guard let channel = engine.graph.channel(for: track.id) else { return }

        endSounding(on: channel, track: track, atBoundary: boundary, hostTime: hostTime)

        let idleIndex = 1 - channel.activeIndex
        let player = channel.players[idleIndex]
        player.stop()
        player.scheduleBuffer(clip.buffer, at: nil, options: [.loops])
        player.play(at: AVAudioTime(hostTime: hostTime))

        var state = engine.playback[track.id] ?? TrackPlayback()
        state.queuedClipID = clip.id
        state.stopQueued = false
        engine.playback[track.id] = state

        let trackID = track.id
        let clipID = clip.id
        channel.pendingTask?.cancel()
        channel.pendingTask = Task { [weak engine] in
            await engine?.sleep(untilBeat: boundary)
            guard let engine, !Task.isCancelled else { return }
            let outgoing = channel.players[channel.activeIndex]
            channel.activeIndex = idleIndex
            var state = engine.playback[trackID] ?? TrackPlayback()
            state.playingClipID = clipID
            state.playingStartBeat = boundary
            state.queuedClipID = nil
            engine.playback[trackID] = state
            // The outgoing player is part-way through its fade here. Its audio
            // has already been ended on the audio thread, so stopping it is
            // bookkeeping only — and has to wait for the fade to play out
            // rather than cutting it off and putting the click back.
            await Self.waitOutTailFade()
            guard !Task.isCancelled else { return }
            outgoing.stop()
        }
    }

    /// `hostTime` is passed in when several tracks share one boundary (a scene
    /// launch, stop-all) so every track's transition lands on the same instant
    /// rather than each recomputing it a few microseconds apart.
    private func scheduleStop(on track: Track, boundary: Double, hostTime: UInt64? = nil) {
        guard let channel = engine.graph.channel(for: track.id) else { return }

        endSounding(on: channel, track: track, atBoundary: boundary,
                    hostTime: hostTime ?? engine.hostTime(forBeat: boundary))

        var state = engine.playback[track.id] ?? TrackPlayback()
        state.stopQueued = true
        state.queuedClipID = nil
        engine.playback[track.id] = state

        let trackID = track.id
        channel.pendingTask?.cancel()
        channel.pendingTask = Task { [weak engine] in
            await engine?.sleep(untilBeat: boundary)
            guard let engine, !Task.isCancelled else { return }
            engine.playback[trackID] = TrackPlayback()
            // As above: the fade is already running on the audio thread, so
            // let it finish before tearing the players down.
            await Self.waitOutTailFade()
            guard !Task.isCancelled else { return }
            channel.stopAllPlayers()
        }
    }

    /// Waits out the boundary fade (with margin) before a player is stopped,
    /// so bookkeeping never truncates audio that is still sounding.
    private static func waitOutTailFade() async {
        try? await Task.sleep(nanoseconds: UInt64(tailFadeSeconds * 2 * 1_000_000_000))
    }

    /// Ends whatever is sounding on `track` exactly at `hostTime` — the launch
    /// or stop boundary — by handing the audio thread a short fade that
    /// interrupts the looping buffer at that instant.
    ///
    /// The incoming clip already starts sample-accurately via `play(at:)`, but
    /// the outgoing one used to run until a main-thread task happened to wake
    /// and call `stop()`: milliseconds of both clips at full level, ended by a
    /// click from cutting mid-waveform. Scheduling the ending instead takes the
    /// main thread out of the audio path — the pending task still does the
    /// bookkeeping, but it no longer has to be punctual to sound right.
    private func endSounding(on channel: TrackChannel, track: Track,
                             atBoundary boundary: Double, hostTime: UInt64) {
        let player = channel.players[channel.activeIndex]
        guard player.isPlaying,
              let state = engine.playback[track.id],
              let clipID = state.playingClipID,
              let clip = track.slots.compactMap({ $0 }).first(where: { $0.id == clipID }),
              let tail = fadeTail(for: clip, endingAtBeat: boundary,
                                  loopStartBeat: state.playingStartBeat)
        else { return }
        player.scheduleBuffer(tail, at: AVAudioTime(hostTime: hostTime), options: [.interrupts])
    }

    /// The outgoing clip's final few milliseconds: the audio it would have gone
    /// on to play at `beat`, faded to silence so the cut doesn't click.
    private func fadeTail(for clip: Clip, endingAtBeat beat: Double,
                          loopStartBeat: Double) -> AVAudioPCMBuffer? {
        let loopBeats = Double(clip.loopBars * engine.beatsPerBar)
        guard loopBeats > 0, engine.tempo > 0 else { return nil }
        let offsetBeats = BeatMath.loopOffsetBeats(atBeat: beat,
                                                   loopStartBeat: loopStartBeat,
                                                   loopBeats: loopBeats)
        let sampleRate = engine.standardFormat.sampleRate
        let offsetFrames = Int((offsetBeats * 60.0 / engine.tempo * sampleRate).rounded())
        return AudioUtil.fadeOutTail(clip.buffer, fromFrame: offsetFrames,
                                     frames: Int(Self.tailFadeSeconds * sampleRate))
    }

    /// Starts a clip immediately but phase-aligned as though it had launched at
    /// `loopStartBeat`: the first pass plays from the current in-loop offset,
    /// then the full buffer loops. Used to relaunch a just-finished take without
    /// a gap.
    func launchInProgress(clip: Clip, on track: Track, loopStartBeat: Double) {
        guard let channel = engine.graph.channel(for: track.id) else { return }
        let loopBeats = Double(clip.loopBars * engine.beatsPerBar)
        guard loopBeats > 0 else { return }
        let framesPerBeat = 60.0 / engine.tempo * engine.standardFormat.sampleRate
        let startDelay = 0.06
        let beatsAtStart = engine.currentBeats + startDelay * engine.tempo / 60
        let offsetBeats = BeatMath.loopOffsetBeats(atBeat: beatsAtStart,
                                                   loopStartBeat: loopStartBeat,
                                                   loopBeats: loopBeats)
        let clipFrames = Int(clip.buffer.frameLength)
        let offsetFrames = min(clipFrames, Int((offsetBeats * framesPerBeat).rounded()))

        let idleIndex = 1 - channel.activeIndex
        let player = channel.players[idleIndex]
        player.stop()
        if offsetFrames > 0, offsetFrames < clipFrames,
           let tail = AudioUtil.slice(clip.buffer, from: offsetFrames, frames: clipFrames - offsetFrames) {
            player.scheduleBuffer(tail, at: nil)
        }
        player.scheduleBuffer(clip.buffer, at: nil, options: [.loops])
        player.play(at: AVAudioTime(hostTime: HostClock.now + HostClock.ticks(forSeconds: startDelay)))

        channel.pendingTask?.cancel()
        channel.players[channel.activeIndex].stop()
        channel.activeIndex = idleIndex
        engine.playback[track.id] = TrackPlayback(playingClipID: clip.id,
                                                  playingStartBeat: loopStartBeat,
                                                  queuedClipID: nil, stopQueued: false)
    }
}
