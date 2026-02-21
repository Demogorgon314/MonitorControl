//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation

final class RemoteAPIRouter {
  private let displayController: RemoteDisplayService
  private let tokenProvider: () -> String

  init(displayController: RemoteDisplayService, tokenProvider: @escaping () -> String) {
    self.displayController = displayController
    self.tokenProvider = tokenProvider
  }

  func route(_ request: RemoteHTTPRequest) -> RemoteHTTPResponse {
    let path = request.path.components(separatedBy: "?").first ?? request.path
    guard path.hasPrefix("/api/v1/") else {
      return .error(statusCode: 404, code: "not_found", message: "route not found")
    }

    guard self.isAuthorized(request: request) else {
      return .error(statusCode: 401, code: "unauthorized", message: "invalid or missing bearer token")
    }

    switch request.method {
    case "GET":
      return self.handleGet(path: path)
    case "POST":
      return self.handlePost(path: path, request: request)
    default:
      return .error(statusCode: 405, code: "method_not_allowed", message: "method is not allowed")
    }
  }

  private func handleGet(path: String) -> RemoteHTTPResponse {
    if path == "/api/v1/health" {
      return .json(statusCode: 200, payload: RemoteHealthResponse(status: "ok", version: "v1"))
    }
    if path == "/api/v1/displays" {
      do {
        return .json(statusCode: 200, payload: RemoteDisplaysResponse(displays: try self.displayController.getDisplays()))
      } catch {
        return self.mapDisplayError(error)
      }
    }

    if let displayRoute = self.parseDisplayRoute(path), displayRoute.operation == "inputs" {
      do {
        return .json(statusCode: 200, payload: try self.displayController.getInputs(displayId: displayRoute.displayId))
      } catch {
        return self.mapDisplayError(error)
      }
    }

    if path.hasPrefix("/api/v1/displays") {
      return .error(statusCode: 405, code: "method_not_allowed", message: "method is not allowed")
    }
    return .error(statusCode: 404, code: "not_found", message: "route not found")
  }

  private func handlePost(path: String, request: RemoteHTTPRequest) -> RemoteHTTPResponse {
    switch path {
    case "/api/v1/displays/brightness":
      guard let payload: RemoteBrightnessRequest = self.decodeJSONBody(request: request) else {
        return .error(statusCode: 400, code: "invalid_json", message: "request body must be valid JSON")
      }
      do {
        return .json(statusCode: 200, payload: RemoteDisplaysResponse(displays: try self.displayController.setBrightnessForAll(valuePercent: payload.value)))
      } catch {
        return self.mapDisplayError(error)
      }
    case "/api/v1/displays/volume":
      guard let payload: RemoteVolumeRequest = self.decodeJSONBody(request: request) else {
        return .error(statusCode: 400, code: "invalid_json", message: "request body must be valid JSON")
      }
      do {
        return .json(statusCode: 200, payload: RemoteDisplaysResponse(displays: try self.displayController.setVolumeForAll(valuePercent: payload.value)))
      } catch {
        return self.mapDisplayError(error)
      }
    case "/api/v1/displays/power":
      guard let payload: RemotePowerRequest = self.decodeJSONBody(request: request) else {
        return .error(statusCode: 400, code: "invalid_json", message: "request body must be valid JSON")
      }
      do {
        let acceptedIds = try self.displayController.setPowerForAll(state: payload.state)
        return .json(statusCode: 200, payload: RemoteAllPowerResponse(requestedState: payload.state, acceptedDisplayIds: acceptedIds))
      } catch {
        return self.mapDisplayError(error)
      }
    default:
      return self.handlePostWithDisplayId(path: path, request: request)
    }
  }

