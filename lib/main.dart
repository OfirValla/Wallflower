import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/aura_app.dart';
import 'data/settings/settings_repository_impl.dart';
import 'domain/models/aura_settings.dart';
import 'domain/repositories/settings_repository.dart';
import 'platform/device_identity.dart';
import 'providers.dart';

/// Boot sequence.
///
/// Settings and device identity are resolved *before* the first frame and
/// injected as provider overrides. That costs a few hundred milliseconds of
/// black screen on a cold start and buys something worth much more on a wall
/// display: the dashboard's first frame is the real dashboard, at the right
/// brightness, at the configured URL - never a loading spinner that an
/// operator has to watch every time the panel reboots.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Native KioskManager owns immersive mode for the long run, but asking for
  // it here means frame one is already fullscreen instead of flashing bars.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // A crash loop on a wall-mounted tablet is invisible - nobody is watching a
  // console. Log loudly and keep going wherever we can.
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('Aura: uncaught Flutter error: ${details.exception}');
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('Aura: uncaught platform error: $error');
    debugPrintStack(stackTrace: stack);
    return true;
  };

  final SettingsRepository repository = SettingsRepositoryImpl();
  final AuraSettings settings = await repository.load();
  final DeviceIdentity identity = await DeviceIdentity.load();

  debugPrint(
    'Aura: booting ${identity.model} node=${identity.nodeId} '
    'url=${settings.startUrl}',
  );

  runApp(
    ProviderScope(
      overrides: <Override>[
        settingsRepositoryProvider.overrideWithValue(repository),
        initialSettingsProvider.overrideWithValue(settings),
        deviceIdentityProvider.overrideWithValue(identity),
      ],
      child: const AuraApp(),
    ),
  );
}
