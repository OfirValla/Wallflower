import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../domain/models/aura_settings.dart';
import '../../domain/models/remote_command.dart';
import '../../providers.dart';
import '../admin/admin_page.dart';

/// The kiosk surface: a full-bleed WebView plus the three things that have to
/// sit above it - the screen-off blackout, the hidden admin hotspot, and a
/// non-intrusive connection banner.
class KioskPage extends ConsumerStatefulWidget {
  const KioskPage({super.key});

  @override
  ConsumerState<KioskPage> createState() => _KioskPageState();
}

class _KioskPageState extends ConsumerState<KioskPage> {
  int _hotspotTaps = 0;
  Timer? _hotspotResetTimer;

  /// `window.Aura` - lets a Home Assistant dashboard drive the kiosk from a
/// custom button card without needing MQTT. Same executor, same commands.
  static const String _bridgeScript = '''
(function () {
  if (window.Aura) return;
  function send(payload) {
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      return window.flutter_inappwebview.callHandler('aura', payload);
    }
  }
  window.Aura = {
    send: send,
    screenOn: function () { return send({ command: 'screen_on' }); },
    screenOff: function () { return send({ command: 'screen_off' }); },
    setBrightness: function (v) { return send({ command: 'set_brightness', value: v }); },
    navigate: function (url) { return send({ command: 'navigate_to', url: url }); },
    reload: function (clearCache) { return send({ command: 'reload', clear_cache: !!clearCache }); },
    speak: function (text, language) {
      return send({ command: 'play_audio', text: text, language: language });
    },
    playAudio: function (url, volume) {
      return send({ command: 'play_audio', url: url, volume: volume });
    },
    loadStartUrl: function () { return send({ command: 'load_start_url' }); }
  };
})();
''';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _hotspotResetTimer?.cancel();
    super.dispose();
  }

  /// Order matters here.
  ///
  /// Permissions first, because the camera pipeline is started by the service
  /// and a denied CAMERA permission would make it fail silently. Then the
  /// native handshake - which starts the foreground service, and is only legal
  /// because this runs after the first frame, i.e. from a visible Activity.
  /// The HA transports come last: they publish telemetry, so they should see a
  /// settled state.
  Future<void> _bootstrap() async {
    final settings = ref.read(settingsControllerProvider);
    await _ensurePermissions(settings);
    await ref.read(kioskControllerProvider.notifier).initialise();
    await ref.read(homeAssistantBridgeProvider).start();
  }

  Future<void> _ensurePermissions(AuraSettings settings) async {
    final wanted = <Permission>[
      Permission.notification,
      if (settings.motionEnabled && settings.motionSource != MotionSource.sensors)
        Permission.camera,
    ];
    for (final Permission permission in wanted) {
      try {
        if (!await permission.isGranted) await permission.request();
      } catch (_) {
        // A Device Owner install auto-grants these; a denial is not fatal.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    final state = ref.watch(kioskControllerProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      // The kiosk owns the whole screen; never let the IME resize the dashboard.
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _buildWebView(settings),
          if (state.loadError != null || !state.online)
            _buildStatusBanner(state.loadError, state.online),
          if (state.adminVisible) const AdminPage(),
          _buildAdminHotspot(),
          _buildScreenOffOverlay(screenOff: !state.screenOn),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------
  // WebView
  // -----------------------------------------------------------------------

  Widget _buildWebView(AuraSettings settings) {
    final controller = ref.read(kioskControllerProvider.notifier);

    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(settings.startUrl)),
      initialUserScripts: UnmodifiableListView<UserScript>(<UserScript>[
        if (settings.enableJsBridge)
          UserScript(
            source: _bridgeScript,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
      ]),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        // A dashboard must be able to autoplay its camera streams and sounds.
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        // Hybrid composition: correct rendering of a full-screen platform view,
        // at the cost of an extra composition step. The right trade for a
        // static dashboard.
        useHybridComposition: true,
        hardwareAcceleration: true,
        transparentBackground: false,
        // Local HA installs are frequently http:// behind an https:// frame.
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        cacheEnabled: true,
        clearCache: settings.clearCacheOnStart,
        cacheMode: CacheMode.LOAD_DEFAULT,
        domStorageEnabled: true,
        databaseEnabled: true,
        thirdPartyCookiesEnabled: true,
        userAgent: settings.userAgent ?? '',
        // Kiosk chrome: no zoom, no scrollbars, no context menu, no overscroll
        // glow. Everything that reveals "this is a browser" is off.
        supportZoom: false,
        builtInZoomControls: false,
        displayZoomControls: false,
        disableContextMenu: true,
        disableLongPressContextMenu: true,
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        overScrollMode: OverScrollMode.NEVER,
        useWideViewPort: true,
        loadWithOverviewMode: true,
        supportMultipleWindows: false,
        javaScriptCanOpenWindowsAutomatically: false,
        algorithmicDarkeningAllowed: true,
      ),
      onWebViewCreated: (InAppWebViewController webViewController) {
        controller.attachWebView(webViewController);
        if (settings.enableJsBridge) {
          webViewController.addJavaScriptHandler(
            handlerName: 'aura',
            callback: (List<dynamic> args) async {
              if (args.isEmpty) return <String, dynamic>{'ok': false};
              final raw = args.first;
              if (raw is! Map) return <String, dynamic>{'ok': false};
              final command = RemoteCommand.fromJson(
                raw.map<String, dynamic>(
                  (Object? k, Object? v) => MapEntry(k.toString(), v),
                ),
              );
              if (command == null) return <String, dynamic>{'ok': false};
              await ref.read(commandExecutorProvider).execute(command);
              return <String, dynamic>{'ok': true};
            },
          );
        }
      },
      onLoadStart: (_, WebUri? url) => controller.onPageStarted(url?.toString()),
      onLoadStop: (_, WebUri? url) => controller.onPageFinished(url?.toString()),
      onTitleChanged: (_, String? title) {},
      onReceivedError: (_, WebResourceRequest request, WebResourceError error) {
        // Sub-resource failures are noise; only a failed main frame means the
        // dashboard is actually broken.
        if (request.isForMainFrame ?? true) {
          controller.onLoadError(error.description);
        }
      },
      onReceivedHttpError: (_, WebResourceRequest request,
          WebResourceResponse response) {
        if ((request.isForMainFrame ?? true) && (response.statusCode ?? 0) >= 500) {
          controller.onLoadError('HTTP ${response.statusCode}');
        }
      },
      // Self-signed certificate handling. PROCEED only when the operator has
      // explicitly opted in; otherwise fail closed.
      onReceivedServerTrustAuthRequest: (_, __) async {
        final allow = ref.read(settingsControllerProvider).allowInsecureSsl;
        return ServerTrustAuthResponse(
          action: allow
              ? ServerTrustAuthResponseAction.PROCEED
              : ServerTrustAuthResponseAction.CANCEL,
        );
      },
      // Grant camera/mic to the dashboard itself (HA camera cards, WebRTC).
      onPermissionRequest: (_, PermissionRequest request) async {
        return PermissionResponse(
          resources: request.resources,
          action: PermissionResponseAction.GRANT,
        );
      },
      onRenderProcessGone: (_, RenderProcessGoneDetail detail) {
        controller.onRenderProcessGone();
      },
    );
  }

  // -----------------------------------------------------------------------
  // Overlays
  // -----------------------------------------------------------------------

  /// The "screen off" blackout for [ScreenOffMode.dim].
  ///
  /// Backlight is already at 0 - this covers the panel so an LCD's leakage
  /// shows black rather than a dim dashboard, and it swallows the first touch
  /// so waking the display never also presses a button underneath.
  Widget _buildScreenOffOverlay({required bool screenOff}) {
    return IgnorePointer(
      ignoring: !screenOff,
      child: AnimatedOpacity(
        opacity: screenOff ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => ref.read(kioskControllerProvider.notifier).handleWakeTap(),
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    );
  }

  /// Invisible 64x64 corner target. Four taps within three seconds opens the
  /// PIN gate. A visible settings button would be the first thing a visitor
  /// presses; a gesture nobody knows about is the point.
  Widget _buildAdminHotspot() {
    return Positioned(
      top: 0,
      left: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _registerHotspotTap,
        child: const SizedBox(width: 64, height: 64),
      ),
    );
  }

  void _registerHotspotTap() {
    _hotspotTaps++;
    _hotspotResetTimer?.cancel();
    _hotspotResetTimer = Timer(const Duration(seconds: 3), () {
      _hotspotTaps = 0;
    });

    if (_hotspotTaps >= 4) {
      _hotspotTaps = 0;
      _hotspotResetTimer?.cancel();
      ref.read(kioskControllerProvider.notifier).showAdmin();
    }
  }

  Widget _buildStatusBanner(String? error, bool online) {
    final message = !online
        ? 'Network unavailable - retrying'
        : 'Load failed: $error - retrying';

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: Colors.black.withValues(alpha: 0.72),
          child: Row(
            children: <Widget>[
              const Icon(Icons.cloud_off, size: 16, color: Colors.white70),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
