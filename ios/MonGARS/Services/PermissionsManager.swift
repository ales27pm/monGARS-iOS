import AVFoundation
import Contacts
import CoreLocation
import EventKit
import Speech
import UserNotifications

@Observable
@MainActor
final class PermissionsManager {
    struct NativePermissionStatus: Identifiable, Sendable {
        let feature: NativeFeature
        let granted: Bool

        var id: NativeFeature { feature }
    }

    enum NativeFeature: CaseIterable, Sendable {
        case location
        case contacts
        case calendar
        case reminders
        case notifications
    }

    var microphoneGranted: Bool = false
    var speechRecognitionGranted: Bool = false
    var contactsGranted: Bool = false
    var calendarGranted: Bool = false
    var remindersGranted: Bool = false
    var locationAuthorized: Bool = false
    var notificationsGranted: Bool = false
    private let locationManager = CLLocationManager()

    init() {
        locationManager.delegate = self
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

    func requestLocationAccess() {
        locationManager.requestWhenInUseAuthorization()
    }

    func requestAllNativeFeaturePermissions() async {
        requestLocationAccess()
        await requestNotificationAccess()
        await requestContactsAccess()
        await requestCalendarAccess()
        await requestRemindersAccess()
        checkCurrentStatus()
    }

    func requestAllVoicePermissions() async {
        await requestMicrophoneAccess()
        await requestSpeechRecognition()
    }

    var canUseVoice: Bool {
        microphoneGranted && speechRecognitionGranted
    }

    var nativePermissionStatuses: [NativePermissionStatus] {
        NativeFeature.allCases.map { feature in
            NativePermissionStatus(feature: feature, granted: isNativePermissionGranted(feature))
        }
    }

    var allNativeFeaturePermissionsGranted: Bool {
        NativeFeature.allCases.allSatisfy(isNativePermissionGranted(_:))
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

        let locStatus = locationManager.authorizationStatus
        locationAuthorized = locStatus == .authorizedWhenInUse || locStatus == .authorizedAlways

        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsGranted = settings.authorizationStatus == .authorized
        }
    }

    func nativeFeatureTitle(_ feature: NativeFeature, localeManager: LocaleManager) -> String {
        switch feature {
        case .location:
            return localeManager.localizedString("Location", "Localisation")
        case .contacts:
            return localeManager.localizedString("Contacts", "Contacts")
        case .calendar:
            return localeManager.localizedString("Calendar", "Calendrier")
        case .reminders:
            return localeManager.localizedString("Reminders", "Rappels")
        case .notifications:
            return localeManager.localizedString("Notifications", "Notifications")
        }
    }

    private func isNativePermissionGranted(_ feature: NativeFeature) -> Bool {
        switch feature {
        case .location:
            return locationAuthorized
        case .contacts:
            return contactsGranted
        case .calendar:
            return calendarGranted
        case .reminders:
            return remindersGranted
        case .notifications:
            return notificationsGranted
        }
    }
}

extension PermissionsManager: @preconcurrency CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = manager.authorizationStatus
            self.locationAuthorized = status == .authorizedWhenInUse || status == .authorizedAlways
        }
    }
}
