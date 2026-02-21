//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Darwin
import Foundation
import os.log

enum RemoteControlServerStatus: Equatable {
  case stopped
  case running(port: UInt16)
  case failed(message: String)
}

final class RemoteControlServer {
  private let queue = DispatchQueue(label: "RemoteControlServer.queue")
  private let clientQueue = DispatchQueue(label: "RemoteControlServer.client", attributes: .concurrent)
  private let parser = RemoteAPIRequestParser()
  private var listenFileDescriptor: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var router: RemoteAPIRouter?

  var statusChangeHandler: ((RemoteControlServerStatus) -> Void)?

  private(set) var status: RemoteControlServerStatus = .stopped {
    didSet {
      self.statusChangeHandler?(self.status)
    }
  }

  func start(port: UInt16, tokenProvider: @escaping () -> String) throws {
    self.stop()

    self.router = RemoteAPIRouter(displayController: .shared, tokenProvider: tokenProvider)

    let serverSocket = socket(AF_INET, SOCK_STREAM, 0)
    guard serverSocket >= 0 else {
      self.status = .failed(message: "unable to create server socket")
      throw NSError(domain: "RemoteControlServer", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "unable to create server socket"])
    }

    var reuseAddress: Int32 = 1
    if setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size)) < 0 {
      close(serverSocket)
      self.status = .failed(message: "unable to configure server socket")
      throw NSError(domain: "RemoteControlServer", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "unable to configure server socket"])
    }

    var address = sockaddr_in()
    #if !os(Linux)
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        bind(serverSocket, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      let errorMessage = String(cString: strerror(errno))
      close(serverSocket)
      self.status = .failed(message: "unable to bind socket: \(errorMessage)")
      throw NSError(domain: "RemoteControlServer", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "unable to bind socket"])
    }

    guard listen(serverSocket, SOMAXCONN) == 0 else {
      let errorMessage = String(cString: strerror(errno))
      close(serverSocket)
      self.status = .failed(message: "unable to listen on socket: \(errorMessage)")
      throw NSError(domain: "RemoteControlServer", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "unable to listen on socket"])
    }
    let socketFlags = fcntl(serverSocket, F_GETFL, 0)
    _ = fcntl(serverSocket, F_SETFL, socketFlags | O_NONBLOCK)

    self.listenFileDescriptor = serverSocket
    self.acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: self.queue)
    self.acceptSource?.setEventHandler { [weak self] in
      self?.acceptConnections()
    }
    self.acceptSource?.setCancelHandler { [weak self] in
      guard let self, self.listenFileDescriptor >= 0 else {
        return
      }
      close(self.listenFileDescriptor)
      self.listenFileDescriptor = -1
    }
    self.acceptSource?.resume()
    self.status = .running(port: port)
    os_log("Remote HTTP server is listening on port %{public}@", type: .info, String(port))
  }

  func stop() {
    self.acceptSource?.cancel()
    self.acceptSource = nil
    if self.listenFileDescriptor >= 0 {
      close(self.listenFileDescriptor)
      self.listenFileDescriptor = -1
    }
    self.router = nil
    self.status = .stopped
  }

  private func acceptConnections() {
    guard self.listenFileDescriptor >= 0 else {
      return
    }
    while true {
      var addressStorage = sockaddr_storage()
      var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let clientSocket = withUnsafeMutablePointer(to: &addressStorage) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
          accept(self.listenFileDescriptor, socketAddress, &addressLength)
        }
      }
      if clientSocket < 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK {
          break
        }
        if errno == EINTR {
          continue
        }
        break
      }
      self.clientQueue.async {
        self.handleClient(socket: clientSocket)
      }
    }
  }

  private func handleClient(socket: Int32) {
    guard let router = self.router else {
      close(socket)
      return
    }

    defer {
      close(socket)
    }

    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    var noSigPipe: Int32 = 1
    _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var buffer = Data()
    let chunkSize = 2048

    while true {
      var chunk = [UInt8](repeating: 0, count: chunkSize)
      let receivedCount = recv(socket, &chunk, chunk.count, 0)
      if receivedCount > 0 {
        buffer.append(chunk, count: Int(receivedCount))
        switch self.parser.parse(buffer: buffer) {
        case .incomplete:
          continue
        case let .ready(request):
          self.sendResponse(self.serializeResponse(router.route(request)), socket: socket)
          return
        case let .failure(response):
          self.sendResponse(self.serializeResponse(response), socket: socket)
          return
        }
      } else if receivedCount == 0 {
        return
      } else {
        if errno == EAGAIN || errno == EWOULDBLOCK {
          self.sendResponse(self.serializeResponse(.error(statusCode: 400, code: "bad_request", message: "request timeout")), socket: socket)
        }
        return
      }
    }
  }

  private func sendResponse(_ responseData: Data, socket: Int32) {
    var sentBytes = 0
    responseData.withUnsafeBytes { buffer in
      guard let pointer = buffer.baseAddress else {
        return
      }
      while sentBytes < responseData.count {
        let remainingBytes = responseData.count - sentBytes
        let writeResult = send(socket, pointer.advanced(by: sentBytes), remainingBytes, 0)
        if writeResult <= 0 {
          break
        }
        sentBytes += Int(writeResult)
      }
    }
  }

  private func serializeResponse(_ response: RemoteHTTPResponse) -> Data {
    var headers = response.headers
    headers["Content-Length"] = String(response.body.count)
    headers["Connection"] = "close"

    var lines: [String] = []
    lines.append("HTTP/1.1 \(response.statusCode) \(self.reasonPhrase(response.statusCode))")
    for (header, value) in headers {
      lines.append("\(header): \(value)")
    }
    lines.append("")
    lines.append("")

    var data = Data(lines.joined(separator: "\r\n").utf8)
    data.append(response.body)
    return data
  }

  private func reasonPhrase(_ statusCode: Int) -> String {
    switch statusCode {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 409: return "Conflict"
    case 413: return "Payload Too Large"
    case 422: return "Unprocessable Entity"
    case 500: return "Internal Server Error"
    case 503: return "Service Unavailable"
    default: return "OK"
    }
  }
}
