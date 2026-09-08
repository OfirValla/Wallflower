import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

import '../domain/models/aura_settings.dart';
import '../domain/models/device_snapshot.dart';
import '../domain/models/device_telemetry.dart';
import '../domain/models/remote_command.dart';
import '../platform/device_identity.dart';
import 'command_executor.dart';
import 'mqtt/ha_discovery.dart';
import 'mqtt/mqtt_manager.dart';
import 'rest/aura_rest_server.dart';

/// Assembles telemetry and owns both Home Assistant transports.
///
/// The bridge is the only place that knows how [DeviceSnapshot], the battery and
/// [DeviceIdentity] combine into the single [DeviceTelemetry] document. MQTT
/// and REST are then just two ways to move that document and receive commands
/// about it - neither transport knows anything about the app's internals.
class HomeAssistantBridge {
  HomeAssistantBridge({
    required DeviceIdentity identity,
    required AuraSettings Function() readSettings,
    required DeviceSnapshot Function() readSnapshot,
    required CommandExecutor executor,
  })  : _identity = identity,
        _readSettings = readSettings,
        _readSnapshot = readSnapshot,
        _executor = executor;

  DeviceIdentity _identity;
  final AuraSettings Function() _readSettings;
  final DeviceSnapshot Function() _readSnapshot;
  final CommandExecutor _executor;

  late final MqttManager _mqtt = MqttManager(
    onCommand: (RemoteCommand command) => _executor.execute(command),
    onStateChanged: (MqttLinkState state) {
      _mqttState = state;
      onLinkStateChanged?.call(state);
    },
  );

  late final AuraRestServer _rest = AuraRestServer(
    onCommand: _executor.execute,
    telemetry: buildTelemetry,
    status: () => <String, dynamic>{
      ..._readSnapshot().nativeStatus,
      'mqtt': _mqttState.name,
      'mqtt_error': _mqtt.lastError,
      'node_id': _identity.nodeId,
      'ip': _identity.ipAddress,
      'version': _identity.appVersion,
    },
  );

  final Battery _battery = Battery();
  StreamSubscription<BatteryState>? _batterySubscription;
  Timer? _batteryPoll;
  Timer? _ipRefresh;

  int _batteryLevel = -1;
  BatteryState _batteryState = BatteryState.unknown;
  final DateTime _startedAt = DateTime.now();

  MqttLinkState _mqttState = MqttLinkState.disconnected;
  MqttLinkState get mqttState => _mqttState;
  String? get mqttError => _mqtt.lastError;
  bool get restRunning => _rest.isRunning;

  void Function(MqttLinkState state)? onLinkStateChanged;

  bool _started = false;

  // -----------------------------------------------------------------------
  // Lifecycle
  // -----------------------------------------------------------------------

  Future<void> start() async {
    if (_started) return;
    _started = true;

    await _refreshBattery();
    _batterySubscription = _battery.onBatteryStateChanged.listen(
      (BatteryState state) async {
        _batteryState = state;
        await _refreshBatteryLevel();
        publish();
      },
      onError: (Object error) => debugPrint('Aura: battery stream: $error'),
    );

    // The level itself has no stream; charge state changes are the interesting
    // edges and a slow poll covers the slow drift.
    _batteryPoll = Timer.periodic(const Duration(minutes: 2), (_) async {
      await _refreshBatteryLevel();
      publish();
    });

    // DHCP leases change; HA's "Visit device" link should not rot.
    _ipRefresh = Timer.periodic(const Duration(minutes: 10), (_) async {
      final ip = await DeviceIdentity.resolveIpAddress();
      if (ip != null && ip != _identity.ipAddress) {
        _identity = _identity.copyWith(ipAddress: ip);
        await restartTransports();
      }
    });

    await restartTransports();
  }

  /// Applies a settings change: reconnects MQTT and rebinds REST as needed.
  Future<void> onSettingsChanged(AuraSettings settings) => restartTransports();

  /// Called on every kiosk-state change; publishing is de-duplicated so this
  /// is cheap even at UI-update frequency.
  void onKioskStateChanged() => publish();

  Future<void> restartTransports() async {
    final settings = _readSettings();

    if (settings.mqttConfigured) {
      await _mqtt.start(
        settings: settings,
        discovery: buildDiscovery(settings),
        telemetry: buildTelemetry,
      );
    } else {
      await _mqtt.stop();
    }

    if (settings.restEnabled) {
      // The admin PIN doubles as the API bearer token - see AuraRestServer.
      await _rest.start(port: settings.restPort, token: settings.adminPin);
    } else {
      await _rest.stop();
    }
  }

  Future<void> dispose() async {
    _batterySubscription?.cancel();
    _batteryPoll?.cancel();
    _ipRefresh?.cancel();
    await _mqtt.stop();
    await _rest.stop();
    _started = false;
  }

  // -----------------------------------------------------------------------
  // Telemetry
  // -----------------------------------------------------------------------

  void publish() {
    if (!_started) return;
    _mqtt.publishTelemetry(buildTelemetry());
  }

  HaDiscovery buildDiscovery(AuraSettings settings) => HaDiscovery(
        nodeId: _identity.nodeId,
        deviceName: settings.deviceName,
        discoveryPrefix: settings.discoveryPrefix,
        manufacturer: _identity.manufacturer,
        model: '${_identity.model} (Android ${_identity.androidRelease})',
        swVersion: _identity.appVersion,
        configurationUrl: _identity.ipAddress == null
            ? null
            : 'http://${_identity.ipAddress}:${settings.restPort}',
      );

  DeviceTelemetry buildTelemetry() {
    final kiosk = _readSnapshot();
    return DeviceTelemetry(
      batteryLevel: _batteryLevel,
      charging: _batteryState == BatteryState.charging ||
          _batteryState == BatteryState.full,
      batteryState: _batteryState.name,
      screenOn: kiosk.screenOn,
      brightness: kiosk.brightness,
      motionDetected: kiosk.motionDetected,
      motionSource: kiosk.motionSource,
      motionEnabled: _readSettings().motionEnabled,
      illuminance: kiosk.illuminance,
      currentUrl: kiosk.currentUrl,
      pageTitle: kiosk.pageTitle,
      kioskActive: kiosk.kioskLocked,
      deviceOwner: kiosk.deviceOwner,
      ipAddress: _identity.ipAddress,
      uptimeSeconds: DateTime.now().difference(_startedAt).inSeconds,
      appVersion: _identity.appVersion,
    );
  }

  Future<void> _refreshBattery() async {
    try {
      _batteryState = await _battery.batteryState;
    } catch (error) {
      debugPrint('Aura: battery state unavailable: $error');
    }
    await _refreshBatteryLevel();
  }

  Future<void> _refreshBatteryLevel() async {
    try {
      _batteryLevel = await _battery.batteryLevel;
    } catch (error) {
      // Mains-only signage often has no battery at all. -1 is suppressed by
      // the discovery template rather than graphed as 0%.
      _batteryLevel = -1;
    }
  }
}
