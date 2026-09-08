import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/aura_settings.dart';
import '../../domain/models/device_snapshot.dart';
import '../../integration/command_executor.dart';
import '../../platform/aura_platform.dart';
import '../../providers.dart';

/// Observable state of the kiosk surface.
@immutable
class KioskState {
  const KioskState({
    this.screenOn = true,
    this.brightness = 255,
    this.motionDetected = false,
    this.motionSource,
    this.illuminance,
    this.currentUrl = '',
    this.pageTitle,
    this.loading = true,
    this.loadError,
    this.online = true,
    this.adminVisible = false,
    this.nativeStatus = const <String, dynamic>{},
  });

  final bool screenOn;
  final int brightness;
  final bool motionDetected;
  final String? motionSource;
  final double? illuminance;

  final String currentUrl;
  final String? pageTitle;
  final bool loading;
  final String? loadError;
  final bool online;

  final bool adminVisible;

  /// Raw capability/status map from native: deviceOwner, lockTaskActive,
  /// canDrawOverlays, cameraRunning, ... Rendered by the admin diagnostics.
  final Map<String, dynamic> nativeStatus;

  bool get kioskLocked => nativeStatus['lockTaskActive'] == true;
  bool get isDeviceOwner => nativeStatus['deviceOwner'] == true;

  KioskState copyWith({
    bool? screenOn,
    int? brightness,
    bool? motionDetected,
    String? motionSource,
    double? illuminance,
    String? currentUrl,
    String? pageTitle,
    bool? loading,
    Object? loadError = _unset,
    bool? online,
    bool? adminVisible,
    Map<String, dynamic>? nativeStatus,
  }) {
    return KioskState(
      screenOn: screenOn ?? this.screenOn,
      brightness: brightness ?? this.brightness,
      motionDetected: motionDetected ?? this.motionDetected,
      motionSource: motionSource ?? this.motionSource,
      illuminance: illuminance ?? this.illuminance,
      currentUrl: currentUrl ?? this.currentUrl,
      pageTitle: pageTitle ?? this.pageTitle,
      loading: loading ?? this.loading,
      loadError: loadError == _unset ? this.loadError : loadError as String?,
      online: online ?? this.online,
      adminVisible: adminVisible ?? this.adminVisible,
      nativeStatus: nativeStatus ?? this.nativeStatus,
    );
  }

  /// Projects presentation state down to the domain snapshot the Home
  /// Assistant bridge consumes, so `integration/` never imports `features/`.
  DeviceSnapshot toSnapshot() => DeviceSnapshot(
        screenOn: screenOn,
        brightness: brightness,
        motionDetected: motionDetected,
        motionSource: motionSource,
        illuminance: illuminance,
        currentUrl: currentUrl,
        pageTitle: pageTitle,
        kioskLocked: kioskLocked,
        deviceOwner: isDeviceOwner,
        nativeStatus: nativeStatus,
      );

  static const Object _unset = Object();
}

/// Orchestrates the kiosk surface: the WebView, the native lockdown handshake,
/// crash/network recovery, and the admin panel's visibility.
///
/// It also *is* the [WebSurface] the command executor drives, which is why the
/// executor takes a provider function rather than an instance - the controller
/// outlives any individual `InAppWebViewController`, and a WebView recreation
/// must not break remote control.
class KioskController extends Notifier<KioskState> implements WebSurface {
  InAppWebViewController? _webView;
  StreamSubscription<NativeEvent>? _nativeEvents;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Timer? _periodicReload;
  Timer? _errorRetry;
  int _errorRetryAttempt = 0;

  @override
  KioskState build() {
    final settings = ref.read(settingsControllerProvider);

    // ref.listen, not ref.watch: watching would re-run build() and reset the
    // whole surface every time a setting changes.
    ref.listen<AuraSettings>(
      settingsControllerProvider,
      (AuraSettings? previous, AuraSettings next) =>
          _onSettingsChanged(previous, next),
    );

    ref.onDispose(_disposeResources);

    _subscribeNativeEvents();
    _subscribeConnectivity();
    _schedulePeriodicReload(settings.periodicReloadMinutes);

    return KioskState(
      brightness: settings.brightness,
      currentUrl: settings.startUrl,
    );
  }

