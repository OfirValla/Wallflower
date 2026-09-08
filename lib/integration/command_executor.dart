import 'package:flutter/foundation.dart';

import '../domain/models/aura_settings.dart';
import '../domain/models/remote_command.dart';
import '../platform/aura_platform.dart';
import 'audio_announcer.dart';

/// The WebView operations a command can trigger.
///
/// An interface rather than a direct dependency on the page: the executor is
/// created during app bootstrap, long before any `InAppWebViewController`
/// exists, and it must keep working across a WebView recreation.
abstract interface class WebSurface {
  Future<void> navigate(String url);

  Future<void> reload({bool clearCache = false});

  Future<void> loadStartUrl();

  Future<void> evaluateJavascript(String source);
}

/// Single funnel for every inbound command, whatever door it came through.
///
/// One funnel matters more than it looks: MQTT, the REST API and the in-page
/// JS bridge must produce byte-identical behaviour, or operators end up
/// debugging why `screen_off` works from an automation but not from a
/// dashboard button.
class CommandExecutor {
  CommandExecutor({
    required AuraPlatform platform,
    required AudioAnnouncer audio,
    required WebSurface? Function() surfaceProvider,
    required Future<void> Function(AuraSettings Function(AuraSettings)) mutateSettings,
  })  : _platform = platform,
        _audio = audio,
        _surfaceProvider = surfaceProvider,
        _mutateSettings = mutateSettings;

  final AuraPlatform _platform;
  final AudioAnnouncer _audio;
  final WebSurface? Function() _surfaceProvider;
  final Future<void> Function(AuraSettings Function(AuraSettings)) _mutateSettings;

  Future<void> execute(RemoteCommand command) async {
    debugPrint('Aura: executing ${command.runtimeType}');
    try {
      // Exhaustive by construction - adding a RemoteCommand subtype without
      // handling it here is a compile error.
      switch (command) {
        case SetScreen(:final on):
          await _platform.setScreen(on: on);

        case SetBrightness(:final value):
          final clamped = value.clamp(0, 255);
          await _platform.setBrightness(clamped);
          // Persist so the level survives a restart, which is what an operator
          // expects after dragging HA's brightness slider.
          await _mutateSettings((s) => s.copyWith(brightness: clamped));

        case NavigateTo(:final url):
          await _surfaceProvider()?.navigate(url);

        case Reload(:final clearCache):
          await _surfaceProvider()?.reload(clearCache: clearCache);

        case LoadStartUrl():
          await _surfaceProvider()?.loadStartUrl();

        case BringToForeground():
          await _platform.bringToForeground();

        case PlayAudio(:final text, :final url, :final volume, :final language):
          if (url != null && url.isNotEmpty) {
            await _audio.playUrl(url, volume: volume);
          } else if (text != null && text.isNotEmpty) {
            await _audio.speak(text, language: language, volume: volume);
          }

        case SetMotionDetection(:final enabled):
          // Settings are the source of truth; the change is pushed to native
          // by the settings controller, which restarts the camera pipeline.
          await _mutateSettings((s) => s.copyWith(motionEnabled: enabled));

        case EvalJs(:final source):
          await _surfaceProvider()?.evaluateJavascript(source);
      }
    } catch (error, stack) {
      // A bad command must never take the display down.
      debugPrint('Aura: command ${command.runtimeType} failed: $error');
      debugPrintStack(stackTrace: stack);
    }
  }
}
