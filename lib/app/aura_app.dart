import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/aura_settings.dart';
import '../features/admin/admin_page.dart';
import '../features/kiosk/kiosk_page.dart';
import '../providers.dart';

/// Root widget.
///
/// There is exactly one route. A kiosk with a Navigator stack is a kiosk that
/// can end up somewhere unexpected after a stray gesture, so the admin panel
/// is a layer in the kiosk [Stack] rather than a pushed route, and first-run
/// setup swaps the whole home widget instead of pushing over it.
class AuraApp extends StatelessWidget {
  const AuraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aura Display',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF38BDF8),
        scaffoldBackgroundColor: Colors.black,
      ),
      // Never let a system font-scale setting reflow a dashboard that was
      // laid out for this exact panel.
      builder: (BuildContext context, Widget? child) => MediaQuery.withNoTextScaling(
        child: child ?? const SizedBox.shrink(),
      ),
      home: const _BootGate(),
    );
  }
}

/// Picks between first-run setup and the kiosk.
///
/// Gating here rather than inside [KioskPage] means the WebView, the native
/// lockdown handshake and the Home Assistant transports do not start at all
/// until a dashboard URL exists. A fresh install has nothing to point them at,
/// and starting them anyway just produces a failed load of the placeholder URL
/// behind an admin gesture nobody can guess.
///
/// This also runs in reverse: "Reset all settings" clears
/// [AuraSettings.setupComplete], which drops the panel back to setup rather
/// than to a dashboard pointed at a URL the operator just erased.
class _BootGate extends ConsumerWidget {
  const _BootGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool configured = ref.watch(
      settingsControllerProvider.select(
        (AuraSettings settings) => settings.setupComplete,
      ),
    );

    if (configured) return const KioskPage();

    // A Scaffold that yields to the keyboard. The in-kiosk admin overlay sits
    // in a Scaffold with resizeToAvoidBottomInset: false, which is right for a
    // dashboard but would hide the URL field under the IME on the one screen
    // whose entire job is typing a URL.
    return const Scaffold(
      backgroundColor: Color(0xFF0B1220),
      body: AdminPage(firstRun: true),
    );
  }
}
