import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Handles the `play_audio` command: either speak text or play a sound file.
///
/// Both engines are created lazily. On a display that never receives an audio
/// command, neither the TTS service nor an audio focus request is ever touched.
class AudioAnnouncer {
  FlutterTts? _tts;
  AudioPlayer? _player;

  Future<void> speak(
    String text, {
    String? language,
    double? volume,
  }) async {
    if (text.trim().isEmpty) return;
    try {
      final tts = _tts ??= FlutterTts();
      if (language != null && language.isNotEmpty) {
        await tts.setLanguage(language);
      }
      if (volume != null) {
        await tts.setVolume(volume.clamp(0.0, 1.0));
      }
      // Queue rather than interrupt: two automations firing at once should
      // produce two announcements, not half of one.
      await tts.awaitSpeakCompletion(true);
      await tts.speak(text);
    } catch (error) {
      debugPrint('Aura: TTS failed: $error');
    }
  }

  Future<void> playUrl(String url, {double? volume}) async {
    if (url.trim().isEmpty) return;
    try {
      final player = _player ??= AudioPlayer();
      if (volume != null) await player.setVolume(volume.clamp(0.0, 1.0));
      await player.play(UrlSource(url));
    } catch (error) {
      debugPrint('Aura: audio playback failed: $error');
    }
  }

  Future<void> stop() async {
    await _tts?.stop();
    await _player?.stop();
  }

  Future<void> dispose() async {
    await _tts?.stop();
    await _player?.dispose();
    _tts = null;
    _player = null;
  }
}
