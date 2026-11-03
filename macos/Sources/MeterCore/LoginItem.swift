/// Whether the app opens at login, as the system reports it.
public enum LoginItemStatus: Sendable, Equatable {
  /// Registered and allowed.
  case enabled
  /// Not registered.
  case disabled
  /// Registered, but waiting for the user to allow it in System Settings.
  case requiresApproval
  /// The system has no record of the app, as before its first registration.
  case notFound
}

/// Turns opening at login on and off.
public protocol LoginItemService: Sendable {
  /// The current status, read fresh from the system.
  var status: LoginItemStatus { get }
  /// Registers or unregisters the app.
  func setEnabled(_ enabled: Bool) throws
}

/// What the Settings window shows for opening at login.
public struct LoginItemDisplay: Sendable, Equatable {
  /// Whether the checkbox is checked.
  public var isOn: Bool
  /// Whether the checkbox can be changed.
  public var isEnabled: Bool
  /// An explanation under the checkbox, if one is needed.
  public var note: String?
  /// Whether to offer a button to the Login Items settings.
  public var offersSystemSettings: Bool

  /// Decides the display from the system's status and where the app runs.
  ///
  /// A login item points at the app's location, so it's only offered from
  /// /Applications: a copy in a build folder would be replaced by the next
  /// build.
  public init(status: LoginItemStatus, appPath: String) {
    let installed =
      appPath.hasPrefix("/Applications/") || appPath.contains("/Applications/")
    switch (status, installed) {
    case (.enabled, _):
      self.init(isOn: true, isEnabled: true, note: nil, offersSystemSettings: false)
    case (.requiresApproval, _):
      self.init(
        isOn: true, isEnabled: true,
        note: "Allow Meter in System Settings to finish turning this on.",
        offersSystemSettings: true)
    case (_, false):
      self.init(
        isOn: false, isEnabled: false,
        note: "Install Meter in Applications (make install) to open it at login.",
        offersSystemSettings: false)
    // An app that has never registered can report notFound rather than
    // notRegistered, so both mean "off"; a real failure surfaces when
    // registering.
    case (.notFound, true), (.disabled, true):
      self.init(isOn: false, isEnabled: true, note: nil, offersSystemSettings: false)
    }
  }

  private init(isOn: Bool, isEnabled: Bool, note: String?, offersSystemSettings: Bool) {
    self.isOn = isOn
    self.isEnabled = isEnabled
    self.note = note
    self.offersSystemSettings = offersSystemSettings
  }
}
