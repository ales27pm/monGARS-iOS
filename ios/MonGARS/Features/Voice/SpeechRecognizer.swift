import AVFoundation
import Foundation
import Speech

@Observable
@MainActor
final class SpeechRecognizer {
    var transcribedText: String = ""
    var isListening: Bool = false
    var errorMessage: String?
    var audioLevel: Float = 0

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    var hasRequiredPermissions: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVAudioApplication.shared.recordPermission == .granted
    }

    func requestPermissions() async -> Bool {
        let micGranted = await AVAudioApplication.requestRecordPermission()
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return micGranted && speechStatus == .authorized
    }

    func startListening(language: AppLanguage) {
        guard !isListening else { return }

        guard hasRequiredPermissions else {
            errorMessage = language == .frenchCA
                ? "Permissions vocales requises. Activez-les dans les Réglages."
                : "Voice permissions required. Enable them in Settings."
            return
        }

        let locale = Locale(identifier: language.speechLocaleIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            errorMessage = language == .frenchCA
                ? "Reconnaissance vocale non disponible pour \(language.displayName)"
                : "Speech recognition unavailable for \(language.displayName)"
            return
        }

        transcribedText = ""
        errorMessage = nil
        audioLevel = 0

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        if language == .frenchCA {
            request.contextualStrings = ["monGARS", "Québec", "Montréal", "Ottawa", "Canada"]
        } else {
            request.contextualStrings = ["monGARS", "Quebec", "Montreal", "Ottawa", "Canada"]
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = language == .frenchCA
                ? "Erreur audio : \(error.localizedDescription)"
                : "Audio session error: \(error.localizedDescription)"
            return
        }

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            request.append(buffer)
            let level = self?.calculateAudioLevel(buffer: buffer) ?? 0
            Task { @MainActor [weak self] in
                self?.audioLevel = level
            }
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let result {
                    self.transcribedText = result.bestTranscription.formattedString
                }

                if error != nil || (result?.isFinal == true) {
                    self.stopListeningInternal()
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            self.audioEngine = engine
            self.recognitionRequest = request
            self.isListening = true
        } catch {
            errorMessage = language == .frenchCA
                ? "Erreur du moteur audio : \(error.localizedDescription)"
                : "Audio engine error: \(error.localizedDescription)"
            stopListeningInternal()
        }
    }

    func stopListening() {
        stopListeningInternal()
    }

    private func stopListeningInternal() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        audioLevel = 0
    }

    nonisolated private func calculateAudioLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelDataValue = channelData.pointee
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channelDataValue[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))
        let db = 20 * log10(max(rms, 1e-6))
        let normalized = max(0, min(1, (db + 50) / 50))
        return normalized
    }
}
