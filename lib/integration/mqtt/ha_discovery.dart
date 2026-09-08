/// One retained MQTT Discovery config message.
class DiscoveryMessage {
  const DiscoveryMessage(this.topic, this.payload);

  final String topic;
  final Map<String, dynamic> payload;
}

/// Builds the Home Assistant MQTT Discovery surface for one Aura unit.
///
/// Topic layout:
/// ```
/// aura/<node>/state            <- single retained JSON telemetry document
/// aura/<node>/availability     <- "online" / "offline" (offline is the LWT)
/// aura/<node>/cmd/<entity>     <- per-entity command topics (HA writes here)
/// aura/<node>/command          <- generic JSON envelope for automations
/// <prefix>/status              <- HA birth/will; triggers a discovery replay
/// ```
///
/// Design notes worth knowing before you edit this file:
///
/// * **One state topic, many templates.** Every sensor pulls its value out of
///   the same retained JSON document with a `value_template`. That is one
///   publish per update instead of a dozen, and after an HA restart a single
///   retained message repopulates every entity.
/// * **Availability is the LWT.** The broker publishes `offline` for us if the
///   tablet drops off the wifi, so entities go unavailable rather than showing
///   stale values - which matters a lot when the entity is a battery level.
/// * **`has_entity_name: true`.** Entities are named relative to their device,
///   so they show up as "Hallway Tablet Screen", not "Screen".
/// * **The screen is a `light`, not a `switch`.** It has brightness, so
///   modelling it as a light gets the operator a real brightness slider, HA's
///   built-in transitions and `light.turn_on` semantics for free.
class HaDiscovery {
  HaDiscovery({
    required this.nodeId,
    required this.deviceName,
    required this.discoveryPrefix,
    required this.manufacturer,
    required this.model,
    required this.swVersion,
    this.configurationUrl,
  });

  /// Stable per-device id. Derived from ANDROID_ID, so it survives reinstalls
  /// but changes on factory reset.
  final String nodeId;
  final String deviceName;
  final String discoveryPrefix;
  final String manufacturer;
  final String model;
  final String swVersion;

  /// Shown as "Visit device" in HA. Points at the local REST server.
  final String? configurationUrl;

  String get baseTopic => 'aura/$nodeId';
  String get stateTopic => '$baseTopic/state';
  String get availabilityTopic => '$baseTopic/availability';
  String get commandWildcard => '$baseTopic/cmd/#';
  String get commandEnvelopeTopic => '$baseTopic/command';
  String get haStatusTopic => '$discoveryPrefix/status';

  static const String payloadOnline = 'online';
  static const String payloadOffline = 'offline';

  String commandTopic(String suffix) => '$baseTopic/cmd/$suffix';

  /// Returns the suffix of a `aura/<node>/cmd/<suffix>` topic, or null.
  String? commandSuffixOf(String topic) {
    final prefix = '$baseTopic/cmd/';
    if (!topic.startsWith(prefix)) return null;
    return topic.substring(prefix.length);
  }

  Map<String, dynamic> get _device => <String, dynamic>{
        'identifiers': <String>['aura_$nodeId'],
        'name': deviceName,
        'manufacturer': manufacturer,
        'model': model,
        'sw_version': swVersion,
        if (configurationUrl != null) 'configuration_url': configurationUrl,
      };

  Map<String, dynamic> get _origin => <String, dynamic>{
        'name': 'Aura Display',
        'sw_version': swVersion,
        'support_url': 'https://github.com/ofirvalla/AuraDisplay',
      };

  Map<String, dynamic> _base(String objectId) => <String, dynamic>{
        'unique_id': 'aura_${nodeId}_$objectId',
        'has_entity_name': true,
        'availability_topic': availabilityTopic,
        'payload_available': payloadOnline,
        'payload_not_available': payloadOffline,
        'device': _device,
        'origin': _origin,
      };

  String _configTopic(String component, String objectId) =>
      '$discoveryPrefix/$component/aura_$nodeId/$objectId/config';

  /// The full entity set. Publish retained; republish on HA's birth message.
  List<DiscoveryMessage> build() => <DiscoveryMessage>[
        _screenLight(),
        _motionSensor(),
        _motionSwitch(),
        _batterySensor(),
        _chargingSensor(),
        _illuminanceSensor(),
        _urlSensor(),
        _kioskSensor(),
        _reloadButton(),
        _foregroundButton(),
        _urlText(),
        _ttsNotify(),
      ];

  /// Topics that must be cleared to remove this device from HA.
  List<String> configTopics() =>
      build().map((DiscoveryMessage m) => m.topic).toList(growable: false);

  // -----------------------------------------------------------------------
  // Entities
  // -----------------------------------------------------------------------

  DiscoveryMessage _screenLight() => DiscoveryMessage(
        _configTopic('light', 'screen'),
        <String, dynamic>{
          ..._base('screen'),
          'name': 'Screen',
          'icon': 'mdi:tablet-dashboard',
          'schema': 'basic',
          'state_topic': stateTopic,
          'state_value_template': "{{ 'ON' if value_json.screen_on else 'OFF' }}",
          'command_topic': commandTopic('screen'),
          'payload_on': 'ON',
          'payload_off': 'OFF',
          'brightness_state_topic': stateTopic,
          'brightness_value_template': '{{ value_json.brightness }}',
          'brightness_command_topic': commandTopic('brightness'),
          'brightness_scale': 255,
          // "first" = send ON, then the brightness. Without it HA sends only
          // the brightness on turn-on and the screen never comes back.
          'on_command_type': 'first',
        },
      );

