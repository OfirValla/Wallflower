import 'package:flutter/material.dart';

import '../features/kiosk/kiosk_page.dart';

/// Root widget.
///
/// There is exactly one route. A kiosk with a Navigator stack is a kiosk that
/// can end up somewhere unexpected after a stray gesture, so the admin panel
/// is a layer in the kiosk [Stack] rather than a pushed route.
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
      home: const KioskPage(),
    );
  }
}