  // -----------------------------------------------------------------------
  // Bootstrap
  // -----------------------------------------------------------------------

  /// Native handshake. Called once from the page after first frame, so the
  /// foreground service is started from a *visible* Activity - which is what
  /// makes a camera-type FGS legal.
  Future<void> initialise() async {
    final platform = ref.read(auraPlatformProvider);
    final settings = ref.read(settingsControllerProvider);

    await platform.pushConfig(settings);
    if (settings.kioskEnabled) {
      final status = await platform.engageKiosk();
      if (status.isNotEmpty) state = state.copyWith(nativeStatus: status);
    }
    await platform.startService();
    await platform.setBrightness(settings.brightness);
  }

  // -----------------------------------------------------------------------
  // WebView wiring
  // -----------------------------------------------------------------------

  void attachWebView(InAppWebViewController controller) {
    _webView = controller;
  }

  void detachWebView() {
    _webView = null;
  }

  void onPageStarted(String? url) {
    state = state.copyWith(
      loading: true,
      loadError: null,
      currentUrl: url ?? state.currentUrl,
    );
  }

  Future<void> onPageFinished(String? url) async {
    _errorRetryAttempt = 0;
    _errorRetry?.cancel();
    final title = await _safeTitle();
    state = state.copyWith(
      loading: false,
      loadError: null,
      currentUrl: url ?? state.currentUrl,
      pageTitle: title,
    );
  }

  /// Load failure. Retries with backoff instead of leaving a wall display
  /// showing a Chromium error page forever.
  void onLoadError(String description) {
    state = state.copyWith(loading: false, loadError: description);
    _scheduleErrorRetry();
  }

  /// The WebView renderer process died - either it crashed or the OS reclaimed
  /// it. Either way the widget is now blank and only a reload fixes it.
  Future<void> onRenderProcessGone() async {
    debugPrint('Aura: WebView render process gone');
    if (!ref.read(settingsControllerProvider).reloadOnCrash) return;
    // The old controller is dead; loading the start URL rebuilds the page.
    await loadStartUrl();
  }

  // -----------------------------------------------------------------------
  // WebSurface
  // -----------------------------------------------------------------------

  @override
  Future<void> navigate(String url) async {
    final normalised = _normaliseUrl(url);
    state = state.copyWith(currentUrl: normalised, loadError: null);
    final controller = _webView;
    if (controller == null) return;
    await controller.loadUrl(
      urlRequest: URLRequest(url: WebUri(normalised)),
    );
  }

  @override
  Future<void> reload({bool clearCache = false}) async {
    if (clearCache) {
      await InAppWebViewController.clearAllCache();
    }
    final controller = _webView;
    if (controller == null) {
      await loadStartUrl();
      return;
    }
    await controller.reload();
  }

  @override
  Future<void> loadStartUrl() =>
      navigate(ref.read(settingsControllerProvider).startUrl);

  @override
  Future<void> evaluateJavascript(String source) async {
    await _webView?.evaluateJavascript(source: source);
  }

  // -----------------------------------------------------------------------
  // Admin panel
  // -----------------------------------------------------------------------

  void showAdmin() => state = state.copyWith(adminVisible: true);

  void hideAdmin() => state = state.copyWith(adminVisible: false);

  // -----------------------------------------------------------------------
  // Touch / wake
  // -----------------------------------------------------------------------

  /// Any tap while the display is dark wakes it and is swallowed, so the first
  /// touch never accidentally presses a dashboard button.
  Future<void> handleWakeTap() async {
    await ref.read(auraPlatformProvider).noteInteraction();
  }

  // -----------------------------------------------------------------------
  // Native events
  // -----------------------------------------------------------------------

  void _subscribeNativeEvents() {
    _nativeEvents?.cancel();
    _nativeEvents = ref.read(auraPlatformProvider).events.listen(
          _onNativeEvent,
          onError: (Object error) =>
              debugPrint('Aura: native event error: $error'),
        );
  }

