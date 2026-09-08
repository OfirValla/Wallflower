import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/models/aura_settings.dart';

/// One native notification.
///
/// Deliberately loosely typed: the native side owns the vocabulary
/// (`ready`, `motion`, `screenState`, `motionState`, `kioskStatus`) and Dart
/// pattern-matches on [type]. Adding a native event never requires a Dart
/// model change.
@immutable
class NativeEvent {
  const NativeEvent(this.type, this.data);

  final String type;
  final Map<String, dynamic> data;

  bool get isMotion => type == 'motion';
  bool get isScreenState => type == 'screenState';
  bool get isReady => type == 'ready';

  T? value<T>(String key) {
    final raw = data[key];
    return raw is T ? raw : null;
  }

  @override
  String toString() => 'NativeEvent($type, $data)';
}

/// Dart-side facade over the two platform channels.
///
/// Everything native lives behind this one class so the rest of the app never
/// touches a channel name or an untyped map. When the surface stabilises,
/// swapping the body of these methods for Pigeon-generated calls is a
/// mechanical change that touches no callers.
class AuraPlatform {
  AuraPlatform({
    MethodChannel? commands,
    EventChannel? events,
  })  : _commands = commands ?? const MethodChannel(commandsChannel),
        _events = events ?? const EventChannel(eventsChannel);

  static const String commandsChannel = 'aura/commands';
  static const String eventsChannel = 'aura/events';

  final MethodChannel _commands;
  final EventChannel _events;

  Stream<NativeEvent>? _eventStream;

  /// Broadcast stream of native events. The native side pushes a `ready`
  /// event with a full state snapshot as soon as this is first listened to,
  /// so callers never need a separate initial fetch.
  Stream<NativeEvent> get events {
    return _eventStream ??= _events
        .receiveBroadcastStream()
        .map<NativeEvent>((dynamic raw) {
          final map = _coerce(raw);
          return NativeEvent(map['type']?.toString() ?? 'unknown', map);
        })
        .handleError((Object error, StackTrace stack) {
          debugPrint('Aura: native event stream error: $error');
        });
  }

  // -----------------------------------------------------------------------
  // State
  // -----------------------------------------------------------------------

  Future<Map<String, dynamic>> getStatus() => _invokeMap('getStatus');

  /// Pushes the native-relevant slice of settings down. Call this on every
  /// settings change - native caches it so the service behaves correctly even
  /// when the Dart isolate is not being scheduled.
  Future<Map<String, dynamic>> pushConfig(AuraSettings settings) =>
      _invokeMap('pushConfig', settings.toNativeConfig());

  // -----------------------------------------------------------------------
  // Kiosk
  // -----------------------------------------------------------------------

  Future<Map<String, dynamic>> engageKiosk() => _invokeMap('engageKiosk');

  Future<Map<String, dynamic>> releaseKiosk() => _invokeMap('releaseKiosk');

  Future<bool> startLockTask() => _invokeBool('startLockTask');

  Future<bool> stopLockTask() => _invokeBool('stopLockTask');

  Future<Map<String, dynamic>> applyDeviceOwnerPolicies() =>
      _invokeMap('applyDeviceOwnerPolicies');

  Future<Map<String, dynamic>> clearDeviceOwnerPolicies() =>
      _invokeMap('clearDeviceOwnerPolicies');

  Future<bool> bringToForeground() => _invokeBool('bringToForeground');

  // -----------------------------------------------------------------------
  // Display
  // -----------------------------------------------------------------------

  Future<bool> setScreen({required bool on}) =>
      _invokeBool('setScreen', <String, dynamic>{'on': on});

  /// [value] is 0..255.
  Future<bool> setBrightness(int value) =>
      _invokeBool('setBrightness', <String, dynamic>{'value': value});

  /// Resets the display idle timer, or wakes if already asleep.
  Future<bool> noteInteraction() => _invokeBool('noteInteraction');

  // -----------------------------------------------------------------------
  // Service
  // -----------------------------------------------------------------------

  Future<bool> startService() => _invokeBool('startService');

  Future<bool> stopService() => _invokeBool('stopService');

  // -----------------------------------------------------------------------
  // Settings escape hatches (admin panel)
  // -----------------------------------------------------------------------

  Future<void> openAdminActivation() => _invokeVoid('openAdminActivation');

  Future<void> openOverlaySettings() => _invokeVoid('openOverlaySettings');

  Future<void> openWriteSettings() => _invokeVoid('openWriteSettings');

  Future<void> openHomeAppSettings() => _invokeVoid('openHomeAppSettings');

  // -----------------------------------------------------------------------
  // Plumbing
  // -----------------------------------------------------------------------

  Future<Map<String, dynamic>> _invokeMap(
    String method, [
    Object? arguments,
  ]) async {
    try {
      final result = await _commands.invokeMethod<dynamic>(method, arguments);
      return _coerce(result);
    } on PlatformException catch (error) {
      debugPrint('Aura: $method failed: ${error.message}');
      return const <String, dynamic>{};
    } on MissingPluginException {
      // Happens in unit tests and on non-Android targets. Not fatal.
      return const <String, dynamic>{};
    }
  }

  Future<bool> _invokeBool(String method, [Object? arguments]) async {
    try {
      final result = await _commands.invokeMethod<dynamic>(method, arguments);
      if (result is bool) return result;
      if (result is Map) return true;
      return result != null;
    } on PlatformException catch (error) {
      debugPrint('Aura: $method failed: ${error.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> _invokeVoid(String method, [Object? arguments]) async {
    try {
      await _commands.invokeMethod<dynamic>(method, arguments);
    } on PlatformException catch (error) {
      debugPrint('Aura: $method failed: ${error.message}');
    } on MissingPluginException {
      // ignore
    }
  }

  static Map<String, dynamic> _coerce(dynamic raw) {
    if (raw is Map) {
      return raw.map<String, dynamic>(
        (Object? key, Object? value) => MapEntry(key.toString(), value),
      );
    }
    return const <String, dynamic>{};
  }
}
