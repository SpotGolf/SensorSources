import Foundation

/// Makes up readings for one mock sensor: a batch for each tick, covering the time since the
/// last one. Called on the mock's timer queue.
final class MockStream<Sample: Sendable>: @unchecked Sendable {
    typealias Generate = @Sendable (_ from: TimeInterval, _ to: TimeInterval, _ mode: MockMode, _ clips: [PlayingClip]) -> [Sample]

    private let lock = NSLock()
    private let hub: MockSensorHub
    private let sensor: MockSensorHub.Sensor
    private let generate: Generate
    private var last: TimeInterval

    init(hub: MockSensorHub, sensor: MockSensorHub.Sensor, start: TimeInterval, generate: @escaping Generate) {
        self.hub = hub
        self.sensor = sensor
        self.generate = generate
        last = start
    }

    /// The batch for the time since the last tick, or nil when the mode sends nothing.
    func tick(at now: TimeInterval) -> [Sample]? {
        lock.lock()
        let from = last
        last = now
        lock.unlock()
        let mode = hub.mode(of: sensor)
        guard mode == .ok || mode == .zeros else { return nil }
        let batch = generate(from, now, mode, hub.playing(from: from, to: now))
        return batch.isEmpty ? nil : batch
    }
}

/// The parts the three mocks share: a timer on its own queue that ticks while started.
@MainActor
public class MockSource<Sample: Sendable> {
    let hub: MockSensorHub
    let sensor: MockSensorHub.Sensor
    private let interval: TimeInterval
    private var timer: DispatchSourceTimer?

    init(hub: MockSensorHub, sensor: MockSensorHub.Sensor, interval: TimeInterval) {
        self.hub = hub
        self.sensor = sensor
        self.interval = interval
    }

    public var isSupported: Bool { true }

    public var isActive: Bool { timer != nil && hub.mode(of: sensor) != .fail }

    public func start(onSamples: @escaping @Sendable ([Sample]) -> Void, onError: @escaping @Sendable (Error) -> Void) throws {
        stop()
        hub.retain()
        guard hub.mode(of: sensor) != .fail else {
            hub.release()
            throw SensorSourceError.mockFailure
        }
        let now = ProcessInfo.processInfo.systemUptime
        let stream = MockStream<Sample>(hub: hub, sensor: sensor, start: now, generate: makeGenerator())
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "SensorSources.\(sensor.rawValue)"))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        // The timer's queue calls this, so @Sendable: a plain closure made here would count as
        // main-actor code, and Swift 6 traps when it runs anywhere else
        timer.setEventHandler { @Sendable in
            guard let batch = stream.tick(at: ProcessInfo.processInfo.systemUptime) else { return }
            onSamples(batch)
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        guard let timer else { return }
        timer.cancel()
        self.timer = nil
        hub.release()
    }

    /// Each mock's readings, as a closure the timer queue can call.
    func makeGenerator() -> MockStream<Sample>.Generate {
        fatalError("Each mock generates its own samples")
    }
}

/// An accelerometer at rest at the live rate, 800 Hz on a watch and 100 Hz on a phone, a batch
/// a second, with any clip's readings in place of it.
public final class MockAccelerometer: MockSource<AccelerometerSample>, AccelerometerSource {
    #if os(watchOS)
    public nonisolated static let rate: Double = 800
    #else
    public nonisolated static let rate: Double = PhoneAccelerometer.rate
    #endif

    public init(hub: MockSensorHub = .shared) {
        super.init(hub: hub, sensor: .accelerometer, interval: 1)
    }

    override func makeGenerator() -> MockStream<AccelerometerSample>.Generate {
        { @Sendable from, to, mode, clips in Self.samples(from: from, to: to, mode: mode, clips: clips) }
    }

    nonisolated static func samples(from: TimeInterval, to: TimeInterval, mode: MockMode, clips: [PlayingClip]) -> [AccelerometerSample] {
        let recorded = clips.flatMap { playing in
            playing.clip.accelerometer.map { AccelerometerSample(timestamp: playing.start + $0.timestamp, acceleration: $0.acceleration) }
        }
        let clipSpans = clips.compactMap { playing in
            playing.clip.accelerometer.isEmpty ? nil : playing.start...(playing.start + playing.clip.accelerometerDuration)
        }
        var batch = baseline(from: from, to: to, rate: rate, skipping: clipSpans) { time in
            AccelerometerSample(timestamp: time, acceleration: Vector3(x: noise(0.01), y: noise(0.01), z: -1 + noise(0.01)))
        }
        batch += recorded.filter { $0.timestamp >= from && $0.timestamp < to }
        batch.sort { $0.timestamp < $1.timestamp }
        guard mode == .zeros else { return batch }
        return batch.map { AccelerometerSample(timestamp: $0.timestamp, acceleration: .zero) }
    }
}

