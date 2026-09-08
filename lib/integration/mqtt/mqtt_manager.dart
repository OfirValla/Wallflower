import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../../domain/models/aura_settings.dart';
import '../../domain/models/device_telemetry.dart';
import '../../domain/models/remote_command.dart';
import 'ha_discovery.dart';

enum MqttLinkState { disconnected, connecting, connected, failed }

/// Bi-directional Home Assistant link over MQTT.
///
/// Connection lifecycle, in order, because the order matters:
///
/// 1. Connect with a **retained LWT** of `offline` on the availability topic.
///    The broker now owns our death notice - if the tablet loses wifi, HA marks
///    every entity unavailable instead of trusting a stale battery reading.
/// 2. Publish `online` (retained) to the availability topic.
/// 3. Publish the discovery configs (retained). HA creates/updates the device.
/// 4. Subscribe to `aura/<node>/cmd/#`, the JSON envelope topic, and
///    `<prefix>/status`.
/// 5. Publish the first telemetry document (retained) so entities have values
///    immediately rather than showing "unknown" until the first change.
///
/// Two failure modes get explicit handling because both bite in practice:
///
/// * **HA restarts.** It republishes `homeassistant/status = online` (its birth
///   message) and forgets nothing - but our retained configs may be replayed in
///   an order it does not like. Replaying discovery on the birth message is the
///   documented fix, and it costs one publish burst.
/// * **The broker restarts.** `mqtt_client`'s `autoReconnect` gets the socket
///   back, but a broker that lost its retained store needs availability,
///   discovery and state pushed again - hence [_onAutoReconnected].
class MqttManager {
  MqttManager({
    required this.onCommand,
    this.onStateChanged,
  });

  /// Invoked for every parsed inbound command, on the Dart event loop.
  final void Function(RemoteCommand command) onCommand;
  final void Function(MqttLinkState state)? onStateChanged;

  MqttServerClient? _client;
  HaDiscovery? _discovery;
  AuraSettings? _settings;
  DeviceTelemetry Function()? _telemetryProvider;

  Timer? _heartbeat;
  Timer? _retry;
  int _retryAttempt = 0;
  String? _lastPublishedState;
  StreamSubscription<dynamic>? _updates;

  MqttLinkState _state = MqttLinkState.disconnected;
  MqttLinkState get state => _state;

  String? get lastError => _lastError;
  String? _lastError;

  bool get isConnected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  // -----------------------------------------------------------------------
  // Lifecycle
  // -----------------------------------------------------------------------

  /// (Re)connects with [settings]. Safe to call on every settings change -
  /// it tears down any existing session first.
  Future<void> start({
    required AuraSettings settings,
    required HaDiscovery discovery,
    required DeviceTelemetry Function() telemetry,
  }) async {
    await stop();

    _settings = settings;
    _discovery = discovery;
    _telemetryProvider = telemetry;

    if (!settings.mqttConfigured) {
      _setState(MqttLinkState.disconnected);
      return;
    }
    await _connect();
  }

  Future<void> stop() async {
    _retry?.cancel();
    _retry = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    await _updates?.cancel();
    _updates = null;
    _lastPublishedState = null;

    final client = _client;
    _client = null;
    if (client != null) {
      // Best-effort graceful goodbye: an explicit `offline` beats waiting for
      // the broker's keep-alive timeout to fire the LWT.
      try {
        if (client.connectionStatus?.state == MqttConnectionState.connected) {
          _publish(
            client,
            _discovery!.availabilityTopic,
            HaDiscovery.payloadOffline,
            retain: true,
          );
        }
      } catch (_) {
        // ignore
      }
      client.autoReconnect = false;
      client.disconnect();
    }
    _setState(MqttLinkState.disconnected);
  }

