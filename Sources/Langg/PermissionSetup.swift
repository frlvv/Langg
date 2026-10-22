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
        guard requested.contains(.accessibility), requested.contains(.inputMonitoring) else { return }
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

    func status(for permission: InputPermission, reportedGranted: Bool, keyboardVerified: Bool,
                freshlyGranted: Bool? = nil) -> PermissionSetupStatus {
        // A fresh check confirms this permission, while keyboard verification
        // remains the requirement for the overall working status.
        if keyboardVerified { return .verified }
        if freshlyGranted == true { return .verified }
        if freshlyGranted == false {
            return requested.contains(permission) ? .awaitingVerification : .needsPermission
        }
        if requested.contains(permission) || reportedGranted { return .awaitingVerification }
        return .needsPermission
    }

    func shouldOfferRestart(keyboardVerified: Bool) -> Bool {
        !keyboardVerified && requested.contains(.accessibility) && returnedFromMonitoringSettings
    }
}
