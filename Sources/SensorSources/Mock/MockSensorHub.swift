import AVFAudio
import Foundation

/// The mocks' shared state: what each mock is told to do, and the clips to play. While any mock
/// runs, the hub looks in `inbox` every `pollInterval` for new clips (`<name>.clip/`) and for
/// `control.json`. Tests and apps can also set both directly.
///
/// A clip folder holds any of `accelerometer.csv` (`t,x,y,z`), `motion.csv`
/// (`t,rx,ry,rz,ux,uy,uz,gx,gy,gz,qx,qy,qz,qw`) and `audio.wav` (mono, 48 kHz), with `t` in
/// seconds from the clip's start, and its folder is deleted once read. A clip plays once from
/// when it is picked up, or from `startAt` in an optional `clip.json` (seconds since 1970), so
/// a writer can send clips ahead of time and have them start exactly on time. While a clip
/// plays, its readings take the place of the baseline for the sensors it has. Clips that
/// overlap both play; where both have audio, the later one's is heard.
///
/// `control.json` maps a sensor's name (`accelerometer`, `deviceMotion`, `microphone`) to a
/// `MockMode` name, and stays in force until it changes. Names starting with "." are ignored,
/// so a writer can copy to a hidden name and rename.
public final class MockSensorHub: @unchecked Sendable {
    public enum Sensor: String, Sendable, CaseIterable {
        case accelerometer
        case deviceMotion
        case microphone
    }

    /// The process's hub, reading `Library/SensorMock/Inbox` in the app's data container.
    public static let shared = MockSensorHub(inbox: defaultInbox)

    public static var defaultInbox: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SensorMock/Inbox", isDirectory: true)
    }

    public static let pollInterval: TimeInterval = 0.5
    /// The only clip audio rate the mock microphone plays.
    public static let audioSampleRate: Double = 48_000

    public let inbox: URL?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "SensorSources.MockSensorHub")
    private var modes: [Sensor: MockMode] = [:]
    /// Modes set in code, which `control.json` does not override.
    private var codeModes: [Sensor: MockMode] = [:]
    /// Clips still to play or playing, in start order.
    private var clips: [PlayingClip] = []
    private var users = 0
    private var timer: DispatchSourceTimer?

    /// With no `inbox`, only clips and modes set in code are used.
    public init(inbox: URL?) {
        self.inbox = inbox
    }

    // MARK: - Setting from code

    public func mode(of sensor: Sensor) -> MockMode {
        lock.withLock { codeModes[sensor] ?? modes[sensor] ?? .ok }
    }

    /// Sets a sensor's mode until it is set again, whatever `control.json` says.
    public func setMode(_ mode: MockMode?, for sensor: Sensor) {
        lock.withLock { codeModes[sensor] = mode }
    }

    /// Plays `clip` from `uptime`: its `startAt` if it has one, now otherwise.
    public func play(_ clip: MockClip, at uptime: TimeInterval? = nil) {
        let start = uptime ?? clip.startAt.map(Self.uptime(at:)) ?? ProcessInfo.processInfo.systemUptime
        lock.withLock {
            clips.append(PlayingClip(clip: clip, start: start))
            clips.sort { $0.start < $1.start }
        }
    }

    /// The clips with any part from `from` up to `to`, in start order. Clips over before
    /// `from` are dropped.
    func playing(from: TimeInterval, to: TimeInterval) -> [PlayingClip] {
        lock.withLock {
            clips.removeAll { $0.start + $0.clip.duration + 1 < from }
            return clips.filter { $0.start < to }
        }
    }

    /// The system uptime at `date`, by the wall clock now.
    static func uptime(at date: Date) -> TimeInterval {
        ProcessInfo.processInfo.systemUptime + date.timeIntervalSinceNow
    }

    // MARK: - Polling the inbox

    /// A mock started: the inbox is read now, and then every `pollInterval` while any mock runs.
    func retain() {
        poll()
        lock.withLock {
            users += 1
            guard timer == nil, inbox != nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func release() {
        lock.withLock {
            users = max(0, users - 1)
            guard users == 0 else { return }
            timer?.cancel()
            timer = nil
        }
    }

    /// Reads `control.json` and picks up the newest clip.
    func poll() {
        guard let inbox else { return }
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: inbox.path) else { return }
        let control = inbox.appendingPathComponent("control.json")
        if names.contains("control.json"), let data = try? Data(contentsOf: control),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            var read: [Sensor: MockMode] = [:]
            for (name, value) in object {
                guard let sensor = Sensor(rawValue: name), let mode = MockMode(rawValue: value) else { continue }
                read[sensor] = mode
            }
            lock.withLock { modes = read }
        } else if !names.contains("control.json") {
            lock.withLock { modes = [:] }
        }
        for name in names.sorted() where name.hasSuffix(".clip") && !name.hasPrefix(".") {
            let folder = inbox.appendingPathComponent(name, isDirectory: true)
            do {
                play(try MockClip(folder: folder))
            } catch {
                NSLog("SensorSources: could not read the clip %@: %@", name, String(describing: error))
            }
            try? manager.removeItem(at: folder)
        }
    }
}

