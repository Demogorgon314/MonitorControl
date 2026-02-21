//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Cocoa
import os.log
import ServiceManagement
import Settings

class MainPrefsViewController: NSViewController, SettingsPane {
  let paneIdentifier = Settings.PaneIdentifier.main
  let paneTitle: String = NSLocalizedString("General", comment: "Shown in the main prefs window")

  var toolbarItemIcon: NSImage {
    if !DEBUG_MACOS10, #available(macOS 11.0, *) {
      return NSImage(systemSymbolName: "switch.2", accessibilityDescription: "Display")!
    } else {
      return NSImage(named: NSImage.infoName)!
    }
  }

  @IBOutlet var startAtLogin: NSButton!
  @IBOutlet var automaticUpdateCheck: NSButton!
  @IBOutlet var allowZeroSwBrightness: NSButton!
  @IBOutlet var combinedBrightness: NSButton!
  @IBOutlet var enableSmooth: NSButton!
  @IBOutlet var enableBrightnessSync: NSButton!
  @IBOutlet var startupAction: NSPopUpButton!
  @IBOutlet var remoteControlEnabled: NSButton!
  @IBOutlet var remoteControlPort: NSTextField!
  @IBOutlet var remoteControlToken: NSSecureTextField!
  @IBOutlet var remoteControlTokenPlain: NSTextField?
  @IBOutlet var remoteControlTokenRevealButton: NSButton?
  @IBOutlet var remoteControlStatus: NSTextField!
  @IBOutlet var rowDoNothingStartupText: NSGridRow!
  @IBOutlet var rowWriteStartupText: NSGridRow!
  @IBOutlet var rowReadStartupText: NSGridRow!
  private var isRemoteControlTokenVisible = false

  func updateGridLayout() {
    if self.startupAction.selectedTag() == StartupAction.doNothing.rawValue {
      self.rowDoNothingStartupText.isHidden = false
      self.rowWriteStartupText.isHidden = true
      self.rowReadStartupText.isHidden = true
    } else if self.startupAction.selectedTag() == StartupAction.write.rawValue {
      self.rowDoNothingStartupText.isHidden = true
      self.rowWriteStartupText.isHidden = false
      self.rowReadStartupText.isHidden = true
    } else {
      self.rowDoNothingStartupText.isHidden = true
      self.rowWriteStartupText.isHidden = true
      self.rowReadStartupText.isHidden = false
    }
  }

  @available(macOS, deprecated: 10.10)
  override func viewDidLoad() {
    super.viewDidLoad()
    self.populateSettings()
  }

  @available(macOS, deprecated: 10.10)
  func populateSettings() {
    // This is marked as deprectated but according to the function header it still does not have a replacement as of macOS 12 Monterey and is valid to use.
    let startAtLogin = (SMCopyAllJobDictionaries(kSMDomainUserLaunchd).takeRetainedValue() as? [[String: AnyObject]])?.first { $0["Label"] as? String == "\(Bundle.main.bundleIdentifier!)Helper" }?["OnDemand"] as? Bool ?? false
    self.startAtLogin.state = startAtLogin ? .on : .off
    self.automaticUpdateCheck.state = prefs.bool(forKey: PrefKey.SUEnableAutomaticChecks.rawValue) ? .on : .off
    self.combinedBrightness.state = prefs.bool(forKey: PrefKey.disableCombinedBrightness.rawValue) ? .off : .on
    self.allowZeroSwBrightness.state = prefs.bool(forKey: PrefKey.allowZeroSwBrightness.rawValue) ? .on : .off
    self.enableSmooth.state = prefs.bool(forKey: PrefKey.disableSmoothBrightness.rawValue) ? .off : .on
    self.enableBrightnessSync.state = prefs.bool(forKey: PrefKey.enableBrightnessSync.rawValue) ? .on : .off
    self.startupAction.selectItem(withTag: prefs.integer(forKey: PrefKey.startupAction.rawValue))
    self.remoteControlEnabled.state = prefs.bool(forKey: PrefKey.remoteControlEnabled.rawValue) ? .on : .off
    let port = prefs.integer(forKey: PrefKey.remoteControlPort.rawValue)
    if (1024 ... 65535).contains(port) {
      self.remoteControlPort.stringValue = String(port)
    } else {
      prefs.set(51423, forKey: PrefKey.remoteControlPort.rawValue)
      self.remoteControlPort.stringValue = "51423"
    }
    self.syncRemoteControlTokenFields(RemoteControlTokenStore.shared.loadToken())
    self.setRemoteControlTokenVisibility(false)
    // Preload Display settings to some extent to properly set up size in orther that animation won't fail
    menuslidersPrefsVc?.view.layoutSubtreeIfNeeded()
    keyboardPrefsVc?.view.layoutSubtreeIfNeeded()
    displaysPrefsVc?.view.layoutSubtreeIfNeeded()
    aboutPrefsVc?.view.layoutSubtreeIfNeeded()
    self.updateGridLayout()
    self.refreshRemoteControlStatus()
  }

  @IBAction func startAtLoginClicked(_ sender: NSButton) {
    switch sender.state {
    case .on:
      app.setStartAtLogin(enabled: true)
    case .off:
      app.setStartAtLogin(enabled: false)
    default: break
    }
  }

  @IBAction func automaticUpdateCheck(_ sender: NSButton) {
    switch sender.state {
    case .on:
      prefs.set(true, forKey: PrefKey.SUEnableAutomaticChecks.rawValue)
    case .off:
      prefs.set(false, forKey: PrefKey.SUEnableAutomaticChecks.rawValue)
    default: break
    }
  }

  @IBAction func combinedBrightness(_ sender: NSButton) {
    for display in DisplayManager.shared.getDdcCapableDisplays() where !display.isSw() {
      _ = display.setDirectBrightness(1)
    }
    DisplayManager.shared.resetSwBrightnessForAllDisplays(async: false)
    switch sender.state {
    case .on:
      prefs.set(false, forKey: PrefKey.disableCombinedBrightness.rawValue)
    case .off:
      prefs.set(true, forKey: PrefKey.disableCombinedBrightness.rawValue)
    default: break
    }
    app.configure()
  }

  @IBAction func allowZeroSwBrightness(_ sender: NSButton) {
    switch sender.state {
    case .on:
      prefs.set(true, forKey: PrefKey.allowZeroSwBrightness.rawValue)
    case .off:
      prefs.set(false, forKey: PrefKey.allowZeroSwBrightness.rawValue)
    default: break
    }
    for display in DisplayManager.shared.getOtherDisplays() {
      _ = display.setDirectBrightness(1)
      _ = display.setSwBrightness(1)
    }
    self.updateGridLayout()
    app.configure()
  }

  @IBAction func enableSmooth(_ sender: NSButton) {
    switch sender.state {
    case .on:
      prefs.set(false, forKey: PrefKey.disableSmoothBrightness.rawValue)
    case .off:
      prefs.set(true, forKey: PrefKey.disableSmoothBrightness.rawValue)
    default: break
    }
  }

  @IBAction func enableBrightnessSync(_ sender: NSButton) {
    switch sender.state {
    case .on:
      prefs.set(true, forKey: PrefKey.enableBrightnessSync.rawValue)
    case .off:
      prefs.set(false, forKey: PrefKey.enableBrightnessSync.rawValue)
    default: break
    }
  }

  @IBAction func startupAction(_ sender: NSPopUpButton) {
    prefs.set(sender.selectedTag(), forKey: PrefKey.startupAction.rawValue)
    self.updateGridLayout()
  }

  @IBAction func remoteControlEnabledChanged(_ sender: NSButton) {
    prefs.set(sender.state == .on, forKey: PrefKey.remoteControlEnabled.rawValue)
    app.refreshRemoteControlServerConfiguration(showAlert: true)
    self.refreshRemoteControlStatus()
  }

  @IBAction func remoteControlPortChanged(_ sender: NSTextField) {
    let trimmedPort = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsedPort = Int(trimmedPort), (1024 ... 65535).contains(parsedPort) else {
      let savedPort = prefs.integer(forKey: PrefKey.remoteControlPort.rawValue)
      sender.stringValue = String((1024 ... 65535).contains(savedPort) ? savedPort : 51423)
      self.presentValidationAlert(message: "Port must be an integer between 1024 and 65535.")
      return
    }
    prefs.set(parsedPort, forKey: PrefKey.remoteControlPort.rawValue)
    app.refreshRemoteControlServerConfiguration(showAlert: true)
    self.refreshRemoteControlStatus()
  }

  @IBAction func remoteControlTokenChanged(_: NSTextField) {
    let token = self.currentRemoteControlTokenText().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      self.syncRemoteControlTokenFields(RemoteControlTokenStore.shared.loadToken())
      self.presentValidationAlert(message: "Bearer token cannot be empty.")
      return
    }
    do {
      try RemoteControlTokenStore.shared.saveToken(token)
      self.syncRemoteControlTokenFields(token)
      app.refreshRemoteControlServerConfiguration(showAlert: true)
      self.refreshRemoteControlStatus()
    } catch {
      self.syncRemoteControlTokenFields(RemoteControlTokenStore.shared.loadToken())
      self.presentValidationAlert(message: "Unable to save token in Keychain.")
    }
  }

  @IBAction func toggleRemoteControlTokenVisibility(_: NSButton) {
    if self.isRemoteControlTokenVisible {
      self.remoteControlToken.stringValue = self.remoteControlTokenPlain?.stringValue ?? self.remoteControlToken.stringValue
    } else {
      self.remoteControlTokenPlain?.stringValue = self.remoteControlToken.stringValue
    }
    self.setRemoteControlTokenVisibility(!self.isRemoteControlTokenVisible)
  }

  func refreshRemoteControlStatus() {
    guard self.isViewLoaded else {
      return
    }
    self.remoteControlStatus.stringValue = app.remoteControlStatusDescription()
  }

  private func presentValidationAlert(message: String) {
    let alert = NSAlert()
    alert.messageText = NSLocalizedString("Remote HTTP Control", comment: "Shown in the alert dialog")
    alert.informativeText = message
    alert.runModal()
  }

  private func setRemoteControlTokenVisibility(_ visible: Bool) {
    self.isRemoteControlTokenVisible = visible
    self.remoteControlToken.isHidden = visible
    self.remoteControlTokenPlain?.isHidden = !visible
    self.remoteControlTokenRevealButton?.title = visible ? "Hide" : "Show"
  }

  private func syncRemoteControlTokenFields(_ token: String) {
    self.remoteControlToken.stringValue = token
    self.remoteControlTokenPlain?.stringValue = token
  }

  private func currentRemoteControlTokenText() -> String {
    if self.isRemoteControlTokenVisible, let plainToken = self.remoteControlTokenPlain?.stringValue {
      return plainToken
    }
    return self.remoteControlToken.stringValue
  }

  @available(macOS, deprecated: 10.10)
  func resetSheetModalHander(modalResponse: NSApplication.ModalResponse) {
    if modalResponse == NSApplication.ModalResponse.alertFirstButtonReturn {
      app.settingsReset()
      self.populateSettings()
      menuslidersPrefsVc?.populateSettings()
      keyboardPrefsVc?.populateSettings()
      displaysPrefsVc?.populateSettings()
    }
  }

  @available(macOS, deprecated: 10.10)
  @IBAction func resetPrefsClicked(_: NSButton) {
    let alert = NSAlert()
    alert.messageText = NSLocalizedString("Reset Settings?", comment: "Shown in the alert dialog")
    alert.informativeText = NSLocalizedString("Are you sure you want to reset all settings?", comment: "Shown in the alert dialog")
    alert.addButton(withTitle: NSLocalizedString("Yes", comment: "Shown in the alert dialog"))
    alert.addButton(withTitle: NSLocalizedString("No", comment: "Shown in the alert dialog"))
    alert.alertStyle = NSAlert.Style.warning
    if let window = self.view.window {
      alert.beginSheetModal(for: window, completionHandler: { modalResponse in self.resetSheetModalHander(modalResponse: modalResponse) })
    }
  }
}
