import AVFoundation
import Contacts
import CoreLocation
import EventKit
import Speech
import UserNotifications

@Observable
@MainActor
final class PermissionsManager: NSObject {
    enum VoiceAuthorizationState: Sendable, Equatable {
        case notDetermined
        case granted
        case denied
        case restricted

        var isGranted: Bool {
            self == .granted
        }

        var isDeniedOrRestricted: Bool {
            self == .denied || self == .restricted
        }
    }

    enum RefreshTrigger: Sendable, Equatable {
        case initial
        case manual
        case appDidBecomeActive
    }

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
    private(set) var microphoneAuthorizationState: VoiceAuthorizationState = .notDetermined
    private(set) var speechRecognitionAuthorizationState: VoiceAuthorizationState = .notDetermined
    private(set) var lastRefreshTrigger: RefreshTrigger = .initial
    var contactsGranted: Bool = false
    var calendarGranted: Bool = false
    var remindersGranted: Bool = false
    var locationAuthorized: Bool = false
    var notificationsGranted: Bool = false
    private let locationManager = CLLocationManager()
    private var locationPermissionContinuation: CheckedContinuation<Bool, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
        refreshAll(trigger: .initial)
    }

    func requestMicrophoneAccess() async {
        let current = currentMicrophoneAuthorizationState()
        microphoneAuthorizationState = current
        microphoneGranted = current.isGranted

        guard current == .notDetermined else {
            return
        }

        let granted = await AVAudioApplication.requestRecordPermission()
        microphoneAuthorizationState = granted ? .granted : currentMicrophoneAuthorizationState()
        microphoneGranted = microphoneAuthorizationState.isGranted
    }

    func requestSpeechRecognition() async {
        let current = Self.voiceAuthorizationState(forSpeechAuthorizationStatus: SFSpeechRecognizer.authorizationStatus())
        speechRecognitionAuthorizationState = current
        speechRecognitionGranted = current.isGranted

        guard current == .notDetermined else {
            return
        }

        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        speechRecognitionAuthorizationState = Self.voiceAuthorizationState(forSpeechAuthorizationStatus: status)
        speechRecognitionGranted = speechRecognitionAuthorizationState.isGranted
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

    func requestLocationAccess() async -> Bool {
        let currentStatus = locationManager.authorizationStatus
        if currentStatus == .authorizedWhenInUse || currentStatus == .authorizedAlways {
            locationAuthorized = true
            return true
        }
        if currentStatus == .denied || currentStatus == .restricted {
            locationAuthorized = false
            return false
        }

        return await withCheckedContinuation { continuation in
            locationPermissionContinuation?.resume(returning: locationAuthorized)
            locationPermissionContinuation = continuation
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func requestAllNativeFeaturePermissions() async {
        _ = await requestLocationAccess()
        await requestNotificationAccess()
        await requestContactsAccess()
        await requestCalendarAccess()
        await requestRemindersAccess()
        checkCurrentStatus()
    }

    func requestAllVoicePermissions() async {
        await requestMicrophoneAccess()
        await requestSpeechRecognition()
        refreshAll()
    }

    var canUseVoice: Bool {
        microphoneGranted && speechRecognitionGranted
    }

    var voicePermissionsDenied: Bool {
        Self.shouldOfferVoiceSettingsRecovery(
            microphoneState: microphoneAuthorizationState,
            speechState: speechRecognitionAuthorizationState
        )
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
        refreshAll(trigger: .manual)
    }

    /// Refreshes permission state after the app returns to foreground so Settings reflects current system authorization.
    func refreshAfterAppBecomesActive() {
        refreshAll(trigger: .appDidBecomeActive)
    }

    private func refreshAll(trigger: RefreshTrigger) {
        lastRefreshTrigger = trigger
        checkCurrentStatus()
    }

    private func checkCurrentStatus() {
        let micState = currentMicrophoneAuthorizationState()
        microphoneAuthorizationState = micState
        microphoneGranted = micState.isGranted

        let speechState = Self.voiceAuthorizationState(forSpeechAuthorizationStatus: SFSpeechRecognizer.authorizationStatus())
        speechRecognitionAuthorizationState = speechState
        speechRecognitionGranted = speechState.isGranted
        contactsGranted = CNContactStore.authorizationStatus(for: .contacts) == .authorized
        calendarGranted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        remindersGranted = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess

        let locStatus = locationManager.authorizationStatus
        locationAuthorized = locStatus == .authorizedWhenInUse || locStatus == .authorizedAlways

        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsGranted = settings.authorizationStatus == .authorized
        }
    }

    private func currentMicrophoneAuthorizationState() -> VoiceAuthorizationState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    /// Maps `SFSpeechRecognizerAuthorizationStatus` to the app's normalized voice permission state.
    nonisolated static func voiceAuthorizationState(forSpeechAuthorizationStatus status: SFSpeechRecognizerAuthorizationStatus) -> VoiceAuthorizationState {
        switch status {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    /// Maps microphone record permission to the app's normalized voice permission state.
    nonisolated static func voiceAuthorizationState(forMicrophonePermission permission: AVAudioSession.RecordPermission) -> VoiceAuthorizationState {
        switch permission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    /// Returns `true` when denied/restricted voice permissions require user recovery through iOS Settings.
    nonisolated static func shouldOfferVoiceSettingsRecovery(
        microphoneState: VoiceAuthorizationState,
        speechState: VoiceAuthorizationState
    ) -> Bool {
        switch microphoneState {
        case .denied, .restricted:
            return true
        case .notDetermined, .granted:
            break
        }

        switch speechState {
        case .denied, .restricted:
            return true
        case .notDetermined, .granted:
            return false
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

extension PermissionsManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = manager.authorizationStatus
            self.locationAuthorized = status == .authorizedWhenInUse || status == .authorizedAlways
            guard status != .notDetermined else { return }
            self.locationPermissionContinuation?.resume(returning: self.locationAuthorized)
            self.locationPermissionContinuation = nil
        }
    }
}
