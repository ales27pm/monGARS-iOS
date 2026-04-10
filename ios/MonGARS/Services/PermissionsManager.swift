import AVFoundation
import Speech

@Observable
@MainActor
final class PermissionsManager {
    var microphoneGranted: Bool = false
    var speechRecognitionGranted: Bool = false

    init() {
        checkCurrentStatus()
    }

    func requestMicrophoneAccess() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        microphoneGranted = granted
    }

    func requestSpeechRecognition() async {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        speechRecognitionGranted = status == .authorized
    }

    func requestAllVoicePermissions() async {
        await requestMicrophoneAccess()
        await requestSpeechRecognition()
    }

    var canUseVoice: Bool {
        microphoneGranted && speechRecognitionGranted
    }

    private func checkCurrentStatus() {
        microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
        speechRecognitionGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
    }
}
