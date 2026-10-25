import AVFAudio
import Foundation

/// The microphone through `AVAudioEngine`: each 4096-frame buffer of the first channel, as an
/// `AudioSample`. Starts itself again after an audio interruption or a configuration change,
/// which otherwise leave the engine stopped for good.
///
/// Each start uses a new engine: one kept from an earlier start can hold an input format that
/// is no longer valid, and then every start fails with -10868 ("Input HW format is invalid")
/// until the app quits.
@MainActor
public final class LiveMicrophone: MicrophoneSource {
    private var engine: AVAudioEngine?
    private var onSamples: (@Sendable ([AudioSample]) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?
    private var sessionObservers: [NotificationCenter.ObservationToken] = []
    private var configurationObserver: NSObjectProtocol?

    public private(set) var isActive = false

    public init() {}

    public var isSupported: Bool { true }

    public func start(onSamples: @escaping @Sendable ([AudioSample]) -> Void,
                      onError: @escaping @Sendable (Error) -> Void) throws {
        guard !isActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement)
        } catch {
            SensorLog.error("Measurement mode refused; using the default mode: \(String(describing: error))")
            try session.setCategory(.record)
        }
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let hardware = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, hardware.sampleRate > 0, hardware.channelCount > 0 else {
            deactivate(session)
            throw SensorSourceError.noInput
        }
        let sampleRate = format.sampleRate
        do {
            // The audio thread calls this, so @Sendable: a plain closure made here would count as
            // main-actor code, and Swift 6 traps when it runs anywhere else
            try input.installAudioTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, when in
                onSamples([AudioSample(hostTime: AVAudioTime.seconds(forHostTime: when.hostTime), sampleRate: sampleRate,
                                       samples: Self.samples(buffer))])
            }
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            deactivate(session)
            throw error
        }
        self.engine = engine
        self.onSamples = onSamples
        self.onError = onError
        isActive = true
        observe()
        SensorLog.notice("Microphone started: \(format.sampleRate) Hz, \(format.channelCount) channel(s)")
    }

    public func stop() {
        guard isActive else { return }
        isActive = false
        let center = NotificationCenter.default
        for observer in sessionObservers {
            center.removeObserver(observer)
        }
        sessionObservers = []
        if let configurationObserver {
            center.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        deactivate(AVAudioSession.sharedInstance())
        SensorLog.notice("Microphone stopped")
    }

    /// The first channel of a buffer, in full-scale units.
    nonisolated static func samples(_ buffer: AVReadOnlyAudioPCMBuffer) -> [Float] {
        guard case .float(let channel) = buffer.channelData(0) else { return [] }
        return (0..<channel.count).map { channel[$0] }
    }

    private func deactivate(_ session: AVAudioSession) {
        do {
            try session.setActive(false)
        } catch {
            SensorLog.error("Could not deactivate the audio session: \(String(describing: error))")
        }
    }

    /// An interruption, or a changed input, stops the engine; it is started again with the
    /// input's current format once the interruption is over or the input has changed.
    private func observe() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        sessionObservers.append(center.addObserver(of: session, for: .didBecomeInactive) { message in
            // `stop()` deactivating the session is reported too; only the system's matters
            guard case .systemInterruption(let context) = message.deactivationResult else { return }
            SensorLog.notice("Microphone interrupted: reason \(context.reason.rawValue)")
        })
        // Restarted whatever the recommendation: the mic records sensor data, not playback
        sessionObservers.append(center.addObserver(of: session, for: .resumptionRecommendation) { [weak self] _ in
            self?.restart(reason: "the interruption ended")
        })
        configurationObserver = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.restart(reason: "the audio configuration changed") }
        }
    }

    /// Starts again on a new engine after the old one was stopped from outside.
    private func restart(reason: String) {
        guard isActive, let onSamples, let onError else { return }
        SensorLog.notice("Microphone restarting: \(reason)")
        stop()
        do {
            try start(onSamples: onSamples, onError: onError)
        } catch {
            SensorLog.error("Microphone did not restart: \(String(describing: error))")
            onError(error)
        }
    }
}
