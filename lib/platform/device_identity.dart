import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Static facts about this unit, resolved once at boot.
///
/// [nodeId] is the identity Home Assistant keys everything on - MQTT topics,
/// `unique_id`s, the device registry entry. Getting it wrong means duplicate
/// devices in HA after every reinstall, so it is deliberately **not** derived
/// from any hardware identifier:
///
/// * `ANDROID_ID` is no longer exposed by `device_info_plus`, is per-signing-key
///   since Android 8, and resets on factory reset anyway.
/// * `Build.FINGERPRINT` is identical across every unit of the same model.
/// * Serial numbers need privileged access.
///
/// So Aura generates a random id on first launch and persists it. It survives
/// updates and reboots, and it is stable per *installation*, which is exactly
/// the granularity HA wants.
@immutable
class DeviceIdentity {
  const DeviceIdentity({
    required this.nodeId,
    required this.manufacturer,
    required this.model,
    required this.androidRelease,
    required this.appVersion,
    this.ipAddress,
  });

  final String nodeId;
  final String manufacturer;
  final String model;
  final String androidRelease;
  final String appVersion;
  final String? ipAddress;

  DeviceIdentity copyWith({String? ipAddress}) => DeviceIdentity(
        nodeId: nodeId,
        manufacturer: manufacturer,
        model: model,
        androidRelease: androidRelease,
        appVersion: appVersion,
        ipAddress: ipAddress ?? this.ipAddress,
      );

  static const _nodeIdKey = 'aura.node_id';

  static Future<DeviceIdentity> load() async {
    final prefs = await SharedPreferences.getInstance();

    var nodeId = prefs.getString(_nodeIdKey);
    if (nodeId == null || nodeId.isEmpty) {
      nodeId = _generateNodeId();
      await prefs.setString(_nodeIdKey, nodeId);
    }

    var manufacturer = 'Unknown';
    var model = 'Android';
    var release = '';
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      manufacturer = info.manufacturer;
      model = info.model;
      release = info.version.release;
    } catch (error) {
      debugPrint('Aura: device info unavailable: $error');
    }

    var version = '0.0.0';
    try {
      final package = await PackageInfo.fromPlatform();
      version = '${package.version}+${package.buildNumber}';
    } catch (error) {
      debugPrint('Aura: package info unavailable: $error');
    }

    return DeviceIdentity(
      nodeId: nodeId,
      manufacturer: manufacturer,
      model: model,
      androidRelease: release,
      appVersion: version,
      ipAddress: await resolveIpAddress(),
    );
  }

  /// Re-resolved on network changes so HA's "Visit device" link stays correct
  /// after a DHCP lease change.
  static Future<String?> resolveIpAddress() async {
    try {
      return await NetworkInfo().getWifiIP();
    } catch (error) {
      debugPrint('Aura: wifi IP unavailable: $error');
      return null;
    }
  }

  static String _generateNodeId() {
    final random = Random.secure();
    final suffix = List<String>.generate(
      6,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    return 'a${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$suffix';
  }
}
