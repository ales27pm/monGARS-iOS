import CoreLocation
import Foundation

nonisolated final class GetLocationTool: ToolExecutable, @unchecked Sendable {
    let schema = ToolSchema(
        name: "get_current_location",
        description: "Gets the user's current location with address. Requires user approval.",
        parameters: [],
        requiresApproval: true
    )

    private let locationService: LocationService

    init(locationService: LocationService) {
        self.locationService = locationService
    }

    func execute(arguments: [String: String]) async -> ToolCallResult {
        do {
            let location = try await MainActor.run {
                Task {
                    try await locationService.requestCurrentLocation()
                }
            }
            let loc = try await location.value

            let placemark = try await MainActor.run {
                Task {
                    try await locationService.reverseGeocode(location: loc)
                }
            }
            let place = try? await placemark.value

            var result = "Latitude: \(loc.coordinate.latitude), Longitude: \(loc.coordinate.longitude)"
            if let place {
                var addressParts: [String] = []
                if let street = place.thoroughfare { addressParts.append(street) }
                if let city = place.locality { addressParts.append(city) }
                if let province = place.administrativeArea { addressParts.append(province) }
                if let postalCode = place.postalCode { addressParts.append(postalCode) }
                if let country = place.country { addressParts.append(country) }
                if !addressParts.isEmpty {
                    result += "\nAddress: " + addressParts.joined(separator: ", ")
                }
            }

            return .success(result)
        } catch {
            return .failure("Failed to get location: \(error.localizedDescription)")
        }
    }
}
