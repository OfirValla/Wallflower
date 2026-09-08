import 'package:aura_display/domain/models/aura_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AuraSettings.normalizeStartUrl', () {
    test('adds a scheme to the bare host everyone actually types', () {
      expect(
        AuraSettings.normalizeStartUrl('homeassistant.local:8123'),
        'http://homeassistant.local:8123',
      );
      expect(
        AuraSettings.normalizeStartUrl('192.168.1.50:8123'),
        'http://192.168.1.50:8123',
      );
    });

    test('leaves an already-absolute URL alone', () {
      expect(
        AuraSettings.normalizeStartUrl('https://ha.example.com/lovelace/0'),
        'https://ha.example.com/lovelace/0',
      );
    });

    test('trims surrounding whitespace', () {
      expect(
        AuraSettings.normalizeStartUrl('  http://ha.local  '),
        'http://ha.local',
      );
    });

    test('rejects input that would strand the panel on a blank page', () {
      expect(AuraSettings.normalizeStartUrl(''), isNull);
      expect(AuraSettings.normalizeStartUrl('   '), isNull);
      expect(AuraSettings.normalizeStartUrl('about:blank'), isNull);
      expect(AuraSettings.normalizeStartUrl('ftp://files.local'), isNull);
      expect(AuraSettings.normalizeStartUrl('http://'), isNull);
    });
  });

  group('AuraSettings.setupComplete', () {
    test('defaults to false on a fresh install', () {
      expect(const AuraSettings().setupComplete, isFalse);
    });

    test('round-trips through JSON', () {
      final AuraSettings saved =
          const AuraSettings().copyWith(setupComplete: true);
      expect(AuraSettings.fromJson(saved.toJson()).setupComplete, isTrue);
    });

    test('treats a blob predating the flag as already configured', () {
      // What an upgrading install has on disk: a real blob, no setupComplete.
      final Map<String, dynamic> legacy = const AuraSettings().toJson()
        ..remove('setupComplete');
      expect(AuraSettings.fromJson(legacy).setupComplete, isTrue);
    });

    test('an empty map is not configured', () {
      expect(AuraSettings.fromJson(<String, dynamic>{}).setupComplete, isFalse);
    });
  });
}
