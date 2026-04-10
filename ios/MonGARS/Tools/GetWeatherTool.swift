import CoreLocation
import Foundation

nonisolated final class GetWeatherTool: ToolExecutable, @unchecked Sendable {
    let schema = ToolSchema(
        name: "get_weather",
        description: "Gets basic weather information for the user's current location or a specified city.",
        parameters: [
            ToolParameter(name: "city", description: "City name to get weather for (uses current location if omitted)", type: .string, required: false),
        ],
        requiresApproval: false
    )

    private let locationService: LocationService

    init(locationService: LocationService) {
        self.locationService = locationService
    }

    func execute(arguments: [String: String]) async -> ToolCallResult {
        var coordinate: CLLocationCoordinate2D?

        if let city = arguments["city"], !city.isEmpty {
            let geocoder = CLGeocoder()
            do {
                let placemarks = try await geocoder.geocodeAddressString(city)
                coordinate = placemarks.first?.location?.coordinate
            } catch {
                return .failure("Could not find location for '\(city)'")
            }
        } else {
            do {
                let location = try await MainActor.run {
                    Task { try await locationService.requestCurrentLocation() }
                }
                let loc = try await location.value
                coordinate = loc.coordinate
            } catch {
                return .failure("Could not get current location: \(error.localizedDescription)")
            }
        }

        guard let coord = coordinate else {
            return .failure("No location available")
        }

        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(coord.latitude)&longitude=\(coord.longitude)&current=temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code&timezone=auto"

        guard let url = URL(string: urlString) else {
            return .failure("Invalid weather API URL")
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any] else {
                return .failure("Unexpected weather response format")
            }

            let temp = current["temperature_2m"] as? Double ?? 0
            let humidity = current["relative_humidity_2m"] as? Int ?? 0
            let windSpeed = current["wind_speed_10m"] as? Double ?? 0
            let weatherCode = current["weather_code"] as? Int ?? 0

            let description = weatherDescription(for: weatherCode)
            let cityName = arguments["city"] ?? "current location"

            return .success("""
            Weather for \(cityName):
            Condition: \(description)
            Temperature: \(String(format: "%.1f", temp))°C
            Humidity: \(humidity)%
            Wind Speed: \(String(format: "%.1f", windSpeed)) km/h
            """)
        } catch {
            return .failure("Weather request failed: \(error.localizedDescription)")
        }
    }

    private func weatherDescription(for code: Int) -> String {
        switch code {
        case 0: return "Clear sky"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Foggy"
        case 51, 53, 55: return "Drizzle"
        case 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing rain"
        case 71, 73, 75: return "Snowfall"
        case 77: return "Snow grains"
        case 80, 81, 82: return "Rain showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Unknown"
        }
    }
}
