import MeterCore
import ServiceManagement

/// Opens the app at login through `SMAppService.mainApp`.
struct SystemLoginItem: LoginItemService {
  var status: LoginItemStatus {
    switch SMAppService.mainApp.status {
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notFound: .notFound
    case .notRegistered: .disabled
    @unknown default: .disabled
    }
  }

  func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }

  /// Opens System Settings at Login Items, where the user approves the app.
  static func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
