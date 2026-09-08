/// How Aura "turns the display off".
enum ScreenOffMode {
  /// Backlight to 0% + a black overlay. Instant wake, no keyguard, no
  /// permissions. Correct default for a mains-powered wall panel.
  dim,

  /// DevicePolicyManager.lockNow(). Real panel-off, real power saving, but
  /// needs device admin and wake takes a few hundred milliseconds.
  deviceLock;

  String get wire => name;

  static ScreenOffMode fromWire(String? value) => ScreenOffMode.values
      .firstWhere((e) => e.name == value, orElse: () => ScreenOffMode.dim);
}

/// Which presence sources feed the wake logic.
enum MotionSource {
  camera,
  sensors,
  both,
  none;

  String get wire => name;

  static MotionSource fromWire(String? value) => MotionSource.values
      .firstWhere((e) => e.name == value, orElse: () => MotionSource.camera);
}

/// The complete, immutable configuration of one Aura Display unit.
///
/// Two fields never appear in [toJson]: [mqttPassword] and [adminPin]. They
/// live in the platform keystore via `flutter_secure_storage` and are merged
/// back in by the repository on load. Keeping them off the plain-text blob is
/// the whole point, so do not "helpfully" add them to the map.
class AuraSettings {
  const AuraSettings({
    this.startUrl = 'http://homeassistant.local:8123',
    this.userAgent,
    this.allowInsecureSsl = false,
    this.clearCacheOnStart = false,
    this.enableJsBridge = true,
    this.reloadOnCrash = true,
    this.reloadOnNetworkRestore = true,
    this.periodicReloadMinutes = 0,
    this.kioskEnabled = true,
    this.lockTaskEnabled = true,
    this.immersive = true,
    this.blockStatusBar = true,
    this.blockHardwareKeys = true,
    this.dismissKeyguard = true,
    this.allowPowerMenu = false,
    this.becomeHomeApp = true,
    this.keepScreenOn = true,
    this.screenOffMode = ScreenOffMode.dim,
    this.screenTimeoutSeconds = 0,
    this.brightness = 255,
    this.useSystemBrightness = false,
    this.motionEnabled = true,
    this.motionSource = MotionSource.camera,
    this.motionSensitivity = 50,
    this.motionAnalysisFps = 5,
    this.motionCooldownMs = 3000,
    this.motionClearAfterMs = 10000,
    this.wakeOnMotion = true,
    this.luxTriggerDelta = 12,
    this.mqttEnabled = false,
    this.mqttHost = '',
    this.mqttPort = 1883,
    this.mqttUsername = '',
    this.mqttPassword = '',
    this.mqttTls = false,
    this.discoveryPrefix = 'homeassistant',
    this.telemetryIntervalSeconds = 30,
    this.restEnabled = true,
    this.restPort = 2323,
    this.deviceName = 'Aura Display',
    this.adminPin = '1234',
  });

  // --- WebView ------------------------------------------------------------
  final String startUrl;
  final String? userAgent;

  /// Accept invalid/self-signed certificates. Off by default; installing the
  /// local CA on the device (see network_security_config.xml) is strictly
  /// better and keeps validation intact.
  final bool allowInsecureSsl;
  final bool clearCacheOnStart;

  /// Exposes `window.Aura` to the page so a dashboard can call back into the
  /// kiosk (screen off, brightness, TTS...).
  final bool enableJsBridge;
  final bool reloadOnCrash;
  final bool reloadOnNetworkRestore;

  /// Guards against long-running dashboards leaking memory. 0 disables.
  final int periodicReloadMinutes;

  // --- Kiosk lockdown -----------------------------------------------------
  final bool kioskEnabled;
  final bool lockTaskEnabled;
  final bool immersive;
  final bool blockStatusBar;
  final bool blockHardwareKeys;
  final bool dismissKeyguard;
  final bool allowPowerMenu;
  final bool becomeHomeApp;

  // --- Power / display ----------------------------------------------------
  final bool keepScreenOn;
  final ScreenOffMode screenOffMode;

  /// Seconds of no interaction before the display sleeps. 0 = never.
  final int screenTimeoutSeconds;

