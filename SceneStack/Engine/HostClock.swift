import Darwin

/// Conversions between mach host time (the timebase AVAudioTime and audio
/// render timestamps use) and seconds.
enum HostClock {
    static let secondsPerTick: Double = {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    static var now: UInt64 { mach_absolute_time() }

    static func ticks(forSeconds seconds: Double) -> UInt64 {
        UInt64(seconds / secondsPerTick)
    }

    static func seconds(fromTicks ticks: UInt64) -> Double {
        Double(ticks) * secondsPerTick
    }
}
