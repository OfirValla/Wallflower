/// The device facts the Home Assistant bridge needs, with no presentation
/// concerns attached.
///
/// This type exists to keep the dependency rule honest. The bridge lives in
/// `integration/` and must not import `features/`, but it needs the current
/// screen state, URL and motion state - all of which the kiosk controller
/// happens to hold. So the controller maps its presentation state down to this
/// domain snapshot, and the bridge only ever sees the snapshot.
class DeviceSnapshot {
  const DeviceSnapshot({
    this.screenOn = true,
    this.brightness = 255,
    this.motionDetected = false,
    this.motionSource,
    this.illuminance,
    this.currentUrl = '',
    this.pageTitle,
    this.kioskLocked = false,
    this.deviceOwner = false,
    this.nativeStatus = const <String, dynamic>{},
  });

  final bool screenOn;
  final int brightness;
  final bool motionDetected;
  final String? motionSource;
  final double? illuminance;
  final String currentUrl;
  final String? pageTitle;
  final bool kioskLocked;
  final bool deviceOwner;

  /// Raw native capability map, surfaced verbatim by `GET /api/status`.
  final Map<String, dynamic> nativeStatus;
}
