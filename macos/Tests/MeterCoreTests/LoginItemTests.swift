import MeterCore
import Testing

private let installed = "/Applications/Meter.app"
private let built = "/Users/u/dev/meter/macos/.build/Meter.app"

@Test(arguments: [
  (LoginItemStatus.enabled, installed, true, true, false, false),
  (.disabled, installed, false, true, false, false),
  (.requiresApproval, installed, true, true, true, true),
  (.notFound, installed, false, true, false, false),
  (.disabled, built, false, false, true, false),
  (.notFound, built, false, false, true, false),
  (.disabled, "/Users/u/Applications/Meter.app", false, true, false, false),
])
func loginItemDisplay(
  status: LoginItemStatus, path: String, on: Bool, enabled: Bool, hasNote: Bool,
  offersSettings: Bool
) {
  let d = LoginItemDisplay(status: status, appPath: path)
  #expect(d.isOn == on)
  #expect(d.isEnabled == enabled)
  #expect((d.note != nil) == hasNote)
  #expect(d.offersSystemSettings == offersSettings)
}
