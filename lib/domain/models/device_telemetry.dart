/// Everything Aura reports upstream, in one immutable snapshot.
///
/// This is published as a single retained JSON document on
/// `aura/<node>/state`, and every Home Assistant entity extracts its value
/// from it with a `value_template`. One topic instead of a dozen means one
/// round trip per update, one retained message to restore after an HA restart,
/// and no chance of entities disagreeing about the device's state.
class DeviceTelemetry {
  const DeviceTelemetry({
    this.batteryLevel = -1,
    this.charging = false,
    this.batteryState = 'unknown',
    this.screenOn = true,
    this.brightness = 255,
    this.motionDetected = false,
    this.motionSource,
    this.motionEnabled = true,
    this.illuminance,
    this.currentUrl = '',
    this.pageTitle,
    this.kioskActive = false,
    this.deviceOwner = false,
    this.ipAddress,
    this.uptimeSeconds = 0,
    this.appVersion = '',
  });

  final int batteryLevel;
  final bool charging;
  final String batteryState;

  final bool screenOn;
  final int brightness;

  final bool motionDetected;
  final String? motionSource;
  final bool motionEnabled;
  final double? illuminance;

  final String currentUrl;
  final String? pageTitle;

  final bool kioskActive;
  final bool deviceOwner;

  final String? ipAddress;
  final int uptimeSeconds;
  final String appVersion;

  DeviceTelemetry copyWith({
    int? batteryLevel,
    bool? charging,
    String? batteryState,
    bool? screenOn,
    int? brightness,
    bool? motionDetected,
    String? motionSource,
    bool? motionEnabled,
    double? illuminance,
    String? currentUrl,
    String? pageTitle,
    bool? kioskActive,
    bool? deviceOwner,
    String? ipAddress,
    int? uptimeSeconds,
    String? appVersion,
  }) {
    return DeviceTelemetry(
      batteryLevel: batteryLevel ?? this.batteryLevel,
      charging: charging ?? this.charging,
      batteryState: batteryState ?? this.batteryState,
      screenOn: screenOn ?? this.screenOn,
      brightness: brightness ?? this.brightness,
      motionDetected: motionDetected ?? this.motionDetected,
      motionSource: motionSource ?? this.motionSource,
      motionEnabled: motionEnabled ?? this.motionEnabled,
      illuminance: illuminance ?? this.illuminance,
      currentUrl: currentUrl ?? this.currentUrl,
      pageTitle: pageTitle ?? this.pageTitle,
      kioskActive: kioskActive ?? this.kioskActive,
      deviceOwner: deviceOwner ?? this.deviceOwner,
      ipAddress: ipAddress ?? this.ipAddress,
      uptimeSeconds: uptimeSeconds ?? this.uptimeSeconds,
      appVersion: appVersion ?? this.appVersion,
    );
  }

  /// Keys here are the contract for every `value_template` in
  /// [HaDiscovery] - renaming one silently breaks a Home Assistant entity.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'battery': batteryLevel,
        'charging': charging,
        'battery_state': batteryState,
        'screen_on': screenOn,
        'brightness': brightness,
        'motion': motionDetected,
        'motion_source': motionSource,
        'motion_enabled': motionEnabled,
        'illuminance': illuminance,
        'url': currentUrl,
        'title': pageTitle,
        'kiosk_active': kioskActive,
        'device_owner': deviceOwner,
        'ip': ipAddress,
        'uptime': uptimeSeconds,
        'version': appVersion,
      };
}
