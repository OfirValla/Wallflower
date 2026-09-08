/// Commands Home Assistant (or anything else) can send to this display.
///
/// Sealed so the executor's `switch` is exhaustive: adding a command is a
/// compile error until it is handled, which is exactly the property you want
/// in a remote-control surface.
///
/// Every command arrives through one of three doors and lands here:
///  * a per-entity MQTT topic (`aura/<node>/cmd/screen`) - what HA Discovery
///    wires the entities to
///  * the generic JSON envelope (`aura/<node>/command`) - for scripts and
///    automations that want one topic
///  * `POST /api/command` on the local REST server
sealed class RemoteCommand {
  const RemoteCommand();

  /// Parses the generic JSON envelope: `{"command": "...", ...}`.
  static RemoteCommand? fromJson(Map<String, dynamic> json) {
    final type = (json['command'] ?? json['type'])?.toString();
    if (type == null) return null;
    switch (type) {
      case 'screen_on':
        return const SetScreen(true);
      case 'screen_off':
        return const SetScreen(false);
      case 'set_screen':
        return SetScreen(_asBool(json['value'] ?? json['on']) ?? true);
      case 'set_brightness':
        final value = _asInt(json['value'] ?? json['brightness']);
        return value == null ? null : SetBrightness(value);
      case 'navigate_to':
        final url = (json['url'] ?? json['value'])?.toString();
        return (url == null || url.isEmpty) ? null : NavigateTo(url);
      case 'reload':
        return Reload(clearCache: _asBool(json['clear_cache']) ?? false);
      case 'load_start_url':
        return const LoadStartUrl();
      case 'bring_to_foreground':
        return const BringToForeground();
      case 'play_audio':
        return PlayAudio(
          text: (json['text'] ?? json['message'])?.toString(),
          url: json['url']?.toString(),
          volume: (json['volume'] as num?)?.toDouble(),
          language: json['language']?.toString(),
        );
      case 'set_motion_detection':
        return SetMotionDetection(_asBool(json['value'] ?? json['enabled']) ?? true);
      case 'eval_js':
        final source = (json['source'] ?? json['script'])?.toString();
        return (source == null || source.isEmpty) ? null : EvalJs(source);
      default:
        return null;
    }
  }

  /// Parses a per-entity MQTT topic suffix plus its raw payload, e.g.
  /// suffix `brightness`, payload `128`.
  static RemoteCommand? fromTopic(String suffix, String payload) {
    final trimmed = payload.trim();
    switch (suffix) {
      case 'screen':
        return SetScreen(trimmed.toUpperCase() != 'OFF');
      case 'brightness':
        final value = int.tryParse(trimmed);
        return value == null ? null : SetBrightness(value);
      case 'navigate':
        return trimmed.isEmpty ? null : NavigateTo(trimmed);
      case 'reload':
        return const Reload();
      case 'foreground':
        return const BringToForeground();
      case 'motion':
        return SetMotionDetection(trimmed.toUpperCase() != 'OFF');
      case 'tts':
        return trimmed.isEmpty ? null : PlayAudio(text: trimmed);
      case 'audio':
        return trimmed.isEmpty ? null : PlayAudio(url: trimmed);
      case 'js':
        return trimmed.isEmpty ? null : EvalJs(trimmed);
      case 'command':
        return null; // handled by the JSON envelope path
      default:
        return null;
    }
  }

  static bool? _asBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final v = value.toLowerCase().trim();
      if (v == 'on' || v == 'true' || v == '1') return true;
      if (v == 'off' || v == 'false' || v == '0') return false;
    }
    return null;
  }

  static int? _asInt(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}

final class SetScreen extends RemoteCommand {
  const SetScreen(this.on);
  final bool on;
}

/// [value] is 0..255 to match Home Assistant's default brightness scale.
final class SetBrightness extends RemoteCommand {
  const SetBrightness(this.value);
  final int value;
}

final class NavigateTo extends RemoteCommand {
  const NavigateTo(this.url);
  final String url;
}

final class Reload extends RemoteCommand {
  const Reload({this.clearCache = false});
  final bool clearCache;
}

final class LoadStartUrl extends RemoteCommand {
  const LoadStartUrl();
}

final class BringToForeground extends RemoteCommand {
  const BringToForeground();
}

/// Either speak [text] via TTS, or play the audio file at [url].
final class PlayAudio extends RemoteCommand {
  const PlayAudio({this.text, this.url, this.volume, this.language});
  final String? text;
  final String? url;
  final double? volume;
  final String? language;
}

final class SetMotionDetection extends RemoteCommand {
  const SetMotionDetection(this.enabled);
  final bool enabled;
}

/// Runs arbitrary JavaScript in the dashboard. Powerful and dangerous - only
/// reachable over MQTT/REST, both of which are on the trusted LAN.
final class EvalJs extends RemoteCommand {
  const EvalJs(this.source);
  final String source;
}
