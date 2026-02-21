import Foundation
import XCTest
@testable import RemoteControlCore

final class RemoteAPIRouterInputTests: XCTestCase {
  private final class MockDisplayService: RemoteDisplayService {
    var displaysResult: Result<[RemoteDisplayStatus], Error> = .success([])
    var inputsResult: Result<RemoteDisplayInputsResponse, Error> = .success(
      RemoteDisplayInputsResponse(displayId: 1, input: .init(supported: false, bestEffort: true, current: nil, available: []))
    )
    var setInputResult: Result<RemoteDisplayStatus, Error> = .failure(RemoteDisplayControllerError.operationFailed(message: "not configured"))

    var lastSetInputDisplayId: UInt32?
    var lastSetInputRequest: RemoteSetInputRequest?

    func getDisplays() throws -> [RemoteDisplayStatus] {
      try self.displaysResult.get()
    }

    func getInputs(displayId: UInt32) throws -> RemoteDisplayInputsResponse {
      try self.inputsResult.get()
    }

    func setBrightness(displayId: UInt32, valuePercent: Int) throws -> RemoteDisplayStatus {
      throw RemoteDisplayControllerError.operationFailed(message: "not used")
    }

    func setBrightnessForAll(valuePercent: Int) throws -> [RemoteDisplayStatus] {
      throw RemoteDisplayControllerError.operationFailed(message: "not used")
    }

    func setVolume(displayId: UInt32, valuePercent: Int) throws -> RemoteDisplayStatus {
      throw RemoteDisplayControllerError.operationFailed(message: "not used")
    }

    func setVolumeForAll(valuePercent: Int) throws -> [RemoteDisplayStatus] {
      throw RemoteDisplayControllerError.operationFailed(message: "not used")
    }

    func setPower(displayId: UInt32, state: RemoteRequestedPowerState) throws -> UInt32 {
      throw RemoteDisplayControllerError.operationFailed(message: "not used")
    }

    func setPowerForAll(state: RemoteRequestedPowerState) throws -> [UInt32] {
      throw RemoteDisplayControllerError.operationFailed(message: "not used")
    }

    func setInput(displayId: UInt32, request: RemoteSetInputRequest) throws -> RemoteDisplayStatus {
      self.lastSetInputDisplayId = displayId
      self.lastSetInputRequest = request
      return try self.setInputResult.get()
    }
  }

  func testGetDisplaysIncludesInputSection() throws {
    let mock = MockDisplayService()
    mock.displaysResult = .success([self.makeDisplayStatus(displayId: 9)])
    let router = RemoteAPIRouter(displayController: mock, tokenProvider: { "token" })

    let response = router.route(self.makeRequest(method: "GET", path: "/api/v1/displays"))
    XCTAssertEqual(response.statusCode, 200)

    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let displays = try XCTUnwrap(payload["displays"] as? [[String: Any]])
    let firstDisplay = try XCTUnwrap(displays.first)
    let input = try XCTUnwrap(firstDisplay["input"] as? [String: Any])
    XCTAssertEqual(input["supported"] as? Bool, true)
    XCTAssertEqual(input["bestEffort"] as? Bool, true)

    let current = try XCTUnwrap(input["current"] as? [String: Any])
    XCTAssertEqual(current["name"] as? String, "HDMI-1")
  }

  func testGetInputsRouteReturnsPerDisplayPayload() throws {
    let mock = MockDisplayService()
    mock.inputsResult = .success(
      RemoteDisplayInputsResponse(displayId: 42, input: self.makeInputStatus())
    )
    let router = RemoteAPIRouter(displayController: mock, tokenProvider: { "token" })

    let response = router.route(self.makeRequest(method: "GET", path: "/api/v1/displays/42/inputs"))
    XCTAssertEqual(response.statusCode, 200)

    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    XCTAssertEqual(payload["displayId"] as? Int, 42)
    XCTAssertNotNil(payload["input"])
  }

  func testPostInputRoutePassesDecodedPayloadToService() throws {
    let mock = MockDisplayService()
    mock.setInputResult = .success(self.makeDisplayStatus(displayId: 42))
    let router = RemoteAPIRouter(displayController: mock, tokenProvider: { "token" })

    let body = Data("{\"name\":\"DP-1\"}".utf8)
    let response = router.route(self.makeRequest(method: "POST", path: "/api/v1/displays/42/input", body: body))
    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(mock.lastSetInputDisplayId, 42)
    XCTAssertEqual(mock.lastSetInputRequest?.name, "DP-1")
    XCTAssertNil(mock.lastSetInputRequest?.code)
  }

  func testPostInputRouteReturnsInvalidJsonWhenMalformedBody() {
    let mock = MockDisplayService()
    let router = RemoteAPIRouter(displayController: mock, tokenProvider: { "token" })

    let response = router.route(self.makeRequest(method: "POST", path: "/api/v1/displays/42/input", body: Data("{\"name\":".utf8)))
    XCTAssertEqual(response.statusCode, 400)

    let payload = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
    let error = payload?["error"] as? [String: Any]
    XCTAssertEqual(error?["code"] as? String, "invalid_json")
  }

  func testUnsupportedInputOperationReturnsExistingErrorEnvelope() throws {
    let mock = MockDisplayService()
    mock.inputsResult = .failure(
      RemoteDisplayControllerError.unsupportedOperation(message: "input not supported", displayIds: [42])
    )
    let router = RemoteAPIRouter(displayController: mock, tokenProvider: { "token" })

    let response = router.route(self.makeRequest(method: "GET", path: "/api/v1/displays/42/inputs"))
    XCTAssertEqual(response.statusCode, 409)

    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "unsupported_operation")
    XCTAssertEqual(error["message"] as? String, "input not supported")
  }

  private func makeDisplayStatus(displayId: UInt32) -> RemoteDisplayStatus {
    RemoteDisplayStatus(
      id: displayId,
      name: "Display \(displayId)",
      friendlyName: "Display \(displayId)",
      type: .other,
      isVirtual: false,
      isDummy: false,
      brightness: 70,
      volume: 30,
      powerState: .on,
      capabilities: .init(brightness: true, volume: true, power: true),
      input: self.makeInputStatus()
    )
  }

  private func makeInputStatus() -> RemoteDisplayInputStatus {
    RemoteDisplayInputStatus(
      supported: true,
      bestEffort: true,
      current: RemoteInputSource(code: 17, name: "HDMI-1"),
      available: [
        RemoteInputSource(code: 17, name: "HDMI-1"),
        RemoteInputSource(code: 15, name: "DP-1"),
      ]
    )
  }

  private func makeRequest(method: String, path: String, body: Data? = nil) -> RemoteHTTPRequest {
    var headers = [
      "authorization": "Bearer token",
    ]
    if body != nil {
      headers["content-type"] = "application/json"
    }
    return RemoteHTTPRequest(method: method, path: path, headers: headers, body: body ?? Data())
  }
}