  void _onNativeEvent(NativeEvent event) {
    switch (event.type) {
      case 'ready':
      case 'motionState':
      case 'kioskStatus':
        state = state.copyWith(
          nativeStatus: <String, dynamic>{...state.nativeStatus, ...event.data},
          screenOn: event.value<bool>('screenOn') ?? state.screenOn,
          brightness: event.value<int>('brightness') ?? state.brightness,
          illuminance:
              (event.data['illuminance'] as num?)?.toDouble() ?? state.illuminance,
        );

      case 'screenState':
        state = state.copyWith(
          screenOn: event.value<bool>('screenOn') ?? state.screenOn,
          brightness: event.value<int>('brightness') ?? state.brightness,
          nativeStatus: <String, dynamic>{...state.nativeStatus, ...event.data},
        );

      case 'motion':
        state = state.copyWith(
          motionDetected: event.value<bool>('detected') ?? false,
          motionSource: event.value<String>('source'),
        );

      default:
        debugPrint('Aura: unhandled native event ${event.type}');
    }
  }

  // -----------------------------------------------------------------------
  // Connectivity & scheduled reloads
  // -----------------------------------------------------------------------

  void _subscribeConnectivity() {
    _connectivity?.cancel();
    _connectivity = Connectivity().onConnectivityChanged.listen(
      (List<ConnectivityResult> results) {
        final online =
            results.any((r) => r != ConnectivityResult.none);
        final wasOffline = !state.online;
        state = state.copyWith(online: online);

        if (online &&
            wasOffline &&
            ref.read(settingsControllerProvider).reloadOnNetworkRestore) {
          debugPrint('Aura: network restored - reloading dashboard');
          // Small delay: the interface is up but DNS/routes often are not.
          Timer(const Duration(seconds: 2), () => reload());
        }
      },
      onError: (Object error) =>
          debugPrint('Aura: connectivity error: $error'),
    );
  }

  void _schedulePeriodicReload(int minutes) {
    _periodicReload?.cancel();
    _periodicReload = null;
    if (minutes <= 0) return;
    _periodicReload = Timer.periodic(Duration(minutes: minutes), (_) {
      // Only reload while the display is dark, so nobody watches the dashboard
      // blink mid-glance.
      if (!state.screenOn) reload();
    });
  }

  void _scheduleErrorRetry() {
    _errorRetry?.cancel();
    _errorRetryAttempt = (_errorRetryAttempt + 1).clamp(1, 6);
    final seconds = (1 << _errorRetryAttempt).clamp(2, 60);
    _errorRetry = Timer(Duration(seconds: seconds), () {
      if (state.loadError != null) reload();
    });
  }

  Future<void> _onSettingsChanged(
    AuraSettings? previous,
    AuraSettings next,
  ) async {
    final platform = ref.read(auraPlatformProvider);
    await platform.pushConfig(next);

    if (previous == null) return;

    if (previous.periodicReloadMinutes != next.periodicReloadMinutes) {
      _schedulePeriodicReload(next.periodicReloadMinutes);
    }
    if (previous.startUrl != next.startUrl) {
      await navigate(next.startUrl);
    }
    if (previous.brightness != next.brightness) {
      await platform.setBrightness(next.brightness);
    }
    if (previous.kioskEnabled != next.kioskEnabled ||
        previous.lockTaskEnabled != next.lockTaskEnabled ||
        previous.blockStatusBar != next.blockStatusBar ||
        previous.immersive != next.immersive) {
      final status = next.kioskEnabled
          ? await platform.engageKiosk()
          : await platform.releaseKiosk();
      if (status.isNotEmpty) state = state.copyWith(nativeStatus: status);
    }
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  Future<String?> _safeTitle() async {
    try {
      return await _webView?.getTitle();
    } catch (_) {
      return state.pageTitle;
    }
  }

  static String _normaliseUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return trimmed;
    if (trimmed.startsWith('http://') ||
        trimmed.startsWith('https://') ||
        trimmed.startsWith('file://') ||
        trimmed.startsWith('about:')) {
      return trimmed;
    }
    // Operators type "homeassistant.local:8123" far more often than a scheme.
    return 'http://$trimmed';
  }

  void _disposeResources() {
    _nativeEvents?.cancel();
    _connectivity?.cancel();
    _periodicReload?.cancel();
    _errorRetry?.cancel();
    _webView = null;
  }
}
