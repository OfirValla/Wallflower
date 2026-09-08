import 'package:aura_display/app/aura_app.dart';
import 'package:aura_display/domain/models/aura_settings.dart';
import 'package:aura_display/domain/repositories/settings_repository.dart';
import 'package:aura_display/features/admin/admin_page.dart';
import 'package:aura_display/features/kiosk/kiosk_page.dart';
import 'package:aura_display/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory stand-in, which is the whole reason [SettingsRepository] is an
/// interface.
class _FakeRepository implements SettingsRepository {
  AuraSettings? saved;

  @override
  Future<AuraSettings> load() async => saved ?? const AuraSettings();

  @override
  Future<void> save(AuraSettings settings) async => saved = settings;

  @override
  Future<void> reset() async => saved = null;
}

void main() {
  List<Override> overrides(_FakeRepository repository) => <Override>[
        settingsRepositoryProvider.overrideWithValue(repository),
        initialSettingsProvider.overrideWithValue(const AuraSettings()),
      ];

  /// The real root, so the boot gate itself is under test.
  Future<_FakeRepository> pumpApp(WidgetTester tester) async {
    final _FakeRepository repository = _FakeRepository();
    await tester.pumpWidget(
      ProviderScope(overrides: overrides(repository), child: const AuraApp()),
    );
    await tester.pumpAndSettle();
    return repository;
  }

  /// The setup screen alone, in the same shell the boot gate gives it.
  ///
  /// Saving here does not swap in the kiosk, which keeps the form's own
  /// behaviour testable - see the handover test for why that matters.
  Future<_FakeRepository> pumpForm(WidgetTester tester) async {
    final _FakeRepository repository = _FakeRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(repository),
        child: const MaterialApp(
          home: Scaffold(
            backgroundColor: Color(0xFF0B1220),
            body: AdminPage(firstRun: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return repository;
  }

  group('boot gate', () {
    testWidgets('a fresh install boots into setup, not the dashboard',
        (WidgetTester tester) async {
      await pumpApp(tester);

      expect(find.text('Set up Aura Display'), findsOneWidget);
      expect(find.text('Save & start'), findsOneWidget);
      // Nothing to close back to yet.
      expect(find.text('Close'), findsNothing);
      // The URL field is the point of the screen, and it is prefilled.
      expect(find.text('http://homeassistant.local:8123'), findsOneWidget);
      // Reachable without knowing a PIN.
      expect(find.text('Unlock'), findsNothing);
    });

    testWidgets('completing setup hands over to the kiosk',
        (WidgetTester tester) async {
      await pumpApp(tester);

      await tester.tap(find.text('Save & start'));
      await tester.pump();

      // The kiosk surface is a platform WebView, which this harness cannot
      // instantiate - it throws while building. Swallowing that assertion is
      // the price of proving the gate handed over instead of staying put;
      // rendering the WebView itself needs a device.
      expect(tester.takeException(), isAssertionError);
      expect(find.byType(KioskPage), findsOneWidget);
      expect(find.text('Set up Aura Display'), findsNothing);
    });
  });

  group('setup form', () {
    testWidgets('offers the motion wake switch', (WidgetTester tester) async {
      await pumpForm(tester);

      await tester.dragUntilVisible(
        find.text('Wake the display on motion'),
        find.byType(ListView),
        const Offset(0, -120),
      );
      expect(find.text('Wake the display on motion'), findsOneWidget);
    });

    testWidgets('stores a bare host as a URL and completes setup',
        (WidgetTester tester) async {
      final _FakeRepository repository = await pumpForm(tester);

      await tester.enterText(find.byType(TextField).first, 'ha.local:8123');
      await tester.tap(find.text('Save & start'));
      await tester.pumpAndSettle();

      expect(repository.saved, isNotNull);
      expect(repository.saved!.startUrl, 'http://ha.local:8123');
      expect(repository.saved!.setupComplete, isTrue);
      // The normalisation is shown, not applied silently.
      expect(find.text('http://ha.local:8123'), findsOneWidget);
    });

    testWidgets('refuses to save a URL that would strand the panel',
        (WidgetTester tester) async {
      final _FakeRepository repository = await pumpForm(tester);

      await tester.enterText(find.byType(TextField).first, '   ');
      await tester.tap(find.text('Save & start'));
      await tester.pumpAndSettle();

      expect(repository.saved, isNull);
      expect(
        find.text('Enter the dashboard address, e.g. homeassistant.local:8123'),
        findsOneWidget,
      );
    });
  });
}
