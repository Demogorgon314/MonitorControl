//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation
import NIOCore
import NIOHTTP1

final class RemoteNIORequestHandler: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private struct ReceivedRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let keepAlive: Bool
    let headerBytes: Int
    var body = Data()
    var bodyBytes = 0
  }

  private enum State {
    case idle
    case receiving(ReceivedRequest)
    case responding
  }

  private let requestExecutionQueue: DispatchQueue
  private let routeRequest: (RemoteHTTPRequest) -> RemoteHTTPResponse
  private var state: State = .idle

  init(
    requestExecutionQueue: DispatchQueue,
    routeRequest: @escaping (RemoteHTTPRequest) -> RemoteHTTPResponse
  ) {
    self.requestExecutionQueue = requestExecutionQueue
    self.routeRequest = routeRequest
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let part = self.unwrapInboundIn(data)
    switch part {
    case let .head(head):
      self.handleHead(head, context: context)
    case var .body(bodyPart):
      self.handleBody(&bodyPart, context: context)
    case .end:
      self.handleEnd(context: context)
    }
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    guard let idleEvent = event as? IdleStateHandler.IdleStateEvent else {
      context.fireUserInboundEventTriggered(event)
      return
    }

    guard idleEvent == .read else {
      context.fireUserInboundEventTriggered(event)
      return
    }

    switch self.state {
    case .idle:
      context.close(promise: nil)
    case .receiving:
      self.failRequest(
        response: .error(statusCode: 408, code: "request_timeout", message: "request timeout"),
        context: context
      )
    case .responding:
      break
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    context.close(promise: nil)
  }

  func channelInactive(context: ChannelHandlerContext) {
    self.state = .idle
    context.fireChannelInactive()
  }

  private func handleHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
    guard case .idle = self.state else {
      self.failRequest(
        response: .error(statusCode: 503, code: "service_unavailable", message: "request is already in progress"),
        context: context
      )
      return
    }

    let headers = self.normalizedHeaders(from: head)
    let headerBytes = self.estimatedHeaderBytes(for: head)
    guard headerBytes <= RemoteAPIRequestParser.maxRequestBytes else {
      self.failRequest(
        response: .error(statusCode: 413, code: "payload_too_large", message: "request size exceeds limit"),
        context: context
      )
      return
    }

    if let rawContentLength = headers["content-length"] {
      guard let parsed = Int(rawContentLength), parsed >= 0 else {
        self.failRequest(
          response: .error(statusCode: 400, code: "bad_request", message: "invalid content-length"),
          context: context
        )
        return
      }
      guard parsed <= RemoteAPIRequestParser.maxBodyBytes else {
        self.failRequest(
          response: .error(statusCode: 413, code: "payload_too_large", message: "body exceeds 8192 bytes"),
          context: context
        )
        return
      }
      guard headerBytes + parsed <= RemoteAPIRequestParser.maxRequestBytes else {
        self.failRequest(
          response: .error(statusCode: 413, code: "payload_too_large", message: "request size exceeds limit"),
          context: context
        )
        return
      }
    }

    self.state = .receiving(
      ReceivedRequest(
        method: head.method.rawValue.uppercased(),
        path: head.uri,
        headers: headers,
        keepAlive: head.isKeepAlive,
        headerBytes: headerBytes
      )
    )
  }

  private func handleBody(_ bodyPart: inout ByteBuffer, context: ChannelHandlerContext) {
    guard case var .receiving(receivedRequest) = self.state else {
      return
    }

    let readableBytes = bodyPart.readableBytes
    receivedRequest.bodyBytes += readableBytes
    guard receivedRequest.bodyBytes <= RemoteAPIRequestParser.maxBodyBytes else {
      self.failRequest(
        response: .error(statusCode: 413, code: "payload_too_large", message: "body exceeds 8192 bytes"),
        context: context
      )
      return
    }
    guard receivedRequest.headerBytes + receivedRequest.bodyBytes <= RemoteAPIRequestParser.maxRequestBytes else {
      self.failRequest(
        response: .error(statusCode: 413, code: "payload_too_large", message: "request size exceeds limit"),
        context: context
      )
      return
    }

    if let bytes = bodyPart.readBytes(length: readableBytes) {
      receivedRequest.body.append(contentsOf: bytes)
    }
    self.state = .receiving(receivedRequest)
  }

  private func handleEnd(context: ChannelHandlerContext) {
    guard case let .receiving(receivedRequest) = self.state else {
      return
    }

    self.state = .responding

    let request = RemoteHTTPRequest(
      method: receivedRequest.method,
      path: receivedRequest.path,
      headers: receivedRequest.headers,
      body: receivedRequest.body
    )
    let keepAlive = receivedRequest.keepAlive

    self.requestExecutionQueue.async { [weak self] in
      guard let self else {
        return
      }
      let response = self.routeRequest(request)
      context.eventLoop.execute {
        self.writeResponse(
          response,
          keepAliveRequested: keepAlive,
          closeAfterWrite: false,
          context: context
        )
      }
    }
  }

  private func failRequest(response: RemoteHTTPResponse, context: ChannelHandlerContext) {
    self.state = .responding
    self.writeResponse(response, keepAliveRequested: false, closeAfterWrite: true, context: context)
  }

  private func writeResponse(
    _ response: RemoteHTTPResponse,
    keepAliveRequested: Bool,
    closeAfterWrite: Bool,
    context: ChannelHandlerContext
  ) {
    let shouldKeepAlive = keepAliveRequested && !closeAfterWrite

    var responseHeaders = HTTPHeaders()
    for (name, value) in response.headers {
      responseHeaders.replaceOrAdd(name: name, value: value)
    }
    responseHeaders.replaceOrAdd(name: "Content-Length", value: String(response.body.count))
    responseHeaders.replaceOrAdd(name: "Connection", value: shouldKeepAlive ? "keep-alive" : "close")

    let responseHead = HTTPResponseHead(
      version: .http1_1,
      status: .init(statusCode: response.statusCode, reasonPhrase: self.reasonPhrase(response.statusCode)),
      headers: responseHeaders
    )

    context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
    var bodyBuffer = context.channel.allocator.buffer(capacity: response.body.count)
    bodyBuffer.writeBytes(response.body)
    context.write(self.wrapOutboundOut(.body(.byteBuffer(bodyBuffer))), promise: nil)

    let writePromise = context.eventLoop.makePromise(of: Void.self)
    context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: writePromise)
    writePromise.futureResult.whenComplete { [weak self, weak context] result in
      guard let self, let context else {
        return
      }

      guard case .success = result else {
        context.close(promise: nil)
        return
      }

      if shouldKeepAlive {
        self.state = .idle
      } else {
        context.close(promise: nil)
      }
    }
  }

  private func normalizedHeaders(from head: HTTPRequestHead) -> [String: String] {
    var headers: [String: String] = [:]
    for header in head.headers {
      let key = header.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if key.isEmpty {
        continue
      }
      headers[key] = header.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return headers
  }

  private func estimatedHeaderBytes(for head: HTTPRequestHead) -> Int {
    var total = "\(head.method.rawValue) \(head.uri) HTTP/\(head.version.major).\(head.version.minor)\r\n".utf8.count
    for header in head.headers {
      total += header.name.utf8.count + 2 + header.value.utf8.count + 2
    }
    return total + 2
  }

  private func reasonPhrase(_ statusCode: Int) -> String {
    switch statusCode {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 408: return "Request Timeout"
    case 409: return "Conflict"
    case 413: return "Payload Too Large"
    case 422: return "Unprocessable Entity"
    case 500: return "Internal Server Error"
    case 503: return "Service Unavailable"
    default: return "OK"
    }
  }
}