  /// 0..255 to match Home Assistant's default light brightness scale.
  final int brightness;
  final bool useSystemBrightness;

  // --- Motion -------------------------------------------------------------
  final bool motionEnabled;
  final MotionSource motionSource;

  /// Single 0..100 knob; native maps it onto per-cell and area thresholds.
  final int motionSensitivity;
  final int motionAnalysisFps;
  final int motionCooldownMs;
  final int motionClearAfterMs;
  final bool wakeOnMotion;
  final double luxTriggerDelta;

  // --- Home Assistant -----------------------------------------------------
  final bool mqttEnabled;
  final String mqttHost;
  final int mqttPort;
  final String mqttUsername;
  final String mqttPassword;
  final bool mqttTls;
  final String discoveryPrefix;
  final int telemetryIntervalSeconds;

  final bool restEnabled;
  final int restPort;

  // --- Identity / admin ---------------------------------------------------
  final String deviceName;
  final String adminPin;

  bool get mqttConfigured => mqttEnabled && mqttHost.trim().isNotEmpty;

  AuraSettings copyWith({
    String? startUrl,
    String? userAgent,
    bool? allowInsecureSsl,
    bool? clearCacheOnStart,
    bool? enableJsBridge,
    bool? reloadOnCrash,
    bool? reloadOnNetworkRestore,
    int? periodicReloadMinutes,
    bool? kioskEnabled,
    bool? lockTaskEnabled,
    bool? immersive,
    bool? blockStatusBar,
    bool? blockHardwareKeys,
    bool? dismissKeyguard,
    bool? allowPowerMenu,
    bool? becomeHomeApp,
    bool? keepScreenOn,
    ScreenOffMode? screenOffMode,
    int? screenTimeoutSeconds,
    int? brightness,
    bool? useSystemBrightness,
    bool? motionEnabled,
    MotionSource? motionSource,
    int? motionSensitivity,
    int? motionAnalysisFps,
    int? motionCooldownMs,
    int? motionClearAfterMs,
    bool? wakeOnMotion,
    double? luxTriggerDelta,
    bool? mqttEnabled,
    String? mqttHost,
    int? mqttPort,
    String? mqttUsername,
    String? mqttPassword,
    bool? mqttTls,
    String? discoveryPrefix,
    int? telemetryIntervalSeconds,
    bool? restEnabled,
    int? restPort,
    String? deviceName,
    String? adminPin,
  }) {
    return AuraSettings(
      startUrl: startUrl ?? this.startUrl,
      userAgent: userAgent ?? this.userAgent,
      allowInsecureSsl: allowInsecureSsl ?? this.allowInsecureSsl,
      clearCacheOnStart: clearCacheOnStart ?? this.clearCacheOnStart,
      enableJsBridge: enableJsBridge ?? this.enableJsBridge,
      reloadOnCrash: reloadOnCrash ?? this.reloadOnCrash,
      reloadOnNetworkRestore:
          reloadOnNetworkRestore ?? this.reloadOnNetworkRestore,
      periodicReloadMinutes:
          periodicReloadMinutes ?? this.periodicReloadMinutes,
      kioskEnabled: kioskEnabled ?? this.kioskEnabled,
      lockTaskEnabled: lockTaskEnabled ?? this.lockTaskEnabled,
      immersive: immersive ?? this.immersive,
      blockStatusBar: blockStatusBar ?? this.blockStatusBar,
      blockHardwareKeys: blockHardwareKeys ?? this.blockHardwareKeys,
      dismissKeyguard: dismissKeyguard ?? this.dismissKeyguard,
      allowPowerMenu: allowPowerMenu ?? this.allowPowerMenu,
      becomeHomeApp: becomeHomeApp ?? this.becomeHomeApp,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      screenOffMode: screenOffMode ?? this.screenOffMode,
      screenTimeoutSeconds: screenTimeoutSeconds ?? this.screenTimeoutSeconds,
      brightness: brightness ?? this.brightness,
      useSystemBrightness: useSystemBrightness ?? this.useSystemBrightness,
      motionEnabled: motionEnabled ?? this.motionEnabled,
      motionSource: motionSource ?? this.motionSource,
      motionSensitivity: motionSensitivity ?? this.motionSensitivity,
      motionAnalysisFps: motionAnalysisFps ?? this.motionAnalysisFps,
      motionCooldownMs: motionCooldownMs ?? this.motionCooldownMs,
      motionClearAfterMs: motionClearAfterMs ?? this.motionClearAfterMs,
      wakeOnMotion: wakeOnMotion ?? this.wakeOnMotion,
      luxTriggerDelta: luxTriggerDelta ?? this.luxTriggerDelta,
      mqttEnabled: mqttEnabled ?? this.mqttEnabled,
      mqttHost: mqttHost ?? this.mqttHost,
      mqttPort: mqttPort ?? this.mqttPort,
      mqttUsername: mqttUsername ?? this.mqttUsername,
      mqttPassword: mqttPassword ?? this.mqttPassword,
      mqttTls: mqttTls ?? this.mqttTls,
      discoveryPrefix: discoveryPrefix ?? this.discoveryPrefix,
      telemetryIntervalSeconds:
          telemetryIntervalSeconds ?? this.telemetryIntervalSeconds,
      restEnabled: restEnabled ?? this.restEnabled,
      restPort: restPort ?? this.restPort,
      deviceName: deviceName ?? this.deviceName,
      adminPin: adminPin ?? this.adminPin,
    );
  }

