import Foundation

/// Three values along the device's x, y and z axes.
public struct Vector3: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(x: 0, y: 0, z: 0)

    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }

    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

/// A rotation as a unit quaternion.
public struct Quaternion: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)

    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
}

/// One accelerometer reading. `timestamp` is seconds of system uptime, the clock Core Motion uses.
public struct AccelerometerSample: Sendable, Equatable {
    public var timestamp: TimeInterval
    /// In g, gravity included.
    public var acceleration: Vector3

    public init(timestamp: TimeInterval, acceleration: Vector3) {
        self.timestamp = timestamp
        self.acceleration = acceleration
    }
}

/// One device motion reading. `timestamp` is seconds of system uptime.
public struct DeviceMotionSample: Sendable, Equatable {
    public var timestamp: TimeInterval
    /// Radians a second.
    public var rotationRate: Vector3
    /// In g, gravity removed.
    public var userAcceleration: Vector3
    /// In g.
    public var gravity: Vector3
    public var attitude: Quaternion

    public init(timestamp: TimeInterval, rotationRate: Vector3, userAcceleration: Vector3, gravity: Vector3,
                attitude: Quaternion) {
        self.timestamp = timestamp
        self.rotationRate = rotationRate
        self.userAcceleration = userAcceleration
        self.gravity = gravity
        self.attitude = attitude
    }
}

/// One buffer from the microphone, mono. `hostTime` is the host time of its first frame in
/// seconds, the same clock as system uptime.
public struct AudioSample: Sendable, Equatable {
    public var hostTime: TimeInterval
    public var sampleRate: Double
    /// Full-scale units, -1 to 1.
    public var samples: [Float]

    public init(hostTime: TimeInterval, sampleRate: Double, samples: [Float]) {
        self.hostTime = hostTime
        self.sampleRate = sampleRate
        self.samples = samples
    }
}
