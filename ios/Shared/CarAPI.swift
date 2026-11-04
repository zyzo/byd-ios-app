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

        return try CarStatus.decoder.decode(T.self, from: data)
    }
}
