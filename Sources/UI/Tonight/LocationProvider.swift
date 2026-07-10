import SwiftUI
import CoreLocation

/// When-in-use location for sky computation. Publishes the freshest `GeoLocation`,
/// persists the last known fix so the Tonight screen works instantly on relaunch,
/// and surfaces a `denied` flag so the UI can show a friendly settings prompt.
@MainActor
public final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published public private(set) var location: GeoLocation?
    @Published public private(set) var denied: Bool = false

    private let manager = CLLocationManager()

    private static let latitudeKey = "starflow.lastLatitude"
    private static let longitudeKey = "starflow.lastLongitude"

    public override init() {
        super.init()

        // Restore last known fix so the sky renders immediately.
        let defaults = UserDefaults.standard
        if let lat = defaults.object(forKey: Self.latitudeKey) as? Double,
           let lon = defaults.object(forKey: Self.longitudeKey) as? Double {
            location = GeoLocation(latitude: lat, longitude: lon)
        }

        #if targetEnvironment(simulator)
        // Simulator default (Apple Park) so previews and tests always have a sky.
        if location == nil {
            location = GeoLocation(latitude: 37.3349, longitude: -122.0090)
        }
        #endif

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Ask for permission if undecided, otherwise request a one-shot fix.
    /// Safe to call repeatedly (on appear, on pull-to-refresh).
    public func requestAccess() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            denied = false
            manager.requestLocation()
        case .denied, .restricted:
            denied = true
        @unknown default:
            break
        }
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            denied = false
            manager.requestLocation()
        case .denied, .restricted:
            denied = true
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    private func accept(latitude: Double, longitude: Double) {
        location = GeoLocation(latitude: latitude, longitude: longitude)
        let defaults = UserDefaults.standard
        defaults.set(latitude, forKey: Self.latitudeKey)
        defaults.set(longitude, forKey: Self.longitudeKey)
    }

    // MARK: CLLocationManagerDelegate (delegate callbacks hop to the main actor)

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.handleAuthorizationChange(status)
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager,
                                            didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        let lat = fix.coordinate.latitude
        let lon = fix.coordinate.longitude
        Task { @MainActor in
            self.accept(latitude: lat, longitude: lon)
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager,
                                            didFailWithError error: Error) {
        // One-shot fix failed (airplane mode, indoors, etc.). The last known /
        // stored location stays valid — sky math degrades gracefully with a
        // kilometer-scale stale position, so no user-facing error is needed.
    }
}