  private func handlePostWithDisplayId(path: String, request: RemoteHTTPRequest) -> RemoteHTTPResponse {
    guard let displayRoute = self.parseDisplayRoute(path) else {
      if path.hasPrefix("/api/v1/displays") {
        return .error(statusCode: 404, code: "not_found", message: "route not found")
      }
      return .error(statusCode: 404, code: "not_found", message: "route not found")
    }

    let displayId = displayRoute.displayId
    let operation = displayRoute.operation
    if operation == "brightness" {
      guard let payload: RemoteBrightnessRequest = self.decodeJSONBody(request: request) else {
        return .error(statusCode: 400, code: "invalid_json", message: "request body must be valid JSON")
      }
      do {
        return .json(statusCode: 200, payload: RemoteSingleDisplayResponse(display: try self.displayController.setBrightness(displayId: displayId, valuePercent: payload.value)))
      } catch {
        return self.mapDisplayError(error)
      }
    }

    if operation == "volume" {
      guard let payload: RemoteVolumeRequest = self.decodeJSONBody(request: request) else {
        return .error(statusCode: 400, code: "invalid_json", message: "request body must be valid JSON")
      }
      do {
        return .json(statusCode: 200, payload: RemoteSingleDisplayResponse(display: try self.displayController.setVolume(displayId: displayId, valuePercent: payload.value)))
      } catch {
        return self.mapDisplayError(error)
      }
    }

    if operation == "power" {
      guard let payload: RemotePowerRequest = self.decodeJSONBody(request: request) else {
        return .error(statusCode: 400, code: "invalid_json", message: "request body must be valid JSON")
      }
      do {
        let acceptedId = try self.displayController.setPower(displayId: displayId, state: payload.state)
        return .json(statusCode: 200, payload: RemoteSinglePowerResponse(displayId: acceptedId, requestedState: payload.state, accepted: true))
      } catch {
        return self.mapDisplayError(error)
      }
    }

    if operation == "input" {
      guard let payload: RemoteSetInputRequest = self.decodeJSONBody(request: request) else {
        return .error(statusCode: 400, code: "invalid_json", message: "request body must be valid JSON")
      }
      do {
        return .json(statusCode: 200, payload: RemoteSingleDisplayResponse(display: try self.displayController.setInput(displayId: displayId, request: payload)))
      } catch {
        return self.mapDisplayError(error)
      }
    }

    return .error(statusCode: 404, code: "not_found", message: "route not found")
  }

  private func parseDisplayRoute(_ path: String) -> (displayId: UInt32, operation: String)? {
    let components = path.split(separator: "/")
    guard components.count == 5, components[0] == "api", components[1] == "v1", components[2] == "displays", let displayId = UInt32(components[3]) else {
      return nil
    }
    return (displayId, String(components[4]))
  }

  private func isAuthorized(request: RemoteHTTPRequest) -> Bool {
    let configuredToken = self.tokenProvider().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !configuredToken.isEmpty, let authorization = request.headers["authorization"] else {
      return false
    }
    let expectedAuthorization = "Bearer \(configuredToken)"
    return authorization == expectedAuthorization
  }

  private func decodeJSONBody<T: Decodable>(request: RemoteHTTPRequest) -> T? {
    guard !request.body.isEmpty else {
      return nil
    }
    guard let contentType = request.headers["content-type"]?.lowercased(), contentType.contains("application/json") else {
      return nil
    }
    return try? JSONDecoder().decode(T.self, from: request.body)
  }

  private func mapDisplayError(_ error: Error) -> RemoteHTTPResponse {
    guard let displayError = error as? RemoteDisplayControllerError else {
      return .error(statusCode: 500, code: "internal_error", message: "unexpected error")
    }

    switch displayError {
    case let .displayNotFound(displayId):
      return .error(statusCode: 404, code: "not_found", message: "display \(displayId) not found")
    case let .invalidValue(message):
      return .error(statusCode: 422, code: "invalid_value", message: message)
    case let .unsupportedOperation(message, displayIds):
      return .error(statusCode: 409, code: "unsupported_operation", message: message, displayIds: displayIds)
    case let .serviceUnavailable(message):
      return .error(statusCode: 503, code: "service_unavailable", message: message)
    case let .operationFailed(message):
      return .error(statusCode: 500, code: "internal_error", message: message)
    }
  }
}
