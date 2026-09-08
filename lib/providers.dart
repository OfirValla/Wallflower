import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'domain/models/aura_settings.dart';
import 'domain/repositories/settings_repository.dart';
import 'features/kiosk/kiosk_controller.dart';
import 'integration/audio_announcer.dart';
import 'integration/command_executor.dart';
import 'integration/home_assistant_bridge.dart';
import 'platform/aura_platform.dart';
import 'platform/device_identity.dart';

// ---------------------------------------------------------------------------
// Bootstrap injections
//
// These three are resolved asynchronously in main() and injected as overrides.
// Doing it that way instead of with FutureProviders means every consumer sees
// plain synchronous values, so no widget in the tree ever renders a loading
// state for something that was ready before the first frame.
// ---------------------------------------------------------------------------

final initialSettingsProvider = Provider<AuraSettings>(
  (Ref ref) => throw UnimplementedError('Override initialSettingsProvider in main()'),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (Ref ref) => throw UnimplementedError('Override settingsRepositoryProvider in main()'),
);

final deviceIdentityProvider = Provider<DeviceIdentity>(
  (Ref ref) => throw UnimplementedError('Override deviceIdentityProvider in main()'),
);

// ---------------------------------------------------------------------------
// Platform & services
// ---------------------------------------------------------------------------

final auraPlatformProvider = Provider<AuraPlatform>((Ref ref) => AuraPlatform());

final audioAnnouncerProvider = Provider<AudioAnnouncer>((Ref ref) {
  final announcer = AudioAnnouncer();
  ref.onDispose(announcer.dispose);
  return announcer;
});

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/// Single writer for [AuraSettings].
///
/// Every mutation goes through [update], which does three things in order:
/// publish the new state to the UI, persist it, then push the native slice
/// down. UI-first is deliberate - a switch in the admin panel should feel
/// instant, and a slow keystore write must not make it stutter.
class SettingsController extends Notifier<AuraSettings> {
  @override
  AuraSettings build() => ref.read(initialSettingsProvider);

  Future<void> update(AuraSettings Function(AuraSettings current) mutate) async {
    final next = mutate(state);
    state = next;
    try {
      await ref.read(settingsRepositoryProvider).save(next);
    } catch (error) {
      debugPrint('Aura: settings save failed: $error');
    }
    await ref.read(auraPlatformProvider).pushConfig(next);
  }

  Future<void> replace(AuraSettings next) => update((_) => next);

  Future<void> resetToDefaults() async {
    await ref.read(settingsRepositoryProvider).reset();
    state = const AuraSettings();
    await ref.read(auraPlatformProvider).pushConfig(state);
  }
}

final settingsControllerProvider =
    NotifierProvider<SettingsController, AuraSettings>(SettingsController.new);

// ---------------------------------------------------------------------------
// Kiosk surface
// ---------------------------------------------------------------------------

final kioskControllerProvider =
    NotifierProvider<KioskController, KioskState>(KioskController.new);

/// The command funnel. Its [WebSurface] is resolved lazily on every call, so a
/// WebView recreation never leaves remote control pointing at a dead
/// controller.
final commandExecutorProvider = Provider<CommandExecutor>((Ref ref) {
  return CommandExecutor(
    platform: ref.read(auraPlatformProvider),
    audio: ref.read(audioAnnouncerProvider),
    surfaceProvider: () => ref.read(kioskControllerProvider.notifier),
    mutateSettings: (AuraSettings Function(AuraSettings) mutate) =>
        ref.read(settingsControllerProvider.notifier).update(mutate),
  );
});

// ---------------------------------------------------------------------------
// Home Assistant
// ---------------------------------------------------------------------------

final homeAssistantBridgeProvider = Provider<HomeAssistantBridge>((Ref ref) {
  final bridge = HomeAssistantBridge(
    identity: ref.read(deviceIdentityProvider),
    readSettings: () => ref.read(settingsControllerProvider),
    readSnapshot: () => ref.read(kioskControllerProvider).toSnapshot(),
    executor: ref.read(commandExecutorProvider),
  );

  // ref.listen must be registered during provider construction.
  ref.listen<AuraSettings>(
    settingsControllerProvider,
    (AuraSettings? previous, AuraSettings next) => bridge.onSettingsChanged(next),
  );
  ref.listen<KioskState>(
    kioskControllerProvider,
    (KioskState? previous, KioskState next) => bridge.onKioskStateChanged(),
  );

  ref.onDispose(bridge.dispose);
  return bridge;
});