  DiscoveryMessage _motionSensor() => DiscoveryMessage(
        _configTopic('binary_sensor', 'motion'),
        <String, dynamic>{
          ..._base('motion'),
          'name': 'Motion',
          'device_class': 'motion',
          'state_topic': stateTopic,
          'value_template': "{{ 'ON' if value_json.motion else 'OFF' }}",
          'payload_on': 'ON',
          'payload_off': 'OFF',
          'json_attributes_topic': stateTopic,
          'json_attributes_template':
              '{{ {"source": value_json.motion_source} | tojson }}',
        },
      );

  DiscoveryMessage _motionSwitch() => DiscoveryMessage(
        _configTopic('switch', 'motion_detection'),
        <String, dynamic>{
          ..._base('motion_detection'),
          'name': 'Motion detection',
          'icon': 'mdi:motion-sensor',
          'entity_category': 'config',
          'state_topic': stateTopic,
          'value_template': "{{ 'ON' if value_json.motion_enabled else 'OFF' }}",
          'command_topic': commandTopic('motion'),
          'payload_on': 'ON',
          'payload_off': 'OFF',
        },
      );

  DiscoveryMessage _batterySensor() => DiscoveryMessage(
        _configTopic('sensor', 'battery'),
        <String, dynamic>{
          ..._base('battery'),
          'name': 'Battery',
          'device_class': 'battery',
          'state_class': 'measurement',
          'unit_of_measurement': '%',
          'entity_category': 'diagnostic',
          'state_topic': stateTopic,
          // A mains-only display reports -1; suppress it rather than graphing it.
          'value_template':
              '{% if value_json.battery >= 0 %}{{ value_json.battery }}{% endif %}',
        },
      );

  DiscoveryMessage _chargingSensor() => DiscoveryMessage(
        _configTopic('binary_sensor', 'charging'),
        <String, dynamic>{
          ..._base('charging'),
          'name': 'Charging',
          'device_class': 'battery_charging',
          'entity_category': 'diagnostic',
          'state_topic': stateTopic,
          'value_template': "{{ 'ON' if value_json.charging else 'OFF' }}",
          'payload_on': 'ON',
          'payload_off': 'OFF',
        },
      );

  DiscoveryMessage _illuminanceSensor() => DiscoveryMessage(
        _configTopic('sensor', 'illuminance'),
        <String, dynamic>{
          ..._base('illuminance'),
          'name': 'Illuminance',
          'device_class': 'illuminance',
          'state_class': 'measurement',
          'unit_of_measurement': 'lx',
          'entity_category': 'diagnostic',
          'state_topic': stateTopic,
          'value_template':
              '{% if value_json.illuminance is not none %}'
                  '{{ value_json.illuminance | round(1) }}{% endif %}',
        },
      );

  DiscoveryMessage _urlSensor() => DiscoveryMessage(
        _configTopic('sensor', 'current_url'),
        <String, dynamic>{
          ..._base('current_url'),
          'name': 'Current URL',
          'icon': 'mdi:web',
          'entity_category': 'diagnostic',
          'state_topic': stateTopic,
          // Entity states are capped at 255 characters by HA.
          'value_template': '{{ value_json.url | truncate(250, true) }}',
          'json_attributes_topic': stateTopic,
          'json_attributes_template':
              '{{ {"full_url": value_json.url, "title": value_json.title} | tojson }}',
        },
      );

  DiscoveryMessage _kioskSensor() => DiscoveryMessage(
        _configTopic('binary_sensor', 'kiosk_locked'),
        <String, dynamic>{
          ..._base('kiosk_locked'),
          'name': 'Kiosk locked',
          'icon': 'mdi:lock',
          'entity_category': 'diagnostic',
          'state_topic': stateTopic,
          'value_template': "{{ 'ON' if value_json.kiosk_active else 'OFF' }}",
          'payload_on': 'ON',
          'payload_off': 'OFF',
        },
      );

  DiscoveryMessage _reloadButton() => DiscoveryMessage(
        _configTopic('button', 'reload'),
        <String, dynamic>{
          ..._base('reload'),
          'name': 'Reload dashboard',
          'icon': 'mdi:refresh',
          'command_topic': commandTopic('reload'),
          'payload_press': 'PRESS',
        },
      );

  DiscoveryMessage _foregroundButton() => DiscoveryMessage(
        _configTopic('button', 'bring_to_foreground'),
        <String, dynamic>{
          ..._base('bring_to_foreground'),
          'name': 'Bring to foreground',
          'icon': 'mdi:open-in-app',
          'command_topic': commandTopic('foreground'),
          'payload_press': 'PRESS',
        },
      );

  DiscoveryMessage _urlText() => DiscoveryMessage(
        _configTopic('text', 'navigate'),
        <String, dynamic>{
          ..._base('navigate'),
          'name': 'Navigate to',
          'icon': 'mdi:link-variant',
          'command_topic': commandTopic('navigate'),
          'state_topic': stateTopic,
          'value_template': '{{ value_json.url | truncate(250, true) }}',
          'mode': 'text',
          // HA's hard limit for the text platform. Longer URLs must go through
          // the JSON envelope topic.
          'max': 255,
        },
      );

  DiscoveryMessage _ttsNotify() => DiscoveryMessage(
        _configTopic('notify', 'tts'),
        <String, dynamic>{
          ..._base('tts'),
          'name': 'Speak',
          'icon': 'mdi:account-voice',
          'command_topic': commandTopic('tts'),
          'command_template': '{{ value }}',
        },
      );
}
