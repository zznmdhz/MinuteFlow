@preconcurrency import CoreLocation
import Foundation

@MainActor
protocol MeetingLocationProviding: AnyObject {
    func captureLocation() async -> MeetingLocation?
}

@MainActor
final class MeetingLocationProvider: NSObject, MeetingLocationProviding, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<MeetingLocation?, Never>?
    private var waitingForAuthorization = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func captureLocation() async -> MeetingLocation? {
        guard CLLocationManager.locationServicesEnabled(), continuation == nil else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .notDetermined:
                waitingForAuthorization = true
                manager.requestWhenInUseAuthorization()
            default:
                finish(nil)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard waitingForAuthorization else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            waitingForAuthorization = false
            manager.requestLocation()
        case .denied, .restricted:
            waitingForAuthorization = false
            finish(nil)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { finish(nil); return }
        Task { @MainActor in
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
            let displayName = Self.displayName(for: placemark)
            finish(MeetingLocation(
                displayName: displayName,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            ))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }

    private func finish(_ value: MeetingLocation?) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
    }

    private static func displayName(for placemark: CLPlacemark?) -> String {
        guard let placemark else { return "已记录位置" }
        let parts = [placemark.subLocality, placemark.locality, placemark.administrativeArea]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var unique: [String] = []
        for part in parts where !unique.contains(part) { unique.append(part) }
        return unique.prefix(2).joined(separator: " · ").isEmpty ? "已记录位置" : unique.prefix(2).joined(separator: " · ")
    }
}

@MainActor
final class NoopMeetingLocationProvider: MeetingLocationProviding {
    func captureLocation() async -> MeetingLocation? { nil }
}