  Future<void> _connect() async {
    final settings = _settings;
    final discovery = _discovery;
    if (settings == null || discovery == null) return;

    _setState(MqttLinkState.connecting);

    final clientId = 'aura_${discovery.nodeId}';
    final client = MqttServerClient.withPort(
      settings.mqttHost.trim(),
      clientId,
      settings.mqttPort,
    );

    client
      ..logging(on: false)
      ..keepAlivePeriod = 30
      ..connectTimeoutPeriod = 8000
      ..autoReconnect = true
      ..resubscribeOnAutoReconnect = true
      ..secure = settings.mqttTls
      ..setProtocolV311()
      ..onConnected = _onConnected
      ..onDisconnected = _onDisconnected
      ..onAutoReconnected = _onAutoReconnected;

    if (settings.mqttTls && settings.allowInsecureSsl) {
      // Same opt-in as the WebView: only for a self-signed broker on a
      // trusted LAN, and off by default.
      client.onBadCertificate = (Object? certificate) => true;
    }

    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .withWillTopic(discovery.availabilityTopic)
        .withWillMessage(HaDiscovery.payloadOffline)
        .withWillQos(MqttQos.atLeastOnce)
        .withWillRetain()
        .startClean();

    _client = client;

    try {
      await client.connect(
        settings.mqttUsername.isEmpty ? null : settings.mqttUsername,
        settings.mqttPassword.isEmpty ? null : settings.mqttPassword,
      );
    } catch (error) {
      _lastError = error.toString();
      debugPrint('Aura: MQTT connect failed: $error');
      client.disconnect();
      _setState(MqttLinkState.failed);
      _scheduleRetry();
      return;
    }

    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      _lastError = 'Broker refused connection: ${client.connectionStatus}';
      _setState(MqttLinkState.failed);
      _scheduleRetry();
      return;
    }

