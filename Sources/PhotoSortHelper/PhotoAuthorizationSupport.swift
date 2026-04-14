import Photos

enum PhotoAuthorizationSupport {
    static func canAccessLibrary(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    static func accessDescription(for status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "Access granted. You can scan and queue items into review albums."
        case .limited:
            return "Limited access granted. Only the photos macOS shared with the app will appear."
        case .denied:
            return "Access denied. Enable Photos access in System Settings > Privacy & Security > Photos."
        case .restricted:
            return "Access restricted by system policy."
        case .notDetermined:
            return "Access has not been requested yet. The app will ask only when you start scanning."
        @unknown default:
            return "Unknown authorization status."
        }
    }

    static func scanActionMessage(for status: PHAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return "Photos access is denied. Enable it in System Settings > Privacy & Security > Photos, then try scanning again."
        case .restricted:
            return "Photos access is restricted by system policy, so the app cannot scan your library."
        case .limited:
            return "Scanning will use only the photos macOS shared with this app."
        case .authorized:
            return "Access granted."
        case .notDetermined:
            return "The app will ask for Photos access when you start scanning."
        @unknown default:
            return "Photos access is unavailable."
        }
    }

    static func queueActionMessage(for status: PHAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return "This queue action needs Photos access. Enable it in System Settings > Privacy & Security > Photos, then try again."
        case .restricted:
            return "This queue action cannot run because Photos access is restricted by system policy."
        case .limited:
            return "macOS granted limited Photos access. Queueing may affect only the photos currently shared with the app."
        case .authorized:
            return "Access granted."
        case .notDetermined:
            return "The app will ask for Photos access before queueing items into review albums."
        @unknown default:
            return "Photos access is unavailable."
        }
    }
}
