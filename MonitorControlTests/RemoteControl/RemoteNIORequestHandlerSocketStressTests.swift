import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import RemoteControlCore

final class RemoteNIORequestHandlerSocketStressTests: XCTestCase {
  private struct OkPayload: Codable {
    let ok: Bool
  }

  private struct ParsedHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
  }

  func testSocketKeepAliveBurstDoesNotResetOrTimeout() throws {
    try self.withLiveServer(readTimeout: .seconds(5)) { port in
      let socket = try self.connectSocket(port: port)
      defer { _ = close(socket) }

      var readBuffer = Data()
      for index in 0 ..< 1000 {
        let request: String
        if index.isMultiple(of: 2) {
          request = "GET /api/v1/displays HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n"
        } else {
          request =
            "POST /api/v1/displays/1/brightness HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 12\r\nConnection: keep-alive\r\n\r\n{\"value\":70}"
        }

        try self.sendAll(request, socket: socket)
        let response = try self.readResponse(socket: socket, buffer: &readBuffer)
        XCTAssertEqual(response.statusCode, 200, "request index \(index)")
      }

      let closeRequest = "GET /api/v1/displays HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
      try self.sendAll(closeRequest, socket: socket)
      let closeResponse = try self.readResponse(socket: socket, buffer: &readBuffer)
      XCTAssertEqual(closeResponse.statusCode, 200)
      XCTAssertEqual(closeResponse.headers["connection"], "close")
      XCTAssertTrue(self.waitForPeerClose(socket: socket, timeout: 1.0))
    }
  }

  func testSocketIncompleteRequestTimesOutWith408Envelope() throws {
    try self.withLiveServer(readTimeout: .milliseconds(250)) { port in
      let socket = try self.connectSocket(port: port)
      defer { _ = close(socket) }

      var readBuffer = Data()
      let partialRequest =
        "POST /api/v1/displays/1/brightness HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 12\r\nConnection: keep-alive\r\n\r\n{\"value\":"

      try self.sendAll(partialRequest, socket: socket)
      usleep(350_000)

      let response = try self.readResponse(socket: socket, buffer: &readBuffer)
      XCTAssertEqual(response.statusCode, 408)

      let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
      let error = try XCTUnwrap(payload["error"] as? [String: Any])
      XCTAssertEqual(error["code"] as? String, "request_timeout")
      XCTAssertEqual(error["message"] as? String, "request timeout")
    }
  }

  private func withLiveServer(
    readTimeout: TimeAmount,
    run: (Int) throws -> Void
  ) throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let routeQueue = DispatchQueue(label: "RemoteNIORequestHandlerSocketStressTests.route")

    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
      .childChannelInitializer { channel in
        channel.pipeline.addHandler(IdleStateHandler(readTimeout: readTimeout)).flatMap {
          channel.pipeline.addHandler(HTTPResponseEncoder())
        }.flatMap {
          channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)))
        }.flatMap {
          channel.pipeline.addHandler(
            RemoteNIORequestHandler(
              requestExecutionQueue: routeQueue,
              routeRequest: { _ in .json(statusCode: 200, payload: OkPayload(ok: true)) }
            )
          )
        }
      }

    let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
    defer {
      try? channel.close(mode: .all).wait()
      try? group.syncShutdownGracefully()
    }

    guard let port = channel.localAddress?.port else {
      XCTFail("missing bound port")
      return
    }

    try run(Int(port))
  }

  private func connectSocket(port: Int) throws -> Int32 {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else {
      throw NSError(domain: "RemoteNIORequestHandlerSocketStressTests", code: Int(errno), userInfo: nil)
    }

    var noSigPipe: Int32 = 1
    _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_in()
#if !os(Linux)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

    let connectResult = withUnsafePointer(to: &address) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        Darwin.connect(socket, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }

    guard connectResult == 0 else {
      let code = errno
      _ = close(socket)
      throw NSError(domain: "RemoteNIORequestHandlerSocketStressTests", code: Int(code), userInfo: nil)
    }

    return socket
  }

  private func sendAll(_ request: String, socket: Int32) throws {
    let bytes = Array(request.utf8)
    var sent = 0
    while sent < bytes.count {
      let writeCount = bytes.withUnsafeBytes { pointer -> Int in
        guard let base = pointer.baseAddress else {
          return -1
        }
        return Darwin.send(socket, base.advanced(by: sent), bytes.count - sent, 0)
      }

      if writeCount > 0 {
        sent += writeCount
        continue
      }

      if writeCount < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        continue
      }

      throw NSError(domain: "RemoteNIORequestHandlerSocketStressTests", code: Int(errno), userInfo: nil)
    }
  }

  private func readResponse(socket: Int32, buffer: inout Data) throws -> ParsedHTTPResponse {
    let deadline = Date().addingTimeInterval(2.0)

    while Date() < deadline {
      if let response = self.popResponse(from: &buffer) {
        return response
      }

      var chunk = [UInt8](repeating: 0, count: 4096)
      let readCount = Darwin.recv(socket, &chunk, chunk.count, 0)
      if readCount > 0 {
        buffer.append(chunk, count: Int(readCount))
        continue
      }
      if readCount == 0 {
        throw NSError(domain: "RemoteNIORequestHandlerSocketStressTests", code: 1001, userInfo: nil)
      }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        continue
      }
      throw NSError(domain: "RemoteNIORequestHandlerSocketStressTests", code: Int(errno), userInfo: nil)
    }

    throw NSError(domain: "RemoteNIORequestHandlerSocketStressTests", code: 1002, userInfo: nil)
  }

  private func popResponse(from buffer: inout Data) -> ParsedHTTPResponse? {
    guard let headerEnd = self.findHeaderEnd(in: buffer, from: buffer.startIndex) else {
      return nil
    }

    let headerData = buffer[buffer.startIndex ..< headerEnd]
    let headerText = String(decoding: headerData, as: UTF8.self)
    let headerLines = headerText.split(whereSeparator: \.isNewline).map(String.init)
    guard let statusLine = headerLines.first else {
      return nil
    }

    let statusLineParts = statusLine.split(separator: " ")
    guard statusLineParts.count >= 2, let statusCode = Int(statusLineParts[1]) else {
      return nil
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
    guard bodyEnd <= buffer.endIndex else {
      return nil
    }

    let body = Data(buffer[headerEnd ..< bodyEnd])
    buffer.removeSubrange(buffer.startIndex ..< bodyEnd)
    return ParsedHTTPResponse(statusCode: statusCode, headers: headers, body: body)
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

  private func waitForPeerClose(socket: Int32, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var scratch = [UInt8](repeating: 0, count: 1024)

    while Date() < deadline {
      let readCount = Darwin.recv(socket, &scratch, scratch.count, 0)
      if readCount == 0 {
        return true
      }
      if readCount > 0 {
        continue
      }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        continue
      }
      return false
    }

    return false
  }
}