  /// Persisted shape. Secrets are excluded on purpose - see the class doc.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'startUrl': startUrl,
        'userAgent': userAgent,
        'allowInsecureSsl': allowInsecureSsl,
        'clearCacheOnStart': clearCacheOnStart,
        'enableJsBridge': enableJsBridge,
        'reloadOnCrash': reloadOnCrash,
        'reloadOnNetworkRestore': reloadOnNetworkRestore,
        'periodicReloadMinutes': periodicReloadMinutes,
        'kioskEnabled': kioskEnabled,
        'lockTaskEnabled': lockTaskEnabled,
        'immersive': immersive,
        'blockStatusBar': blockStatusBar,
        'blockHardwareKeys': blockHardwareKeys,
        'dismissKeyguard': dismissKeyguard,
        'allowPowerMenu': allowPowerMenu,
        'becomeHomeApp': becomeHomeApp,
        'keepScreenOn': keepScreenOn,
        'screenOffMode': screenOffMode.wire,
        'screenTimeoutSeconds': screenTimeoutSeconds,
        'brightness': brightness,
        'useSystemBrightness': useSystemBrightness,
        'motionEnabled': motionEnabled,
        'motionSource': motionSource.wire,
        'motionSensitivity': motionSensitivity,
        'motionAnalysisFps': motionAnalysisFps,
        'motionCooldownMs': motionCooldownMs,
        'motionClearAfterMs': motionClearAfterMs,
        'wakeOnMotion': wakeOnMotion,
        'luxTriggerDelta': luxTriggerDelta,
        'mqttEnabled': mqttEnabled,
        'mqttHost': mqttHost,
        'mqttPort': mqttPort,
        'mqttUsername': mqttUsername,
        'mqttTls': mqttTls,
        'discoveryPrefix': discoveryPrefix,
        'telemetryIntervalSeconds': telemetryIntervalSeconds,
        'restEnabled': restEnabled,
        'restPort': restPort,
        'deviceName': deviceName,
      };

  factory AuraSettings.fromJson(Map<String, dynamic> json) {
    T pick<T>(String key, T fallback) {
      final value = json[key];
      return value is T ? value : fallback;
    }

    const defaults = AuraSettings();
    return AuraSettings(
      startUrl: pick('startUrl', defaults.startUrl),
      userAgent: json['userAgent'] as String?,
      allowInsecureSsl: pick('allowInsecureSsl', defaults.allowInsecureSsl),
      clearCacheOnStart: pick('clearCacheOnStart', defaults.clearCacheOnStart),
      enableJsBridge: pick('enableJsBridge', defaults.enableJsBridge),
      reloadOnCrash: pick('reloadOnCrash', defaults.reloadOnCrash),
      reloadOnNetworkRestore:
          pick('reloadOnNetworkRestore', defaults.reloadOnNetworkRestore),
      periodicReloadMinutes:
          pick('periodicReloadMinutes', defaults.periodicReloadMinutes),
      kioskEnabled: pick('kioskEnabled', defaults.kioskEnabled),
      lockTaskEnabled: pick('lockTaskEnabled', defaults.lockTaskEnabled),
      immersive: pick('immersive', defaults.immersive),
      blockStatusBar: pick('blockStatusBar', defaults.blockStatusBar),
      blockHardwareKeys:
          pick('blockHardwareKeys', defaults.blockHardwareKeys),
      dismissKeyguard: pick('dismissKeyguard', defaults.dismissKeyguard),
      allowPowerMenu: pick('allowPowerMenu', defaults.allowPowerMenu),
      becomeHomeApp: pick('becomeHomeApp', defaults.becomeHomeApp),
      keepScreenOn: pick('keepScreenOn', defaults.keepScreenOn),
      screenOffMode: ScreenOffMode.fromWire(json['screenOffMode'] as String?),
      screenTimeoutSeconds:
          pick('screenTimeoutSeconds', defaults.screenTimeoutSeconds),
      brightness: pick('brightness', defaults.brightness),
      useSystemBrightness:
          pick('useSystemBrightness', defaults.useSystemBrightness),
      motionEnabled: pick('motionEnabled', defaults.motionEnabled),
      motionSource: MotionSource.fromWire(json['motionSource'] as String?),
      motionSensitivity:
          pick('motionSensitivity', defaults.motionSensitivity),
      motionAnalysisFps:
          pick('motionAnalysisFps', defaults.motionAnalysisFps),
      motionCooldownMs: pick('motionCooldownMs', defaults.motionCooldownMs),
      motionClearAfterMs:
          pick('motionClearAfterMs', defaults.motionClearAfterMs),
      wakeOnMotion: pick('wakeOnMotion', defaults.wakeOnMotion),
      luxTriggerDelta:
          (json['luxTriggerDelta'] as num?)?.toDouble() ??
              defaults.luxTriggerDelta,
      mqttEnabled: pick('mqttEnabled', defaults.mqttEnabled),
      mqttHost: pick('mqttHost', defaults.mqttHost),
      mqttPort: pick('mqttPort', defaults.mqttPort),
      mqttUsername: pick('mqttUsername', defaults.mqttUsername),
      mqttTls: pick('mqttTls', defaults.mqttTls),
      discoveryPrefix: pick('discoveryPrefix', defaults.discoveryPrefix),
      telemetryIntervalSeconds:
          pick('telemetryIntervalSeconds', defaults.telemetryIntervalSeconds),
      restEnabled: pick('restEnabled', defaults.restEnabled),
      restPort: pick('restPort', defaults.restPort),
      deviceName: pick('deviceName', defaults.deviceName),
    );
  }

  /// The subset the native layer needs. Keys must match
  /// `AuraConfig.fromMap` in android/.../AuraConfig.kt.
  Map<String, dynamic> toNativeConfig() => <String, dynamic>{
        'kioskEnabled': kioskEnabled,
        'lockTaskEnabled': lockTaskEnabled,
        'immersive': immersive,
        'blockStatusBar': blockStatusBar,
        'blockHardwareKeys': blockHardwareKeys,
        'dismissKeyguard': dismissKeyguard,
        'allowPowerMenu': allowPowerMenu,
        'becomeHomeApp': becomeHomeApp,
        'keepScreenOn': keepScreenOn,
        'screenOffMode': screenOffMode.wire,
        'screenTimeoutSeconds': screenTimeoutSeconds,
        'brightness': brightness,
        'useSystemBrightness': useSystemBrightness,
        'motionEnabled': motionEnabled,
        'motionSource': motionSource.wire,
        'motionSensitivity': motionSensitivity,
        'motionAnalysisFps': motionAnalysisFps,
        'motionCooldownMs': motionCooldownMs,
        'motionClearAfterMs': motionClearAfterMs,
        'wakeOnMotion': wakeOnMotion,
        'luxTriggerDelta': luxTriggerDelta,
      };
}
