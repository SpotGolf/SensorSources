import CoreMotion
import Foundation

/// The accelerometer through `CMMotionManager`, for a phone, which has no batched sensors:
/// 100 Hz, gathered into a batch about once a second, like the watch's batched accelerometer.
@MainActor
public final class PhoneAccelerometer: AccelerometerSource {
    public nonisolated static let rate: Double = 100

    private var queue: OperationQueue?

    public init() {}

    public var isSupported: Bool { PhoneMotion.manager.isAccelerometerAvailable }

    public var isActive: Bool { queue != nil && PhoneMotion.manager.isAccelerometerActive }

    public func start(onSamples: @escaping @Sendable ([AccelerometerSample]) -> Void,
                      onError: @escaping @Sendable (Error) -> Void) throws {
        guard isSupported else { throw SensorSourceError.unsupported }
        stop()
        let manager = PhoneMotion.manager
        let queue = PhoneMotion.queue(for: "accelerometer")
        let batch = MotionBatch<AccelerometerSample>()
        self.queue = queue
        manager.accelerometerUpdateInterval = 1 / Self.rate
        // Core Motion calls this on `queue`, so @Sendable: a plain closure made here would count
        // as main-actor code, and Swift 6 traps when it runs anywhere else
        manager.startAccelerometerUpdates(to: queue) { @Sendable data, error in
            if let error { onError(error) }
            guard let data else { return }
            let a = data.acceleration
            let sample = AccelerometerSample(timestamp: data.timestamp, acceleration: Vector3(x: a.x, y: a.y, z: a.z))
            if let full = batch.add(sample, at: data.timestamp) { onSamples(full) }
        }
    }

    public func stop() {
        guard queue != nil else { return }
        PhoneMotion.manager.stopAccelerometerUpdates()
        queue = nil
    }
}

/// Device motion through `CMMotionManager`, for a phone: 100 Hz rotation rate, user
/// acceleration, gravity and attitude, gathered into a batch about once a second.
@MainActor
public final class PhoneDeviceMotion: DeviceMotionSource {
    public nonisolated static let rate: Double = 100

    private var queue: OperationQueue?

    public init() {}

    public var isSupported: Bool { PhoneMotion.manager.isDeviceMotionAvailable }

    public var isActive: Bool { queue != nil && PhoneMotion.manager.isDeviceMotionActive }

    public func start(onSamples: @escaping @Sendable ([DeviceMotionSample]) -> Void,
                      onError: @escaping @Sendable (Error) -> Void) throws {
        guard isSupported else { throw SensorSourceError.unsupported }
        stop()
        let manager = PhoneMotion.manager
        let queue = PhoneMotion.queue(for: "deviceMotion")
        let batch = MotionBatch<DeviceMotionSample>()
        self.queue = queue
        manager.deviceMotionUpdateInterval = 1 / Self.rate
        manager.startDeviceMotionUpdates(to: queue) { @Sendable motion, error in
            if let error { onError(error) }
            guard let motion else { return }
            let r = motion.rotationRate, u = motion.userAcceleration, g = motion.gravity, q = motion.attitude.quaternion
            let sample = DeviceMotionSample(timestamp: motion.timestamp,
                                            rotationRate: Vector3(x: r.x, y: r.y, z: r.z),
                                            userAcceleration: Vector3(x: u.x, y: u.y, z: u.z),
                                            gravity: Vector3(x: g.x, y: g.y, z: g.z),
                                            attitude: Quaternion(x: q.x, y: q.y, z: q.z, w: q.w))
            if let full = batch.add(sample, at: motion.timestamp) { onSamples(full) }
        }
    }

    public func stop() {
        guard queue != nil else { return }
        PhoneMotion.manager.stopDeviceMotionUpdates()
        queue = nil
    }
}

/// The one motion manager the phone sources share: Apple asks for a single one per app, since
/// more than one can slow the rate readings arrive at.
@MainActor
enum PhoneMotion {
    static let manager = CMMotionManager()

    /// A serial queue, so a source's readings arrive in order and one at a time.
    static func queue(for sensor: String) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "SensorSources.\(sensor)"
        queue.maxConcurrentOperationCount = 1
        return queue
    }
}

/// Readings gathered until they span `interval` seconds, then handed out as one batch.
final class MotionBatch<Sample: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var samples: [Sample] = []
    private var first: TimeInterval?

    init(interval: TimeInterval = 1) {
        self.interval = interval
    }

    /// Adds a reading taken at `time`. Returns the batch once it spans `interval`, nil otherwise.
    func add(_ sample: Sample, at time: TimeInterval) -> [Sample]? {
        lock.withLock {
            samples.append(sample)
            let start = first ?? time
            first = start
            guard time - start >= interval else { return nil }
            defer {
                samples = []
                first = nil
            }
            return samples
        }
    }
}
