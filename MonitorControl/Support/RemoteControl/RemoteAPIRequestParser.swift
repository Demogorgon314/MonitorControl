//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation

enum RemoteAPIRequestParserResult {
  case incomplete
  case ready(RemoteHTTPRequest)
  case failure(RemoteHTTPResponse)
}

final class RemoteAPIRequestParser {
  static let maxBodyBytes = 8 * 1024
  static let maxRequestBytes = 16 * 1024

  func parse(buffer: Data) -> RemoteAPIRequestParserResult {
    if buffer.count > Self.maxRequestBytes {
      return .failure(.error(statusCode: 413, code: "payload_too_large", message: "request size exceeds limit"))
    }

    guard let headerEnd = self.findHeaderEnd(in: buffer) else {
      return .incomplete
    }

    let headerData = buffer.prefix(headerEnd)
    let headerText = String(decoding: headerData, as: UTF8.self)
    let lines = headerText.split(whereSeparator: \.isNewline).map(String.init)
    guard let requestLine = lines.first else {
      return .failure(.error(statusCode: 400, code: "bad_request", message: "missing request line"))
    }

    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2 else {
      return .failure(.error(statusCode: 400, code: "bad_request", message: "invalid request line"))
    }

    let method = String(parts[0]).uppercased()
    let path = String(parts[1])

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let separatorIndex = line.firstIndex(of: ":") else {
        continue
      }
      let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !key.isEmpty {
        headers[key] = value
      }
    }

    let contentLength: Int
    if let rawValue = headers["content-length"] {
      guard let parsed = Int(rawValue), parsed >= 0 else {
        return .failure(.error(statusCode: 400, code: "bad_request", message: "invalid content-length"))
      }
      contentLength = parsed
    } else {
      contentLength = 0
    }

    guard contentLength <= Self.maxBodyBytes else {
      return .failure(.error(statusCode: 413, code: "payload_too_large", message: "body exceeds 8192 bytes"))
    }

    let requestTotalLength = headerEnd + contentLength
    if requestTotalLength > Self.maxRequestBytes {
      return .failure(.error(statusCode: 413, code: "payload_too_large", message: "request size exceeds limit"))
    }
    guard buffer.count >= requestTotalLength else {
      return .incomplete
    }

    let bodyRange = headerEnd ..< requestTotalLength
    let body = Data(buffer[bodyRange])
    let request = RemoteHTTPRequest(method: method, path: path, headers: headers, body: body)
    return .ready(request)
  }

  private func findHeaderEnd(in buffer: Data) -> Int? {
    if let range = buffer.range(of: Data([13, 10, 13, 10])) {
      return range.upperBound
    }
    if let range = buffer.range(of: Data([10, 10])) {
      return range.upperBound
    }
    return nil
  }
}
