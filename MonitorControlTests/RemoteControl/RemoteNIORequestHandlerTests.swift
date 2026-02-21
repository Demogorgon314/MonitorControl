import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest
@testable import RemoteControlCore

final class RemoteNIORequestHandlerTests: XCTestCase {
  private struct OkPayload: Codable {
    let ok: Bool
  }

  private struct ParsedHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
  }

  func testFragmentedBodyAcrossMultipleReads() throws {
    let lock = NSLock()
    var capturedRequest: RemoteHTTPRequest?
    let channel = try self.makeChannel { request in
      lock.lock()
      capturedRequest = request
      lock.unlock()
      return .json(statusCode: 200, payload: OkPayload(ok: true))
    }
    defer { _ = try? channel.finish() }

    let fragments = [
      "POST /api/v1/displays/1/brightness HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n",
      "{\"value\":",
      "70}",
    ]
    try self.writeInboundFragments(fragments, to: channel)
    let response = try self.readSingleResponse(from: channel)

    XCTAssertEqual(response.statusCode, 200)
    lock.lock()
    let request = capturedRequest
    lock.unlock()
    XCTAssertEqual(request?.path, "/api/v1/displays/1/brightness")
    XCTAssertEqual(String(data: request?.body ?? Data(), encoding: .utf8), "{\"value\":70}")
  }

  func testHighFrequencyGetAndPostRequestsDoNotMisclassifyTimeout() throws {
    let channel = try self.makeChannel { _ in
      .json(statusCode: 200, payload: OkPayload(ok: true))
    }
    defer { _ = try? channel.finish() }

    for index in 0 ..< 120 {
      if index.isMultiple(of: 2) {
        try self.writeInboundFragments(
          [
            "GET /api/v1/displays HTTP/1.1\r\nHost: localhost\r\n\r\n",
          ],
          to: channel
        )
      } else {
        try self.writeInboundFragments(
          [
            "POST /api/v1/displays/1/brightness HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n{\"value\":70}",
          ],
          to: channel
        )
      }

      let response = try self.readSingleResponse(from: channel)
      XCTAssertEqual(response.statusCode, 200)
      XCTAssertNotEqual(response.statusCode, 408)
    }
  }

  func testIncompleteRequestReturnsRequestTimeoutEnvelope() throws {
    let lock = NSLock()
    var routeCallCount = 0

    let channel = try self.makeChannel { _ in
      lock.lock()
      routeCallCount += 1
      lock.unlock()
      return .json(statusCode: 200, payload: OkPayload(ok: true))
    }
    defer { _ = try? channel.finish() }

    try self.writeInboundFragments(
      [
        "POST /api/v1/displays/1/brightness HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n{\"value\":",
      ],
      to: channel
    )

    channel.pipeline.fireUserInboundEventTriggered(IdleStateHandler.IdleStateEvent.read)
    channel.embeddedEventLoop.run()
    let response = try self.readSingleResponse(from: channel)

    lock.lock()
    let calls = routeCallCount
    lock.unlock()
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(response.statusCode, 408)

    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "request_timeout")
    XCTAssertEqual(error["message"] as? String, "request timeout")
  }

  func testErrorEnvelopeShapeIsPreserved() throws {
    let channel = try self.makeChannel { _ in
      .json(statusCode: 200, payload: OkPayload(ok: true))
    }
    defer { _ = try? channel.finish() }

    let body = String(repeating: "a", count: RemoteAPIRequestParser.maxBodyBytes + 1)
    let request = """
    POST /api/v1/displays/1/brightness HTTP/1.1\r
    Host: localhost\r
    Content-Type: application/json\r
    Content-Length: \(body.utf8.count)\r
    \r
    \(body)
    """

    try self.writeInboundFragments([request], to: channel)
    let response = try self.readSingleResponse(from: channel)

    XCTAssertEqual(response.statusCode, 413)
    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertNotNil(error["code"] as? String)
    XCTAssertNotNil(error["message"] as? String)
  }

  func testRequestLimitsRemainEnforced() throws {
    XCTAssertEqual(RemoteAPIRequestParser.maxBodyBytes, 8 * 1024)
    XCTAssertEqual(RemoteAPIRequestParser.maxRequestBytes, 16 * 1024)

    let channel = try self.makeChannel { _ in
      .json(statusCode: 200, payload: OkPayload(ok: true))
    }
    defer { _ = try? channel.finish() }

    let oversizedPath = "/" + String(repeating: "a", count: RemoteAPIRequestParser.maxRequestBytes + 32)
    let request = "GET \(oversizedPath) HTTP/1.1\r\nHost: localhost\r\n\r\n"
    try self.writeInboundFragments([request], to: channel)
    let response = try self.readSingleResponse(from: channel)

    XCTAssertEqual(response.statusCode, 413)
    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "payload_too_large")
  }

  func testConnectionHeaderNegotiatesKeepAliveAndClose() throws {
    let channel = try self.makeChannel { _ in
      .json(statusCode: 200, payload: OkPayload(ok: true))
    }
    defer { _ = try? channel.finish() }

    try self.writeInboundFragments(
      [
        "GET /api/v1/displays HTTP/1.1\r\nHost: localhost\r\n\r\n",
      ],
      to: channel
    )
    let keepAliveResponse = try self.readSingleResponse(from: channel)
    XCTAssertEqual(keepAliveResponse.headers["connection"], "keep-alive")

    try self.writeInboundFragments(
      [
        "GET /api/v1/displays HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
      ],
      to: channel
    )
    let closeResponse = try self.readSingleResponse(from: channel)
    XCTAssertEqual(closeResponse.headers["connection"], "close")

    channel.embeddedEventLoop.run()
    XCTAssertFalse(channel.isActive)
  }

  private func makeChannel(route: @escaping (RemoteHTTPRequest) -> RemoteHTTPResponse) throws -> EmbeddedChannel {
    let channel = EmbeddedChannel()
    let routeQueue = DispatchQueue(label: "RemoteNIORequestHandlerTests.route")
    try channel.pipeline.addHandler(HTTPResponseEncoder()).wait()
    try channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))).wait()
    try channel.pipeline.addHandler(
      RemoteNIORequestHandler(requestExecutionQueue: routeQueue, routeRequest: route)
    ).wait()
    return channel
  }

  private func writeInboundFragments(_ fragments: [String], to channel: EmbeddedChannel) throws {
    for fragment in fragments {
      var buffer = channel.allocator.buffer(capacity: fragment.utf8.count)
      buffer.writeString(fragment)
      try channel.writeInbound(buffer)
      channel.embeddedEventLoop.run()
    }
  }

  private func readSingleResponse(from channel: EmbeddedChannel, timeout: TimeInterval = 2.0) throws -> ParsedHTTPResponse {
    var responseBytes = Data()
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      channel.embeddedEventLoop.run()
      while var buffer = try channel.readOutbound(as: ByteBuffer.self) {
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
          responseBytes.append(contentsOf: bytes)
        }
      }

      if let response = self.parseHTTPResponses(from: responseBytes).first {
        return response
      }
      usleep(1_000)
    }

    XCTFail("Timed out waiting for response")
    throw NSError(domain: "RemoteNIORequestHandlerTests", code: 1)
  }

  private func parseHTTPResponses(from data: Data) -> [ParsedHTTPResponse] {
    var responses: [ParsedHTTPResponse] = []
    var cursor = data.startIndex

    while cursor < data.endIndex {
      guard let headerEnd = self.findHeaderEnd(in: data, from: cursor) else {
        break
      }

      let headerData = data[cursor ..< headerEnd]
      let headerText = String(decoding: headerData, as: UTF8.self)
      let headerLines = headerText.split(whereSeparator: \.isNewline).map(String.init)
      guard let statusLine = headerLines.first else {
        break
      }

      let statusLineParts = statusLine.split(separator: " ")
      guard statusLineParts.count >= 2, let statusCode = Int(statusLineParts[1]) else {
        break
      }

      var headers: [String: String] = [:]
      for line in headerLines.dropFirst() {
        guard let separatorIndex = line.firstIndex(of: ":") else {
          continue
        }
        let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        headers[key] = value
      }

      let contentLength = Int(headers["content-length"] ?? "0") ?? 0
      let bodyEnd = headerEnd + contentLength
      guard bodyEnd <= data.endIndex else {
        break
      }

      let body = Data(data[headerEnd ..< bodyEnd])
      responses.append(.init(statusCode: statusCode, headers: headers, body: body))
      cursor = bodyEnd
    }

    return responses
  }

  private func findHeaderEnd(in data: Data, from start: Data.Index) -> Data.Index? {
    if let range = data.range(of: Data([13, 10, 13, 10]), options: [], in: start ..< data.endIndex) {
      return range.upperBound
    }
    if let range = data.range(of: Data([10, 10]), options: [], in: start ..< data.endIndex) {
      return range.upperBound
    }
    return nil
  }
}
