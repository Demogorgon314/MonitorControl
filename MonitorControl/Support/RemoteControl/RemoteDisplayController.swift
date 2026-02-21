//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation

final class RemoteDisplayController: RemoteDisplayService {
  static let shared = RemoteDisplayController()

  private init() {}

  func getDisplays() throws -> [RemoteDisplayStatus] {
    try self.performOnMain {
      DisplayManager.shared.getAllDisplays().map { self.buildStatus(for: $0, refreshInputFromDDC: false) }
    }
  }

  func getInputs(displayId: UInt32) throws -> RemoteDisplayInputsResponse {
    try self.performOnMain {
      guard let display = DisplayManager.shared.getAllDisplays().first(where: { $0.identifier == displayId }), !display.isDummy else {
        throw RemoteDisplayControllerError.displayNotFound(displayId: displayId)
      }
      return RemoteDisplayInputsResponse(displayId: display.identifier, input: self.buildInputStatus(for: display, refreshFromDDC: true))
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
      return self.buildStatus(for: display, refreshInputFromDDC: false)
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
        statuses.append(self.buildStatus(for: display, refreshInputFromDDC: false))
      }
      return statuses
    }
  }

  func setVolume(displayId: UInt32, valuePercent: Int) throws -> RemoteDisplayStatus {
    guard (0 ... 100).contains(valuePercent) else {
      throw RemoteDisplayControllerError.invalidValue(message: "value must be between 0 and 100")
    }
    return try self.performOnMain {
      try self.ensureServiceAvailable()
      guard let display = DisplayManager.shared.getAllDisplays().first(where: { $0.identifier == displayId }), !display.isDummy else {
        throw RemoteDisplayControllerError.displayNotFound(displayId: displayId)
      }
      guard let otherDisplay = display as? OtherDisplay, self.canControlVolume(display: otherDisplay) else {
        throw RemoteDisplayControllerError.unsupportedOperation(message: "volume control is not supported for display \(displayId)", displayIds: [displayId])
      }
      self.applyVolume(valuePercent: valuePercent, to: otherDisplay)
      return self.buildStatus(for: otherDisplay, refreshInputFromDDC: false)
    }
  }

  func setVolumeForAll(valuePercent: Int) throws -> [RemoteDisplayStatus] {
    guard (0 ... 100).contains(valuePercent) else {
      throw RemoteDisplayControllerError.invalidValue(message: "value must be between 0 and 100")
    }
    return try self.performOnMain {
      try self.ensureServiceAvailable()
      let displays = DisplayManager.shared.getAllDisplays().filter { !$0.isDummy }
      let controllableDisplays: [OtherDisplay] = displays.compactMap { display in
        guard let otherDisplay = display as? OtherDisplay, self.canControlVolume(display: otherDisplay) else {
          return nil
        }
        return otherDisplay
      }

      if controllableDisplays.isEmpty {
        throw RemoteDisplayControllerError.unsupportedOperation(
          message: "volume control is not supported for connected displays",
          displayIds: displays.map(\.identifier)
        )
      }

      for otherDisplay in controllableDisplays {
        self.applyVolume(valuePercent: valuePercent, to: otherDisplay)
      }
      return controllableDisplays.map { self.buildStatus(for: $0, refreshInputFromDDC: false) }
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

  func setInput(displayId: UInt32, request: RemoteSetInputRequest) throws -> RemoteDisplayStatus {
    try self.performOnMain {
      try self.ensureServiceAvailable()
      guard let display = DisplayManager.shared.getAllDisplays().first(where: { $0.identifier == displayId }), !display.isDummy else {
        throw RemoteDisplayControllerError.displayNotFound(displayId: displayId)
      }
      guard let otherDisplay = display as? OtherDisplay, self.canControlInput(display: otherDisplay) else {
        throw RemoteDisplayControllerError.unsupportedOperation(message: "input source control is not supported for display \(displayId)", displayIds: [displayId])
      }

      let targetCode = try self.resolveInputCode(request: request)
      guard self.writeInputCode(display: otherDisplay, code: targetCode) else {
        throw RemoteDisplayControllerError.operationFailed(message: "failed to set input source")
      }

      otherDisplay.savePref(Int(targetCode), for: .inputSelect)
      return self.buildStatus(for: otherDisplay, refreshInputFromDDC: false)
    }
  }

  private func ensureServiceAvailable() throws {
    if app.sleepID != 0 || app.reconfigureID != 0 {
      throw RemoteDisplayControllerError.serviceUnavailable(message: "display service is temporarily unavailable")
    }
  }

  private func buildStatus(for display: Display, refreshInputFromDDC: Bool) -> RemoteDisplayStatus {
    let friendlyName = display.readPrefAsString(key: .friendlyName).isEmpty ? display.name : display.readPrefAsString(key: .friendlyName)
    let brightnessValue = max(0, min(100, Int((display.getBrightness() * 100).rounded())))
    let volumeValue = self.getVolumeValue(display: display)
    let type: RemoteDisplayType = display is AppleDisplay ? .apple : .other

    let hasPowerControl = !display.isDummy
    let powerState: RemotePowerState = display.isDummy ? .unknown : (display.readPrefAsBool(key: .remoteControlSimulatedPowerOff) ? .off : .on)

    let brightnessCapability = !display.isDummy && !display.readPrefAsBool(key: .unavailableDDC, for: .brightness)
    let volumeCapability = self.canControlVolume(display: display)
    let capabilities = RemoteDisplayCapabilities(brightness: brightnessCapability, volume: volumeCapability, power: hasPowerControl)
    let input = self.buildInputStatus(for: display, refreshFromDDC: refreshInputFromDDC)
    return RemoteDisplayStatus(
      id: display.identifier,
      name: display.name,
      friendlyName: friendlyName,
      type: type,
      isVirtual: display.isVirtual,
      isDummy: display.isDummy,
      brightness: brightnessValue,
      volume: volumeValue,
      powerState: powerState,
      capabilities: capabilities,
      input: input
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

  private func canControlVolume(display: Display) -> Bool {
    guard let otherDisplay = display as? OtherDisplay else {
      return false
    }
    return self.canControlVolume(display: otherDisplay)
  }

  private func canControlVolume(display: OtherDisplay) -> Bool {
    !display.isDummy && !display.isSw() && !display.readPrefAsBool(key: .unavailableDDC, for: .audioSpeakerVolume)
  }

  private func canControlInput(display: OtherDisplay) -> Bool {
    !display.isDummy && !display.isSw() && !display.readPrefAsBool(key: .unavailableDDC, for: .inputSelect)
  }

  private func getVolumeValue(display: Display) -> Int? {
    guard let otherDisplay = display as? OtherDisplay, self.canControlVolume(display: otherDisplay) else {
      return nil
    }
    let value = otherDisplay.setupSliderCurrentValue(command: .audioSpeakerVolume)
    return max(0, min(100, Int((value * 100).rounded())))
  }

  private func applyVolume(valuePercent: Int, to display: OtherDisplay) {
    let normalized = max(0, min(1, Float(valuePercent) / 100.0))
    let isMuteTransition = (display.readPrefAsInt(for: .audioMuteScreenBlank) == 1 && normalized > 0) || (display.readPrefAsInt(for: .audioMuteScreenBlank) != 1 && normalized == 0)
    if isMuteTransition {
      display.toggleMute(fromVolumeSlider: true)
    }
    if !display.readPrefAsBool(key: .enableMuteUnmute) || normalized != 0 {
      display.writeDDCValues(command: .audioSpeakerVolume, value: display.convValueToDDC(for: .audioSpeakerVolume, from: normalized))
    }
    display.savePref(normalized, for: .audioSpeakerVolume)
  }

  private func buildInputStatus(for display: Display, refreshFromDDC: Bool) -> RemoteDisplayInputStatus {
    guard let otherDisplay = display as? OtherDisplay, self.canControlInput(display: otherDisplay) else {
      return RemoteDisplayInputStatus(supported: false, bestEffort: true, current: nil, available: [])
    }

    var available = RemoteInputSourceCatalog.defaultSources
    var currentSource: RemoteInputSource?
    if let currentCode = self.readCurrentInputCode(display: otherDisplay, refreshFromDDC: refreshFromDDC) {
      currentSource = RemoteInputSourceCatalog.source(for: currentCode)
      if let currentSource, !available.contains(where: { $0.code == currentSource.code }) {
        available.insert(currentSource, at: 0)
      }
    }

    return RemoteDisplayInputStatus(supported: true, bestEffort: true, current: currentSource, available: available)
  }

  private func readCurrentInputCode(display: OtherDisplay, refreshFromDDC: Bool) -> UInt16? {
    if refreshFromDDC {
      if Arm64DDC.isArm64, display.arm64ddc {
        if let inputValue = self.probeArm64InputCode(display: display) {
          display.savePref(Int(inputValue), for: .inputSelect)
          return inputValue
        }
      } else if let inputValue = display.readDDCValues(for: .inputSelect, tries: 1, minReplyDelay: nil)?.current,
                (0 ... 255).contains(inputValue) {
        display.savePref(Int(inputValue), for: .inputSelect)
        return inputValue
      }
    }

    if display.prefExists(for: .inputSelect) {
      let value = display.readPrefAsInt(for: .inputSelect)
      if (0 ... 255).contains(value) {
        return UInt16(value)
      }
    }

    return nil
  }

  private func resolveInputCode(request: RemoteSetInputRequest) throws -> UInt16 {
    let providedCode: UInt16?
    if let rawCode = request.code {
      guard (0 ... 255).contains(rawCode) else {
        throw RemoteDisplayControllerError.invalidValue(message: "input code must be between 0 and 255")
      }
      providedCode = UInt16(rawCode)
    } else {
      providedCode = nil
    }

    let providedNameCode: UInt16?
    if let rawName = request.name, !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard let parsedCode = RemoteInputSourceCatalog.code(forName: rawName) else {
        throw RemoteDisplayControllerError.invalidValue(message: "unsupported input source name")
      }
      providedNameCode = parsedCode
    } else {
      providedNameCode = nil
    }

    guard providedCode != nil || providedNameCode != nil else {
      throw RemoteDisplayControllerError.invalidValue(message: "request must include input name or code")
    }

    if let providedCode, let providedNameCode, providedCode != providedNameCode {
      throw RemoteDisplayControllerError.invalidValue(message: "input name and code do not match")
    }

    return providedCode ?? providedNameCode ?? 0
  }

  private func writeInputCode(display: OtherDisplay, code: UInt16) -> Bool {
    var controlCodes = display.getRemapControlCodes(command: .inputSelect)
    if controlCodes.isEmpty {
      controlCodes = [Command.inputSelect.rawValue]
    }

    var didSucceed = false
    DisplayManager.shared.globalDDCQueue.sync {
      for controlCode in controlCodes {
        let writeSucceeded: Bool
        if Arm64DDC.isArm64 {
          if display.arm64ddc {
            writeSucceeded = Arm64DDC.write(service: display.arm64avService, command: controlCode, value: code) ||
              Arm64DDC.write(service: display.arm64avService, command: controlCode, value: code, dataAddress: ARM64_DDC_ALTERNATE_DATA_ADDRESS)
          } else {
            writeSucceeded = false
          }
        } else {
          writeSucceeded = display.ddc?.write(command: controlCode, value: code, errorRecoveryWaitTime: 2000) ?? false
        }
        didSucceed = didSucceed || writeSucceeded
      }
    }
    return didSucceed
  }

  private func probeArm64InputCode(display: OtherDisplay) -> UInt16? {
    if let value = Arm64DDC.read(
      service: display.arm64avService,
      command: Command.inputSelect.rawValue,
      numOfWriteCycles: 1,
      numOfRetryAttemps: 0,
      validateChecksum: false
    )?.current,
      (0 ... 255).contains(value) {
      return value
    }

    if let value = Arm64DDC.read(
      service: display.arm64avService,
      command: Command.inputSelect.rawValue,
      numOfWriteCycles: 1,
      numOfRetryAttemps: 0,
      dataAddress: ARM64_DDC_ALTERNATE_DATA_ADDRESS,
      validateChecksum: false
    )?.current,
      (0 ... 255).contains(value) {
      return value
    }

    return nil
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
