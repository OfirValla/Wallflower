import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/aura_settings.dart';
import '../../domain/repositories/settings_repository.dart';

/// Split-storage settings repository.
///
/// Non-secret config goes into a single JSON blob in `SharedPreferences`. One
/// blob rather than 40 typed keys because the settings are always read and
/// written as a whole, and a blob makes forward/backward compatibility trivial
/// (`AuraSettings.fromJson` falls back per field).
///
/// The MQTT password and the admin PIN go into `flutter_secure_storage`, which
/// on Android is AES via the Keystore. They are merged into the model on load
/// and stripped on save, so nothing outside this class has to remember which
/// fields are sensitive.
class SettingsRepositoryImpl implements SettingsRepository {
  SettingsRepositoryImpl({
    SharedPreferences? preferences,
    FlutterSecureStorage? secureStorage,
  })  : _prefs = preferences,
        _secure = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  SharedPreferences? _prefs;
  final FlutterSecureStorage _secure;

  static const _settingsKey = 'aura.settings.v1';
  static const _mqttPasswordKey = 'aura.secret.mqtt_password';
  static const _adminPinKey = 'aura.secret.admin_pin';

  Future<SharedPreferences> get _preferences async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<AuraSettings> load() async {
    final prefs = await _preferences;
    AuraSettings settings = const AuraSettings();

    final raw = prefs.getString(_settingsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          settings = AuraSettings.fromJson(decoded);
        }
      } catch (error, stack) {
        // Never let a corrupt blob brick a wall-mounted display: fall back to
        // defaults, keep the bad value for post-mortem, carry on booting.
        debugPrint('Aura: settings decode failed, using defaults: $error');
        debugPrintStack(stackTrace: stack);
      }
    }

    final secrets = await _readSecrets();
    return settings.copyWith(
      mqttPassword: secrets.mqttPassword,
      adminPin: secrets.adminPin ?? settings.adminPin,
    );
  }

  @override
  Future<void> save(AuraSettings settings) async {
    final prefs = await _preferences;
    await prefs.setString(_settingsKey, jsonEncode(settings.toJson()));

    // Secrets never touch the plain-text blob.
    await _writeSecret(_mqttPasswordKey, settings.mqttPassword);
    await _writeSecret(_adminPinKey, settings.adminPin);
  }

  @override
  Future<void> reset() async {
    final prefs = await _preferences;
    await prefs.remove(_settingsKey);
    await _secure.delete(key: _mqttPasswordKey);
    await _secure.delete(key: _adminPinKey);
  }

  Future<({String mqttPassword, String? adminPin})> _readSecrets() async {
    try {
      final password = await _secure.read(key: _mqttPasswordKey);
      final pin = await _secure.read(key: _adminPinKey);
      return (mqttPassword: password ?? '', adminPin: pin);
    } catch (error) {
      // A Keystore that has been invalidated (factory reset, OEM ROM update)
      // throws instead of returning null.
      debugPrint('Aura: secure storage read failed: $error');
      return (mqttPassword: '', adminPin: null);
    }
  }

  Future<void> _writeSecret(String key, String value) async {
    try {
      if (value.isEmpty) {
        await _secure.delete(key: key);
      } else {
        await _secure.write(key: key, value: value);
      }
    } catch (error) {
      debugPrint('Aura: secure storage write failed for $key: $error');
    }
  }
}