/// What a mock does while started.
public enum MockMode: String, Sendable {
    /// Sends the baseline and any clip.
    case ok
    /// `start` throws, and a running mock stops sending and is no longer active.
    case fail
    /// Starts and stays active, but sends nothing.
    case silent
    /// Sends readings of all zeros, which `SensorHealth` does not count as real.
    case zeros
}

/// Recorded readings for any of the three sensors, with times in seconds from the clip's start.
public struct MockClip: Sendable {
    public var accelerometer: [AccelerometerSample]
    public var deviceMotion: [DeviceMotionSample]
    /// Mono, at `MockSensorHub.audioSampleRate`.
    public var audio: [Float]
    /// When the clip starts, by the wall clock; nil to start when it is played.
    public var startAt: Date?

    public init(accelerometer: [AccelerometerSample] = [], deviceMotion: [DeviceMotionSample] = [], audio: [Float] = [],
                startAt: Date? = nil) {
        self.accelerometer = accelerometer.sorted { $0.timestamp < $1.timestamp }
        self.deviceMotion = deviceMotion.sorted { $0.timestamp < $1.timestamp }
        self.audio = audio
        self.startAt = startAt
    }

    public var accelerometerDuration: TimeInterval { accelerometer.last?.timestamp ?? 0 }
    public var deviceMotionDuration: TimeInterval { deviceMotion.last?.timestamp ?? 0 }
    public var audioDuration: TimeInterval { Double(audio.count) / MockSensorHub.audioSampleRate }
    public var duration: TimeInterval { max(accelerometerDuration, deviceMotionDuration, audioDuration) }

    public enum ReadError: Error {
        case badLine(file: String, line: Int)
        case audioRate(Double)
    }

    /// Reads a clip folder.
    public init(folder: URL) throws {
        let manager = FileManager.default
        var accelerometer: [AccelerometerSample] = []
        var deviceMotion: [DeviceMotionSample] = []
        var audio: [Float] = []
        let accelURL = folder.appendingPathComponent("accelerometer.csv")
        if manager.fileExists(atPath: accelURL.path) {
            accelerometer = try Self.rows(accelURL, columns: 4).map { v in
                AccelerometerSample(timestamp: v[0], acceleration: Vector3(x: v[1], y: v[2], z: v[3]))
            }
        }
        let motionURL = folder.appendingPathComponent("motion.csv")
        if manager.fileExists(atPath: motionURL.path) {
            deviceMotion = try Self.rows(motionURL, columns: 14).map { v in
                DeviceMotionSample(timestamp: v[0], rotationRate: Vector3(x: v[1], y: v[2], z: v[3]),
                                   userAcceleration: Vector3(x: v[4], y: v[5], z: v[6]),
                                   gravity: Vector3(x: v[7], y: v[8], z: v[9]),
                                   attitude: Quaternion(x: v[10], y: v[11], z: v[12], w: v[13]))
            }
        }
        let audioURL = folder.appendingPathComponent("audio.wav")
        if manager.fileExists(atPath: audioURL.path) {
            audio = try Self.readAudio(audioURL)
        }
        var startAt: Date?
        if let data = try? Data(contentsOf: folder.appendingPathComponent("clip.json")),
           let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let seconds = object["startAt"] as? Double {
            startAt = Date(timeIntervalSince1970: seconds)
        }
        self.init(accelerometer: accelerometer, deviceMotion: deviceMotion, audio: audio, startAt: startAt)
    }

    /// The numeric rows of a CSV file, skipping a header line.
    static func rows(_ url: URL, columns: Int) throws -> [[Double]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [[Double]] = []
        for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            let fields = line.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            if index == 0, fields.first.flatMap({ $0 }) == nil { continue }
            let values = fields.compactMap { $0 }
            guard values.count == columns, fields.count == columns else {
                throw ReadError.badLine(file: url.lastPathComponent, line: index + 1)
            }
            rows.append(values)
        }
        return rows
    }

    static func readAudio(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == MockSensorHub.audioSampleRate else { throw ReadError.audioRate(format.sampleRate) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

/// A clip and the uptime it started playing.
struct PlayingClip: Sendable {
    let clip: MockClip
    let start: TimeInterval
}
