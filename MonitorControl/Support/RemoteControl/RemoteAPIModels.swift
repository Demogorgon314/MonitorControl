//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation

enum RemoteDisplayType: String, Codable {
  case apple
  case other
}

enum RemotePowerState: String, Codable {
  case on
  case off
  case standby
  case suspend
  case unknown
}

enum RemoteRequestedPowerState: String, Codable {
  case on
  case off
}

struct RemoteDisplayCapabilities: Codable {
  let brightness: Bool
  let power: Bool
}

struct RemoteDisplayStatus: Codable {
  let id: UInt32
  let name: String
  let friendlyName: String
  let type: RemoteDisplayType
  let isVirtual: Bool
  let isDummy: Bool
  let brightness: Int
  let powerState: RemotePowerState
  let capabilities: RemoteDisplayCapabilities
}

struct RemoteHealthResponse: Codable {
  let status: String
  let version: String
}

struct RemoteDisplaysResponse: Codable {
  let displays: [RemoteDisplayStatus]
}

struct RemoteSingleDisplayResponse: Codable {
  let display: RemoteDisplayStatus
}

struct RemoteSinglePowerResponse: Codable {
  let displayId: UInt32
  let requestedState: RemoteRequestedPowerState
  let accepted: Bool
}

struct RemoteAllPowerResponse: Codable {
  let requestedState: RemoteRequestedPowerState
  let acceptedDisplayIds: [UInt32]
}

struct RemoteAPIErrorDetail: Codable {
  let code: String
  let message: String
  let displayIds: [UInt32]?
}

struct RemoteAPIErrorResponse: Codable {
  let error: RemoteAPIErrorDetail
}

struct RemoteBrightnessRequest: Decodable {
  let value: Int
}

struct RemotePowerRequest: Decodable {
  let state: RemoteRequestedPowerState
}

struct RemoteHTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data
}

struct RemoteHTTPResponse {
  let statusCode: Int
  let headers: [String: String]
  let body: Data

  static func json<T: Encodable>(statusCode: Int, payload: T, extraHeaders: [String: String] = [:]) -> RemoteHTTPResponse {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(payload)) ?? Data("{}".utf8)
    var responseHeaders: [String: String] = [
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    ]
    for (key, value) in extraHeaders {
      responseHeaders[key] = value
    }
    return RemoteHTTPResponse(statusCode: statusCode, headers: responseHeaders, body: data)
  }

  static func error(statusCode: Int, code: String, message: String, displayIds: [UInt32]? = nil) -> RemoteHTTPResponse {
    let payload = RemoteAPIErrorResponse(error: .init(code: code, message: message, displayIds: displayIds))
    return .json(statusCode: statusCode, payload: payload)
  }
}
