import SwiftUI
import CoreLocation

/// Process-wide last-known location, fed by every `LocationProvider` instance.
/// Non-UI consumers (SessionEngine's Aim Assist) read it without owning a
/// CLLocationManager of their own. `nil` until any provider produces a fix —
/// consumers must degrade gracefully (Aim Assist skips with a status note).
@MainActor
public final class AppLocation {
    public static let shared = AppLocation()
    public var current: GeoLocation?
    private init() {}
}

/// Best-effort reverse geocoding for the logbook: turns a `GeoLocation` into a
/// city name ("Cupertino") for the share card's optional location line.
/// Returns nil on any failure (offline, no placemark) — callers store nothing
/// rather than a guess, and the card simply omits the location.
public enum CityResolver {
    public static func city(for location: GeoLocation) async -> String? {
        let point = CLLocation(latitude: location.latitude, longitude: location.longitude)
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(point)
        return placemarks?.first?.locality
    }
}

/// When-in-use location for sky computation. Publishes the freshest `GeoLocation`,
/// persists the last known fix so the Tonight screen works instantly on relaunch,
/// and surfaces a `denied` flag so the UI can show a friendly settings prompt.
@MainActor
public final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published public private(set) var location: GeoLocation? {
        didSet { AppLocation.shared.current = location }
    }
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

        // Property observers don't fire inside init — publish the restored/default
        // fix to the shared last-known location explicitly.
        if let restored = location { AppLocation.shared.current = restored }
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
