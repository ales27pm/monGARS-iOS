import AVFoundation
import Contacts
import CoreLocation
import EventKit
import Speech
import UserNotifications

@Observable
@MainActor
final class PermissionsManager {
    var microphoneGranted: Bool = false
    var speechRecognitionGranted: Bool = false
    var contactsGranted: Bool = false
    var calendarGranted: Bool = false
    var remindersGranted: Bool = false
    var locationAuthorized: Bool = false
    var notificationsGranted: Bool = false

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

    func requestContactsAccess() async {
        let store = CNContactStore()
        do {
            let granted = try await store.requestAccess(for: .contacts)
            contactsGranted = granted
        } catch {
            contactsGranted = false
        }
    }

    func requestCalendarAccess() async {
        let store = EKEventStore()
        do {
            let granted = try await store.requestFullAccessToEvents()
            calendarGranted = granted
        } catch {
            calendarGranted = false
        }
    }

    func requestRemindersAccess() async {
        let store = EKEventStore()
        do {
            let granted = try await store.requestFullAccessToReminders()
            remindersGranted = granted
        } catch {
            remindersGranted = false
        }
    }

    func requestNotificationAccess() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            notificationsGranted = granted
        } catch {
            notificationsGranted = false
        }
    }

    func requestAllVoicePermissions() async {
        await requestMicrophoneAccess()
        await requestSpeechRecognition()
    }

    var canUseVoice: Bool {
        microphoneGranted && speechRecognitionGranted
    }

    func refreshAll() {
        checkCurrentStatus()
    }

    private func checkCurrentStatus() {
        microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
        speechRecognitionGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        contactsGranted = CNContactStore.authorizationStatus(for: .contacts) == .authorized
        calendarGranted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        remindersGranted = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess

        let locStatus = CLLocationManager().authorizationStatus
        locationAuthorized = locStatus == .authorizedWhenInUse || locStatus == .authorizedAlways

        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsGranted = settings.authorizationStatus == .authorized
        }
    }
}
