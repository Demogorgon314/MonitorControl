//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import Foundation
import Security

enum RemoteControlTokenStoreError: Error {
  case saveFailed(status: OSStatus)
  case deleteFailed(status: OSStatus)
}

final class RemoteControlTokenStore {
  static let shared = RemoteControlTokenStore()

  private let service = "app.monitorcontrol.MonitorControl.remotecontrol"
  private let account = "http_api_token"

  private init() {}

  func loadToken() -> String {
    var query: [String: Any] = self.baseQuery()
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnData as String] = true

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
      return ""
    }
    return token
  }

  func saveToken(_ token: String) throws {
    let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    let encodedToken = Data(trimmedToken.utf8)
    let deleteStatus = SecItemDelete(self.baseQuery() as CFDictionary)
    if deleteStatus != errSecSuccess, deleteStatus != errSecItemNotFound {
      throw RemoteControlTokenStoreError.deleteFailed(status: deleteStatus)
    }

    var attributes = self.baseQuery()
    attributes[kSecValueData as String] = encodedToken
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let addStatus = SecItemAdd(attributes as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw RemoteControlTokenStoreError.saveFailed(status: addStatus)
    }
  }

  func deleteToken() throws {
    let status = SecItemDelete(self.baseQuery() as CFDictionary)
    if status != errSecSuccess, status != errSecItemNotFound {
      throw RemoteControlTokenStoreError.deleteFailed(status: status)
    }
  }

  private func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: self.service,
      kSecAttrAccount as String: self.account,
    ]
  }
}
