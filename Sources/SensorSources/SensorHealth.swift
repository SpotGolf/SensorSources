import Foundation

/// Whether a batch is real sensor data rather than the zeros, NaNs or silence a broken sensor
/// sends. A batch that is not real should be treated like no data at all.
public enum SensorHealth {
    /// Every value is finite, and at least one reading's magnitude is in `accelerometerRange`:
    /// gravity alone is 1 g, so a working accelerometer never reads near zero for a whole batch.
    public static func isReal(_ batch: [AccelerometerSample]) -> Bool {
        guard !batch.isEmpty, batch.allSatisfy({ $0.timestamp.isFinite && $0.acceleration.isFinite }) else { return false }
        return batch.contains { accelerometerRange.contains($0.acceleration.magnitude) }
    }

    /// Every value is finite, and gravity's magnitude is in `gravityRange` for every reading.
    public static func isReal(_ batch: [DeviceMotionSample]) -> Bool {
        guard !batch.isEmpty else { return false }
        return batch.allSatisfy { sample in
            sample.timestamp.isFinite && sample.rotationRate.isFinite && sample.userAcceleration.isFinite
                && sample.gravity.isFinite && sample.attitude.isFinite && gravityRange.contains(sample.gravity.magnitude)
        }
    }

    /// Every buffer has frames and only finite samples, and not every sample is exactly zero:
    /// a working microphone always picks up some noise.
    public static func isReal(_ batch: [AudioSample]) -> Bool {
        guard !batch.isEmpty, batch.allSatisfy({ !$0.samples.isEmpty && $0.sampleRate > 0 && $0.hostTime.isFinite }) else {
            return false
        }
        var heard = false
        for buffer in batch {
            for sample in buffer.samples {
                guard sample.isFinite else { return false }
                if sample != 0 { heard = true }
            }
        }
        return heard
    }

    public static let accelerometerRange: ClosedRange<Double> = 0.5...4
    public static let gravityRange: ClosedRange<Double> = 0.8...1.2
}