/// Device motion at rest at the live rate, 200 Hz on a watch and 100 Hz on a phone, a batch a
/// second, with any clip's readings in place of it.
public final class MockDeviceMotion: MockSource<DeviceMotionSample>, DeviceMotionSource {
    #if os(watchOS)
    public nonisolated static let rate: Double = 200
    #else
    public nonisolated static let rate: Double = PhoneDeviceMotion.rate
    #endif

    public init(hub: MockSensorHub = .shared) {
        super.init(hub: hub, sensor: .deviceMotion, interval: 1)
    }

    override func makeGenerator() -> MockStream<DeviceMotionSample>.Generate {
        { @Sendable from, to, mode, clips in Self.samples(from: from, to: to, mode: mode, clips: clips) }
    }

    nonisolated static func samples(from: TimeInterval, to: TimeInterval, mode: MockMode, clips: [PlayingClip]) -> [DeviceMotionSample] {
        let recorded: [DeviceMotionSample] = clips.flatMap { playing in
            playing.clip.deviceMotion.map { sample -> DeviceMotionSample in
                var moved = sample
                moved.timestamp += playing.start
                return moved
            }
        }
        let clipSpans = clips.compactMap { playing in
            playing.clip.deviceMotion.isEmpty ? nil : playing.start...(playing.start + playing.clip.deviceMotionDuration)
        }
        var batch = baseline(from: from, to: to, rate: rate, skipping: clipSpans) { time in
            DeviceMotionSample(timestamp: time, rotationRate: Vector3(x: noise(0.01), y: noise(0.01), z: noise(0.01)),
                               userAcceleration: Vector3(x: noise(0.005), y: noise(0.005), z: noise(0.005)),
                               gravity: Vector3(x: 0, y: 0, z: -1), attitude: .identity)
        }
        batch += recorded.filter { $0.timestamp >= from && $0.timestamp < to }
        batch.sort { $0.timestamp < $1.timestamp }
        guard mode == .zeros else { return batch }
        return batch.map { sample -> DeviceMotionSample in
            DeviceMotionSample(timestamp: sample.timestamp, rotationRate: .zero, userAcceleration: .zero, gravity: .zero,
                               attitude: Quaternion(x: 0, y: 0, z: 0, w: 0))
        }
    }
}

/// A quiet microphone, 48 kHz, 4096-frame buffers, with any clip's audio in place of the noise.
public final class MockMicrophone: MockSource<AudioSample>, MicrophoneSource {
    public nonisolated static let bufferFrames = 4096

    public init(hub: MockSensorHub = .shared) {
        super.init(hub: hub, sensor: .microphone, interval: Double(Self.bufferFrames) / MockSensorHub.audioSampleRate)
    }

    override func makeGenerator() -> MockStream<AudioSample>.Generate {
        { @Sendable from, to, mode, clips in Self.samples(from: from, to: to, mode: mode, clips: clips) }
    }

    /// Whole buffers from `from`; the frames past `to` go in the next tick's first buffer, as a
    /// real microphone's do.
    nonisolated static func samples(from: TimeInterval, to: TimeInterval, mode: MockMode, clips: [PlayingClip]) -> [AudioSample] {
        let rate = MockSensorHub.audioSampleRate
        let count = max(1, Int(((to - from) * rate / Double(bufferFrames)).rounded()))
        return (0..<count).map { index in
            let start = from + Double(index * bufferFrames) / rate
            var samples = [Float](repeating: 0, count: bufferFrames)
            if mode == .ok {
                for frame in 0..<bufferFrames {
                    samples[frame] = Float(noise(0.001))
                }
                for clip in clips where !clip.clip.audio.isEmpty {
                    let offset = Int(((start - clip.start) * rate).rounded())
                    for frame in 0..<bufferFrames where clip.clip.audio.indices.contains(offset + frame) {
                        samples[frame] = clip.clip.audio[offset + frame]
                    }
                }
            }
            return AudioSample(hostTime: start, sampleRate: rate, samples: samples)
        }
    }
}

/// Readings at `rate` from `from` up to `to`, aligned to the rate, leaving out the clips' spans.
private func baseline<Sample>(from: TimeInterval, to: TimeInterval, rate: Double, skipping spans: [ClosedRange<TimeInterval>],
                              make: (TimeInterval) -> Sample) -> [Sample] {
    var batch: [Sample] = []
    var index = (from * rate).rounded(.up)
    while index / rate < to {
        let time = index / rate
        if !spans.contains(where: { $0.contains(time) }) {
            batch.append(make(time))
        }
        index += 1
    }
    return batch
}

private func noise(_ amount: Double) -> Double {
    Double.random(in: -amount...amount)
}
