//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation

enum RemoteDisplayControllerError: Error {
  case displayNotFound(displayId: UInt32)
  case invalidValue(message: String)
  case unsupportedOperation(message: String, displayIds: [UInt32])
  case serviceUnavailable(message: String)
  case operationFailed(message: String)
}

final class RemoteDisplayController {
  static let shared = RemoteDisplayController()

  private init() {}

  func getDisplays() throws -> [RemoteDisplayStatus] {
    try self.performOnMain {
      DisplayManager.shared.getAllDisplays().map { self.buildStatus(for: $0) }
    }
  }

  func setBrightness(displayId: UInt32, valuePercent: Int) throws -> RemoteDisplayStatus {
    guard (0 ... 100).contains(valuePercent) else {
      throw RemoteDisplayControllerError.invalidValue(message: "value must be between 0 and 100")
    }
    return try self.performOnMain {
      try self.ensureServiceAvailable()
      guard let display = DisplayManager.shared.getAllDisplays().first(where: { $0.identifier == displayId }), !display.isDummy else {
        throw RemoteDisplayControllerError.displayNotFound(displayId: displayId)
      }
      guard display.setBrightness(Float(valuePercent) / 100.0) else {
        throw RemoteDisplayControllerError.operationFailed(message: "failed to set brightness")
      }
      return self.buildStatus(for: display)
    }
  }

  func setBrightnessForAll(valuePercent: Int) throws -> [RemoteDisplayStatus] {
    guard (0 ... 100).contains(valuePercent) else {
      throw RemoteDisplayControllerError.invalidValue(message: "value must be between 0 and 100")
    }
    return try self.performOnMain {
      try self.ensureServiceAvailable()
      var statuses: [RemoteDisplayStatus] = []
      for display in DisplayManager.shared.getAllDisplays() where !display.isDummy {
        guard display.setBrightness(Float(valuePercent) / 100.0) else {
          throw RemoteDisplayControllerError.operationFailed(message: "failed to set brightness for display \(display.identifier)")
        }
        statuses.append(self.buildStatus(for: display))
      }
      return statuses
    }
  }

  func setPower(displayId: UInt32, state: RemoteRequestedPowerState) throws -> UInt32 {
    try self.performOnMain {
      try self.ensureServiceAvailable()
      guard let display = DisplayManager.shared.getAllDisplays().first(where: { $0.identifier == displayId }), !display.isDummy else {
        throw RemoteDisplayControllerError.displayNotFound(displayId: displayId)
      }
      switch state {
      case .off:
        self.rememberBrightnessForSimulatedWake(display: display)
        guard display.setBrightness(0) else {
          throw RemoteDisplayControllerError.operationFailed(message: "failed to set simulated power off")
        }
        display.savePref(true, key: .remoteControlSimulatedPowerOff)
      case .on:
        let restoreBrightness = self.restoreBrightnessAfterSimulatedWake(display: display)
        guard display.setBrightness(restoreBrightness) else {
          throw RemoteDisplayControllerError.operationFailed(message: "failed to restore brightness on simulated power on")
        }
        display.savePref(false, key: .remoteControlSimulatedPowerOff)
      }
      return display.identifier
    }
  }

  func setPowerForAll(state: RemoteRequestedPowerState) throws -> [UInt32] {
    try self.performOnMain {
      try self.ensureServiceAvailable()
      let displays = DisplayManager.shared.getAllDisplays().filter { !$0.isDummy }
      for display in displays {
        switch state {
        case .off:
          self.rememberBrightnessForSimulatedWake(display: display)
          guard display.setBrightness(0) else {
            throw RemoteDisplayControllerError.operationFailed(message: "failed to set simulated power off for display \(display.identifier)")
          }
          display.savePref(true, key: .remoteControlSimulatedPowerOff)
        case .on:
          let restoreBrightness = self.restoreBrightnessAfterSimulatedWake(display: display)
          guard display.setBrightness(restoreBrightness) else {
            throw RemoteDisplayControllerError.operationFailed(message: "failed to restore brightness on simulated power on for display \(display.identifier)")
          }
          display.savePref(false, key: .remoteControlSimulatedPowerOff)
        }
      }
      return displays.map(\.identifier)
    }
  }

  private func ensureServiceAvailable() throws {
    if app.sleepID != 0 || app.reconfigureID != 0 {
      throw RemoteDisplayControllerError.serviceUnavailable(message: "display service is temporarily unavailable")
    }
  }

  private func buildStatus(for display: Display) -> RemoteDisplayStatus {
    let friendlyName = display.readPrefAsString(key: .friendlyName).isEmpty ? display.name : display.readPrefAsString(key: .friendlyName)
    let brightnessValue = max(0, min(100, Int((display.getBrightness() * 100).rounded())))
    let type: RemoteDisplayType = display is AppleDisplay ? .apple : .other

    let hasPowerControl = !display.isDummy
    let powerState: RemotePowerState = display.isDummy ? .unknown : (display.readPrefAsBool(key: .remoteControlSimulatedPowerOff) ? .off : .on)

    let brightnessCapability = !display.isDummy && !display.readPrefAsBool(key: .unavailableDDC, for: .brightness)
    let capabilities = RemoteDisplayCapabilities(brightness: brightnessCapability, power: hasPowerControl)
    return RemoteDisplayStatus(
      id: display.identifier,
      name: display.name,
      friendlyName: friendlyName,
      type: type,
      isVirtual: display.isVirtual,
      isDummy: display.isDummy,
      brightness: brightnessValue,
      powerState: powerState,
      capabilities: capabilities
    )
  }

  private func rememberBrightnessForSimulatedWake(display: Display) {
    let currentBrightness = max(0, min(1, display.getBrightness()))
    if currentBrightness > 0.001 {
      display.savePref(currentBrightness, key: .remoteControlSimulatedPowerRestoreBrightness)
    } else if !display.prefExists(key: .remoteControlSimulatedPowerRestoreBrightness) {
      display.savePref(Float(0.5), key: .remoteControlSimulatedPowerRestoreBrightness)
    }
  }

  private func restoreBrightnessAfterSimulatedWake(display: Display) -> Float {
    let restoreBrightness = display.prefExists(key: .remoteControlSimulatedPowerRestoreBrightness) ? display.readPrefAsFloat(key: .remoteControlSimulatedPowerRestoreBrightness) : 0.5
    return max(0.01, min(1, restoreBrightness))
  }

  private func performOnMain<T>(_ block: @escaping () throws -> T) throws -> T {
    if Thread.isMainThread {
      return try block()
    }

    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    DispatchQueue.main.async {
      result = Result(catching: block)
      semaphore.signal()
    }
    semaphore.wait()
    guard let result else {
      throw RemoteDisplayControllerError.operationFailed(message: "unable to execute operation")
    }
    return try result.get()
  }
}
