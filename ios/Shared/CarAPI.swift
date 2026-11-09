import Foundation

/// Talks to the BYD Companion backend (server.py), which talks to BYD's cloud.
struct CarAPI {
    var baseURL = AppConfig.serverURL
    var token = AppConfig.serverToken

    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func status(refresh: Bool = false) async throws -> CarStatus {
        if AppConfig.demo { return await DemoCar.status }
        var components = URLComponents(url: try endpoint("status"), resolvingAgainstBaseURL: false)!
        if refresh {
            components.queryItems = [URLQueryItem(name: "refresh", value: "true")]
        }
        return try await send(URLRequest(url: components.url!))
    }

    /// Downloads the Bluetooth key the Mac provisioned (provision_ble_key.py).
    func bleKey() async throws -> BleKey {
        if AppConfig.demo { throw ServerError(message: "Not available in demo mode.") }
        return try await send(URLRequest(url: try endpoint("ble-key")))
    }

    /// Sends a command to the car. Returns whether BYD confirmed it.
    func run(_ command: CarCommand, temperature: Double = 21, minutes: Int = 20) async throws -> Bool {
        if AppConfig.demo {
            try await Task.sleep(for: .milliseconds(600))
            await DemoCar.apply(command)
            return true
        }
        var request = URLRequest(url: try endpoint("command/\(command.rawValue)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ClimateBody(temperature: temperature, minutes: minutes))
        let result: CommandResult = try await send(request)
        return result.success
    }

    // Trip log (see README, "Trip log"). The Worker answers these itself.

    func trips(since: Date? = nil) async throws -> TripsResponse {
        if AppConfig.demo { return await DemoTrips.response() }
        var components = URLComponents(url: try endpoint("trips"), resolvingAgainstBaseURL: false)!
        if let since {
            components.queryItems = [URLQueryItem(name: "since", value: Self.iso.string(from: since))]
        }
        return try await send(URLRequest(url: components.url!))
    }

    func deleteTrip(_ id: String) async throws {
        if AppConfig.demo { await DemoTrips.delete(id); return }
        var request = URLRequest(url: try endpoint("trips/\(id)"))
        request.httpMethod = "DELETE"
        let _: Empty = try await send(request)
    }

    /// Saves what a refuel or a charge really came to; nil for both goes back to the estimate.
    func editRefill(_ tripId: String, kind: Refill.Kind, amount: Double?, cost: Double?) async throws -> Trip? {
        if AppConfig.demo { return nil }
        struct Body: Encodable { var kind: Refill.Kind; var amount: Double?; var cost: Double? }
        var request = try post("trips/\(tripId)/refill", Body(kind: kind, amount: amount, cost: cost))
        request.httpMethod = "PUT"
        return try await send(request)
    }

    /// Saves what a charge between trips really came to; nil for both goes back to the estimate.
    func editCharge(_ chargeId: String, amount: Double?, cost: Double?) async throws -> Charge? {
        if AppConfig.demo { return nil }
        struct Body: Encodable { var amount: Double?; var cost: Double? }
        var request = try post("charges/\(chargeId)", Body(amount: amount, cost: cost))
        request.httpMethod = "PUT"
        return try await send(request)
    }

    func deleteCharge(_ id: String) async throws {
        if AppConfig.demo { await DemoTrips.deleteCharge(id); return }
        var request = URLRequest(url: try endpoint("charges/\(id)"))
        request.httpMethod = "DELETE"
        let _: Empty = try await send(request)
    }

    func postEvents(_ events: [PhoneEvent]) async throws {
        if AppConfig.demo { return }
        let body = PhoneEventsBody(phoneId: PhoneIdentity.id, phoneName: PhoneIdentity.name, events: events)
        let _: Empty = try await send(try post("trips/events", body))
    }

    func settings() async throws -> EnergySettings {
        if AppConfig.demo { return await DemoTrips.settings }
        return try await send(URLRequest(url: try endpoint("settings")))
    }

    func updateSettings(_ settings: EnergySettings) async throws -> EnergySettings {
        if AppConfig.demo { await DemoTrips.update(settings); return settings }
        var request = try post("settings", settings)
        request.httpMethod = "PUT"
        return try await send(request)
    }

    func prices() async throws -> Prices {
        if AppConfig.demo { return await DemoTrips.prices }
        return try await send(URLRequest(url: try endpoint("prices")))
    }

    func phones() async throws -> PhonesResponse {
        if AppConfig.demo { return await DemoTrips.phones() }
        return try await send(URLRequest(url: try endpoint("phones")))
    }

    func lease() async throws -> LeaseResponse {
        if AppConfig.demo { return LeaseResponse(granted: true, leader: Leader(phoneId: PhoneIdentity.id, name: PhoneIdentity.name, until: Date().addingTimeInterval(120))) }
        return try await send(try post("lease", LeaseRequest(phoneId: PhoneIdentity.id, phoneName: PhoneIdentity.name)))
    }

    private static let iso = ISO8601DateFormatter()

    private func post<Body: Encodable>(_ path: String, _ body: Body) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// For routes whose answer doesn't matter; the server may return nothing at all.
    private struct Empty: Decodable {
        init() {}
        init(from decoder: Decoder) throws {}
    }

    private struct ClimateBody: Encodable {
        let temperature: Double
        let minutes: Int
    }

    private struct CommandResult: Decodable {
        let success: Bool
    }

    private struct ErrorBody: Decodable {
        let detail: String
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let baseURL else {
            throw ServerError(message: "No server set. Add SERVER_URL to ios/Config.local.xcconfig and rebuild.")
        }
        return baseURL.appending(path: path)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        var request = request
        // Realtime data and commands can take a while: BYD polls the car.
        request.timeoutInterval = 90
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            let host = request.url?.host() ?? "?"
            throw ServerError(message: "Can't reach the server at \(host): \(error.localizedDescription)")
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
            throw ServerError(message: detail ?? "Server error \(code)")
        }

        if T.self == Empty.self { return Empty() as! T }
        return try CarStatus.decoder.decode(T.self, from: data)
    }
}
