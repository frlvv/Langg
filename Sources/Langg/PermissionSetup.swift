enum InputPermission: CaseIterable, Hashable, Sendable {
    case accessibility
    case inputMonitoring
}

enum PermissionSetupStatus: Equatable {
    case needsPermission
    case awaitingVerification
    case verified
}

struct PermissionSetup {
    private var requested: Set<InputPermission> = []
    private var monitoringSettingsVisited = false
    private var returnedFromMonitoringSettings = false

    mutating func didRequest(_ permission: InputPermission) {
        requested.insert(permission)
        if permission == .inputMonitoring {
            monitoringSettingsVisited = false
            returnedFromMonitoringSettings = false
        }
    }

    mutating func didActivateApplication(isSystemSettings: Bool) {
        guard requested.contains(.inputMonitoring) else { return }
        if isSystemSettings {
            monitoringSettingsVisited = true
        } else if monitoringSettingsVisited {
            returnedFromMonitoringSettings = true
            monitoringSettingsVisited = false
        }
    }

    mutating func didRevoke() {
        requested.removeAll()
        monitoringSettingsVisited = false
        returnedFromMonitoringSettings = false
    }

    func status(for permission: InputPermission, reportedGranted: Bool, keyboardVerified: Bool) -> PermissionSetupStatus {
        // Requests and cached API answers cannot prove that keyboard input works.
        if keyboardVerified { return .verified }
        if requested.contains(permission) || reportedGranted { return .awaitingVerification }
        return .needsPermission
    }

    func shouldOfferRestart(keyboardVerified: Bool) -> Bool {
        !keyboardVerified && returnedFromMonitoringSettings
    }
}
