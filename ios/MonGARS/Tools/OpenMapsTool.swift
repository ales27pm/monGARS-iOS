import Foundation
import MapKit

nonisolated final class OpenMapsTool: ToolExecutable, @unchecked Sendable {
    let schema = ToolSchema(
        name: "open_maps",
        description: "Opens Apple Maps with directions or a search query.",
        parameters: [
            ToolParameter(name: "query", description: "A place name or address to search for", type: .string, required: false),
            ToolParameter(name: "latitude", description: "Latitude for a specific coordinate", type: .string, required: false),
            ToolParameter(name: "longitude", description: "Longitude for a specific coordinate", type: .string, required: false),
            ToolParameter(name: "directions_to", description: "Destination address for driving directions", type: .string, required: false),
        ],
        requiresApproval: false
    )

    func execute(arguments: [String: String]) async -> ToolCallResult {
        if let directionsTo = arguments["directions_to"], !directionsTo.isEmpty {
            return await openDirections(to: directionsTo)
        }

        if let latStr = arguments["latitude"], let lonStr = arguments["longitude"],
           let lat = Double(latStr), let lon = Double(lonStr) {
            return await openCoordinate(lat: lat, lon: lon)
        }

        if let query = arguments["query"], !query.isEmpty {
            return await openSearch(query: query)
        }

        return .failure("Provide a query, coordinates, or directions_to parameter.")
    }

    private func openDirections(to destination: String) async -> ToolCallResult {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.geocodeAddressString(destination)
            guard let placemark = placemarks.first, let location = placemark.location else {
                return .failure("Could not find location for '\(destination)'")
            }

            let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
            mapItem.name = destination

            await MainActor.run {
                mapItem.openInMaps(launchOptions: [
                    MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
                ])
            }

            return .success("Opened Apple Maps with directions to '\(destination)'.")
        } catch {
            return .failure("Geocoding failed: \(error.localizedDescription)")
        }
    }

    private func openCoordinate(lat: Double, lon: Double) async -> ToolCallResult {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = "Location (\(lat), \(lon))"

        await MainActor.run {
            mapItem.openInMaps()
        }

        return .success("Opened Apple Maps at coordinates (\(lat), \(lon)).")
    }

    private func openSearch(query: String) async -> ToolCallResult {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "maps://?q=\(encodedQuery)") else {
            return .failure("Invalid search query")
        }

        await MainActor.run {
            UIApplication.shared.open(url)
        }

        return .success("Opened Apple Maps searching for '\(query)'.")
    }
}