    _retryAttempt = 0;
    _lastError = null;
    _listen(client);
    _announce(client);
    _startHeartbeat();
  }

  // -----------------------------------------------------------------------
  // Announce / subscribe
  // -----------------------------------------------------------------------

  void _announce(MqttServerClient client) {
    final discovery = _discovery;
    if (discovery == null) return;

    // 1. We are alive.
    _publish(
      client,
      discovery.availabilityTopic,
      HaDiscovery.payloadOnline,
      retain: true,
    );

    // 2. Here is what we are.
    for (final DiscoveryMessage message in discovery.build()) {
      _publish(client, message.topic, jsonEncode(message.payload), retain: true);
    }

    // 3. Tell us what to do.
    client.subscribe(discovery.commandWildcard, MqttQos.atLeastOnce);
    client.subscribe(discovery.commandEnvelopeTopic, MqttQos.atLeastOnce);
    // HA's birth/will message. Without this, entities silently stop working
    // after an HA restart until Aura happens to reconnect.
    client.subscribe(discovery.haStatusTopic, MqttQos.atLeastOnce);

    // 4. Here is the current state, so nothing shows "unknown".
    final telemetry = _telemetryProvider?.call();
    if (telemetry != null) publishTelemetry(telemetry, force: true);
  }

  void _listen(MqttServerClient client) {
    _updates?.cancel();
    _updates = client.updates?.listen(
      (dynamic events) {
        if (events is! List) return;
        for (final dynamic event in events) {
          try {
            final String topic = (event.topic as String?) ?? '';
            final dynamic message = event.payload;
            if (message is! MqttPublishMessage) continue;
            final String payload = MqttPublishPayload.bytesToStringAsString(
              message.payload.message,
            );
            _handleMessage(topic, payload);
          } catch (error) {
            debugPrint('Aura: malformed MQTT message: $error');
          }
        }
      },
      onError: (Object error) {
        debugPrint('Aura: MQTT stream error: $error');
      },
    );
  }

  void _handleMessage(String topic, String payload) {
    final discovery = _discovery;
    if (discovery == null) return;

    // Home Assistant came back. Replay discovery so the entities re-appear.
    if (topic == discovery.haStatusTopic) {
      if (payload.trim() == HaDiscovery.payloadOnline) {
        debugPrint('Aura: HA birth message - replaying discovery');
        final client = _client;
        if (client != null && isConnected) _announce(client);
      }
      return;
    }

    RemoteCommand? command;

    if (topic == discovery.commandEnvelopeTopic) {
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) {
          command = RemoteCommand.fromJson(decoded);
        }
      } catch (error) {
        debugPrint('Aura: bad command envelope: $error');
      }
    } else {
      final suffix = discovery.commandSuffixOf(topic);
      if (suffix != null) command = RemoteCommand.fromTopic(suffix, payload);
    }

    if (command == null) {
      debugPrint('Aura: ignored MQTT message on $topic ("$payload")');
      return;
    }
    onCommand(command);
  }

  // -----------------------------------------------------------------------
  // Telemetry
  // -----------------------------------------------------------------------

  /// Publishes the retained telemetry document.
  ///
  /// De-duplicated by encoded payload: a wall display that reports nothing new
  /// should cost nothing. [force] bypasses that for the heartbeat and for the
  /// first publish after (re)connecting.
  void publishTelemetry(DeviceTelemetry telemetry, {bool force = false}) {
    final client = _client;
    final discovery = _discovery;
    if (client == null || discovery == null || !isConnected) return;

    final encoded = jsonEncode(telemetry.toJson());
    if (!force && encoded == _lastPublishedState) return;
    _lastPublishedState = encoded;

    _publish(client, discovery.stateTopic, encoded, retain: true);
  }

  /// Removes this device from Home Assistant by clearing its retained configs.
  Future<void> removeFromHomeAssistant() async {
    final client = _client;
    final discovery = _discovery;
    if (client == null || discovery == null || !isConnected) return;
    for (final String topic in discovery.configTopics()) {
      _publish(client, topic, '', retain: true);
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    final seconds = (_settings?.telemetryIntervalSeconds ?? 30).clamp(5, 3600);
    _heartbeat = Timer.periodic(Duration(seconds: seconds), (_) {
      final telemetry = _telemetryProvider?.call();
      if (telemetry != null) publishTelemetry(telemetry, force: true);
    });
  }

  void _publish(
    MqttServerClient client,
    String topic,
    String payload, {
    bool retain = false,
    MqttQos qos = MqttQos.atLeastOnce,
  }) {
    try {
      final builder = MqttClientPayloadBuilder()..addUTF8String(payload);
      client.publishMessage(topic, qos, builder.payload!, retain: retain);
    } catch (error) {
      debugPrint('Aura: publish to $topic failed: $error');
    }
  }

  // -----------------------------------------------------------------------
  // Connection callbacks
  // -----------------------------------------------------------------------

  void _onConnected() {
    debugPrint('Aura: MQTT connected');
    _setState(MqttLinkState.connected);
  }

  void _onDisconnected() {
    debugPrint('Aura: MQTT disconnected');
    _heartbeat?.cancel();
    if (_client != null) {
      _setState(MqttLinkState.disconnected);
      // autoReconnect handles socket-level drops; this covers the case where
      // the broker actively refused us and autoReconnect gave up.
      _scheduleRetry();
    }
  }

  void _onAutoReconnected() {
    debugPrint('Aura: MQTT auto-reconnected - re-announcing');
    _setState(MqttLinkState.connected);
    final client = _client;
    if (client != null) {
      _lastPublishedState = null;
      _announce(client);
      _startHeartbeat();
    }
  }

  /// Exponential backoff capped at 60s: a display in a garage with flaky wifi
  /// should not hammer the broker, and should not need a restart to recover.
  void _scheduleRetry() {
    if (_retry != null) return;
    if (_settings?.mqttConfigured != true) return;
    _retryAttempt = (_retryAttempt + 1).clamp(1, 6);
    final delay = Duration(seconds: (1 << _retryAttempt).clamp(2, 60));
    debugPrint('Aura: MQTT retry in ${delay.inSeconds}s');
    _retry = Timer(delay, () {
      _retry = null;
      if (!isConnected) _connect();
    });
  }

  void _setState(MqttLinkState next) {
    if (_state == next) return;
    _state = next;
    onStateChanged?.call(next);
  }
}
