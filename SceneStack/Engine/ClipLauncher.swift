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
                scheduleStop(on: track, boundary: boundary)
            }
        }
    }

    func stopAllClips() {
        guard engine.mode != .stopped else { return }
        let boundary = engine.nextQuantizedBeat()
        for track in engine.tracks {
            if let state = engine.playback[track.id],
               state.playingClipID != nil || state.queuedClipID != nil {
                scheduleStop(on: track, boundary: boundary)
            }
        }
    }

    private func scheduleLaunch(clip: Clip, on track: Track, boundary: Double, hostTime: UInt64) {
        guard let channel = engine.graph.channel(for: track.id) else { return }

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
            channel.players[channel.activeIndex].stop()
            channel.activeIndex = idleIndex
            var state = engine.playback[trackID] ?? TrackPlayback()
            state.playingClipID = clipID
            state.playingStartBeat = boundary
            state.queuedClipID = nil
            engine.playback[trackID] = state
        }
    }

    private func scheduleStop(on track: Track, boundary: Double) {
        guard let channel = engine.graph.channel(for: track.id) else { return }
        var state = engine.playback[track.id] ?? TrackPlayback()
        state.stopQueued = true
        state.queuedClipID = nil
        engine.playback[track.id] = state

        let trackID = track.id
        channel.pendingTask?.cancel()
        channel.pendingTask = Task { [weak engine] in
            await engine?.sleep(untilBeat: boundary)
            guard let engine, !Task.isCancelled else { return }
            channel.stopAllPlayers()
            engine.playback[trackID] = TrackPlayback()
        }
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
        var offsetBeats = (beatsAtStart - loopStartBeat).truncatingRemainder(dividingBy: loopBeats)
        if offsetBeats < 0 { offsetBeats += loopBeats }
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
