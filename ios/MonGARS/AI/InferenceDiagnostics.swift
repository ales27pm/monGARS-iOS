import Foundation
import os

actor InferenceDiagnostics {
    private let logger = Logger(subsystem: "com.mongars.ai", category: "inference")
    private var snapshots: [InferenceSnapshot] = []
    private let maxSnapshots = 100

    func recordSnapshot(_ snapshot: InferenceSnapshot) {
        snapshots.append(snapshot)
        if snapshots.count > maxSnapshots {
            snapshots.removeFirst(snapshots.count - maxSnapshots)
        }
        logger.info(
            "Generation: \(snapshot.tokensGenerated) tokens in \(String(format: "%.2f", snapshot.elapsedSeconds))s (\(String(format: "%.1f", snapshot.tokensPerSecond)) tok/s) variant=\(snapshot.variant.rawValue) thermal=\(Self.thermalLabel(snapshot.thermalState))"
        )
    }

    func recordModelLoad(variant: ModelVariant, durationSeconds: Double, success: Bool) {
        if success {
            logger.info("Model loaded: \(variant.rawValue) in \(String(format: "%.2f", durationSeconds))s")
        } else {
            logger.error("Model load failed: \(variant.rawValue) after \(String(format: "%.2f", durationSeconds))s")
        }
    }

    func recordWarmup(variant: ModelVariant, durationSeconds: Double) {
        logger.info("Warmup completed: \(variant.rawValue) in \(String(format: "%.2f", durationSeconds))s")
    }

    func recordMemoryPressure(bytesUsed: UInt64, thermal: ProcessInfo.ThermalState) {
        logger.warning("Memory pressure: \(bytesUsed / 1_048_576)MB used, thermal=\(Self.thermalLabel(thermal))")
    }

    func recordError(_ message: String, variant: ModelVariant?) {
        let v = variant?.rawValue ?? "unknown"
        logger.error("Inference error [\(v)]: \(message)")
    }

    var recentSnapshots: [InferenceSnapshot] {
        snapshots
    }

    var averageTokensPerSecond: Double {
        let valid = snapshots.filter { $0.tokensPerSecond > 0 }
        guard !valid.isEmpty else { return 0 }
        return valid.map(\.tokensPerSecond).reduce(0, +) / Double(valid.count)
    }

    func reset() {
        snapshots.removeAll()
    }

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
