//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation

enum RemoteInputSourceCatalog {
  static let defaultSources: [RemoteInputSource] = [
    RemoteInputSource(code: 17, name: "HDMI-1"),
    RemoteInputSource(code: 18, name: "HDMI-2"),
    RemoteInputSource(code: 15, name: "DP-1"),
    RemoteInputSource(code: 16, name: "DP-2"),
    RemoteInputSource(code: 3, name: "DVI-1"),
    RemoteInputSource(code: 4, name: "DVI-2"),
    RemoteInputSource(code: 1, name: "VGA-1"),
    RemoteInputSource(code: 2, name: "VGA-2"),
  ]

  private static let aliases: [String: Int] = [
    "hdmi": 17,
    "hdmi1": 17,
    "hdmi-1": 17,
    "hdmi2": 18,
    "hdmi-2": 18,
    "dp": 15,
    "dp1": 15,
    "dp-1": 15,
    "displayport": 15,
    "displayport1": 15,
    "displayport-1": 15,
    "dp2": 16,
    "dp-2": 16,
    "displayport2": 16,
    "displayport-2": 16,
    "dvi": 3,
    "dvi1": 3,
    "dvi-1": 3,
    "dvi2": 4,
    "dvi-2": 4,
    "vga": 1,
    "vga1": 1,
    "vga-1": 1,
    "vga2": 2,
    "vga-2": 2,
  ]

  private static let namesByCode: [Int: String] = {
    var dictionary: [Int: String] = [:]
    for source in Self.defaultSources {
      dictionary[source.code] = source.name
    }
    return dictionary
  }()

  static func source(for code: UInt16) -> RemoteInputSource {
    let intCode = Int(code)
    if let name = Self.namesByCode[intCode] {
      return RemoteInputSource(code: intCode, name: name)
    }
    return RemoteInputSource(code: intCode, name: "UNKNOWN-\(intCode)")
  }

  static func code(forName rawName: String) -> UInt16? {
    let normalized = rawName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
      .replacingOccurrences(of: " ", with: "")

    guard !normalized.isEmpty else {
      return nil
    }

    if let source = Self.defaultSources.first(where: { $0.name.lowercased() == normalized }) {
      return UInt16(source.code)
    }

    if let code = Self.aliases[normalized] {
      return UInt16(code)
    }

    return nil
  }
}
