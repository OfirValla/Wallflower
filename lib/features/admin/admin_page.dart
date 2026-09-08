import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/aura_settings.dart';
import '../../integration/mqtt/mqtt_manager.dart';
import '../../providers.dart';

/// Full-screen configuration surface, gated behind the admin PIN.
///
/// Rendered inside the kiosk [Stack] rather than pushed as a route, because a
/// Navigator route can be popped by a stray BACK and would then leave the
/// dashboard showing a half-torn transition. A widget in the stack is either
/// there or it is not.
class AdminPage extends ConsumerStatefulWidget {
  const AdminPage({super.key});

  @override
  ConsumerState<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends ConsumerState<AdminPage> {
  bool _unlocked = false;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF0B1220),
      child: SafeArea(
        child: _unlocked
            ? _AdminForm(onClose: _close)
            : _PinGate(
                expected: ref.read(settingsControllerProvider).adminPin,
                onUnlocked: () => setState(() => _unlocked = true),
                onCancel: _close,
              ),
      ),
    );
  }

  void _close() => ref.read(kioskControllerProvider.notifier).hideAdmin();
}

// ---------------------------------------------------------------------------
// PIN gate
// ---------------------------------------------------------------------------

class _PinGate extends StatefulWidget {
  const _PinGate({
    required this.expected,
    required this.onUnlocked,
    required this.onCancel,
  });

  final String expected;
  final VoidCallback onUnlocked;
  final VoidCallback onCancel;

  @override
  State<_PinGate> createState() => _PinGateState();
}

class _PinGateState extends State<_PinGate> {
  final TextEditingController _controller = TextEditingController();
  String? _error;
  int _attempts = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_controller.text == widget.expected) {
      widget.onUnlocked();
      return;
    }
    _attempts++;
    setState(() {
      _controller.clear();
      // Three strikes closes the panel: a bystander guessing at a wall tablet
      // gets one short window, not unlimited tries.
      _error = _attempts >= 3 ? 'Too many attempts' : 'Incorrect PIN';
    });
    if (_attempts >= 3) widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.lock_outline, size: 40, color: Colors.white70),
            const SizedBox(height: 16),
            const Text(
              'Aura Display admin',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _controller,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, letterSpacing: 8),
              decoration: InputDecoration(
                hintText: 'PIN',
                errorText: _error,
                filled: true,
                fillColor: Colors.white10,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
                FilledButton(onPressed: _submit, child: const Text('Unlock')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Settings form
// ---------------------------------------------------------------------------

class _AdminForm extends ConsumerStatefulWidget {
  const _AdminForm({required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<_AdminForm> createState() => _AdminFormState();
}

class _AdminFormState extends ConsumerState<_AdminForm> {
  late AuraSettings _draft;
  final Map<String, TextEditingController> _text = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    // Edit a local draft and commit on Save: a half-typed MQTT host should not
    // trigger a reconnect on every keystroke.
    _draft = ref.read(settingsControllerProvider);
  }

  @override
  void dispose() {
    for (final TextEditingController controller in _text.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(String key, String initial) =>
      _text.putIfAbsent(key, () => TextEditingController(text: initial));

  Future<void> _save() async {
    await ref.read(settingsControllerProvider.notifier).replace(_draft);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings saved')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final kiosk = ref.watch(kioskControllerProvider);
    final bridge = ref.read(homeAssistantBridgeProvider);

    return Theme(
      data: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B1220),
      ),
      child: Column(
        children: <Widget>[
          _Header(onClose: widget.onClose, onSave: _save),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              children: <Widget>[
                _section('Dashboard'),
                _textField(
                  key: 'startUrl',
                  label: 'Start URL',
                  value: _draft.startUrl,
                  onChanged: (v) => _draft = _draft.copyWith(startUrl: v),
                ),
                _textField(
                  key: 'userAgent',
                  label: 'Custom User-Agent (blank = default)',
                  value: _draft.userAgent ?? '',
                  onChanged: (v) =>
                      _draft = _draft.copyWith(userAgent: v.isEmpty ? '' : v),
                ),
                _switch(
                  'Accept invalid SSL certificates',
                  _draft.allowInsecureSsl,
                  (v) => _draft = _draft.copyWith(allowInsecureSsl: v),
                  subtitle: 'Only for a self-signed local server. Installing the '
                      'CA on the device is safer and keeps validation on.',
                ),
                _switch(
                  'Expose window.Aura to the page',
                  _draft.enableJsBridge,
                  (v) => _draft = _draft.copyWith(enableJsBridge: v),
                ),
                _switch(
                  'Reload after a WebView crash',
                  _draft.reloadOnCrash,
                  (v) => _draft = _draft.copyWith(reloadOnCrash: v),
                ),
                _switch(
                  'Reload when the network comes back',
                  _draft.reloadOnNetworkRestore,
                  (v) => _draft = _draft.copyWith(reloadOnNetworkRestore: v),
                ),
                _numberField(
                  key: 'periodicReload',
                  label: 'Periodic reload (minutes, 0 = off)',
                  value: _draft.periodicReloadMinutes,
                  onChanged: (v) =>
                      _draft = _draft.copyWith(periodicReloadMinutes: v),
                ),

                _section('Kiosk lockdown'),
                _switch(
                  'Kiosk mode',
                  _draft.kioskEnabled,
                  (v) => _draft = _draft.copyWith(kioskEnabled: v),
                ),
                _switch(
                  'Lock Task / screen pinning',
                  _draft.lockTaskEnabled,
                  (v) => _draft = _draft.copyWith(lockTaskEnabled: v),
                ),
                _switch(
                  'Hide system bars (immersive)',
                  _draft.immersive,
                  (v) => _draft = _draft.copyWith(immersive: v),
                ),
                _switch(
                  'Block the status bar / notification shade',
                  _draft.blockStatusBar,
                  (v) => _draft = _draft.copyWith(blockStatusBar: v),
                ),
                _switch(
                  'Swallow BACK / RECENTS / MENU',
                  _draft.blockHardwareKeys,
                  (v) => _draft = _draft.copyWith(blockHardwareKeys: v),
                ),
                _switch(
                  'Suppress the lock screen',
                  _draft.dismissKeyguard,
                  (v) => _draft = _draft.copyWith(dismissKeyguard: v),
                ),
                _switch(
                  'Allow the power menu',
                  _draft.allowPowerMenu,
                  (v) => _draft = _draft.copyWith(allowPowerMenu: v),
                ),

                _section('Display & power'),
                _switch(
                  'Keep the display awake',
                  _draft.keepScreenOn,
                  (v) => _draft = _draft.copyWith(keepScreenOn: v),
                ),
                _dropdown<ScreenOffMode>(
                  label: 'Screen-off method',
                  value: _draft.screenOffMode,
                  items: const <ScreenOffMode, String>{
                    ScreenOffMode.dim: 'Dim + black overlay (instant wake)',
                    ScreenOffMode.deviceLock: 'Device lock (real panel off)',
                  },
                  onChanged: (v) => _draft = _draft.copyWith(screenOffMode: v),
                ),
                _numberField(
                  key: 'screenTimeout',
                  label: 'Screen timeout (seconds, 0 = never)',
                  value: _draft.screenTimeoutSeconds,
                  onChanged: (v) =>
                      _draft = _draft.copyWith(screenTimeoutSeconds: v),
                ),
                _slider(
                  label: 'Brightness',
                  value: _draft.brightness.toDouble(),
                  min: 0,
                  max: 255,
                  display: '${(_draft.brightness / 255 * 100).round()}%',
                  onChanged: (v) =>
                      _draft = _draft.copyWith(brightness: v.round()),
                ),

                _section('Motion detection'),
                _switch(
                  'Enable motion detection',
                  _draft.motionEnabled,
                  (v) => _draft = _draft.copyWith(motionEnabled: v),
                ),
                _dropdown<MotionSource>(
                  label: 'Source',
                  value: _draft.motionSource,
                  items: const <MotionSource, String>{
                    MotionSource.camera: 'Front camera (frame differencing)',
                    MotionSource.sensors: 'Light + proximity sensors',
                    MotionSource.both: 'Camera and sensors',
                    MotionSource.none: 'Disabled',
                  },
                  onChanged: (v) => _draft = _draft.copyWith(motionSource: v),
                ),
                _slider(
                  label: 'Sensitivity',
                  value: _draft.motionSensitivity.toDouble(),
                  min: 0,
                  max: 100,
                  display: '${_draft.motionSensitivity}',
                  onChanged: (v) =>
                      _draft = _draft.copyWith(motionSensitivity: v.round()),
                ),
                _slider(
                  label: 'Analysis rate',
                  value: _draft.motionAnalysisFps.toDouble(),
                  min: 1,
                  max: 15,
                  divisions: 14,
                  display: '${_draft.motionAnalysisFps} fps',
                  onChanged: (v) =>
                      _draft = _draft.copyWith(motionAnalysisFps: v.round()),
                ),
                _switch(
                  'Wake the display on motion',
                  _draft.wakeOnMotion,
                  (v) => _draft = _draft.copyWith(wakeOnMotion: v),
                ),

                _section('Home Assistant - MQTT'),
                _switch(
                  'Enable MQTT',
                  _draft.mqttEnabled,
                  (v) => _draft = _draft.copyWith(mqttEnabled: v),
                ),
                _textField(
                  key: 'mqttHost',
                  label: 'Broker host',
                  value: _draft.mqttHost,
                  onChanged: (v) => _draft = _draft.copyWith(mqttHost: v),
                ),
                _numberField(
                  key: 'mqttPort',
                  label: 'Broker port',
                  value: _draft.mqttPort,
                  onChanged: (v) => _draft = _draft.copyWith(mqttPort: v),
                ),
                _textField(
                  key: 'mqttUsername',
                  label: 'Username',
                  value: _draft.mqttUsername,
                  onChanged: (v) => _draft = _draft.copyWith(mqttUsername: v),
                ),
                _textField(
                  key: 'mqttPassword',
                  label: 'Password',
                  value: _draft.mqttPassword,
                  obscure: true,
                  onChanged: (v) => _draft = _draft.copyWith(mqttPassword: v),
                ),
                _switch(
                  'Use TLS',
                  _draft.mqttTls,
                  (v) => _draft = _draft.copyWith(mqttTls: v),
                ),
                _textField(
                  key: 'discoveryPrefix',
                  label: 'Discovery prefix',
                  value: _draft.discoveryPrefix,
                  onChanged: (v) => _draft = _draft.copyWith(discoveryPrefix: v),
                ),
                _numberField(
                  key: 'telemetryInterval',
                  label: 'Telemetry heartbeat (seconds)',
                  value: _draft.telemetryIntervalSeconds,
                  onChanged: (v) =>
                      _draft = _draft.copyWith(telemetryIntervalSeconds: v),
                ),
                _statusRow('MQTT link', bridge.mqttState.name,
                    ok: bridge.mqttState == MqttLinkState.connected),
                if (bridge.mqttError != null)
                  _statusRow('MQTT error', bridge.mqttError!, ok: false),

                _section('Home Assistant - local REST API'),
                _switch(
                  'Enable REST API',
                  _draft.restEnabled,
                  (v) => _draft = _draft.copyWith(restEnabled: v),
                ),
                _numberField(
                  key: 'restPort',
                  label: 'Port',
                  value: _draft.restPort,
                  onChanged: (v) => _draft = _draft.copyWith(restPort: v),
                ),
                _statusRow(
                  'Listening',
                  bridge.restRunning ? 'yes (:${_draft.restPort})' : 'no',
                  ok: bridge.restRunning,
                ),

                _section('Identity & admin'),
                _textField(
                  key: 'deviceName',
                  label: 'Device name (shown in Home Assistant)',
                  value: _draft.deviceName,
                  onChanged: (v) => _draft = _draft.copyWith(deviceName: v),
                ),
                _textField(
                  key: 'adminPin',
                  label: 'Admin PIN (also the REST bearer token)',
                  value: _draft.adminPin,
                  obscure: true,
                  onChanged: (v) => _draft = _draft.copyWith(adminPin: v),
                ),

                _section('Diagnostics'),
                _statusRow('Device Owner', _yesNo(kiosk.isDeviceOwner),
                    ok: kiosk.isDeviceOwner),
                _statusRow('Lock Task active', _yesNo(kiosk.kioskLocked),
                    ok: kiosk.kioskLocked),
                _statusRow(
                  'Overlay permission',
                  _yesNo(kiosk.nativeStatus['canDrawOverlays'] == true),
                  ok: kiosk.nativeStatus['canDrawOverlays'] == true,
                ),
                _statusRow(
                  'Camera analysis',
                  _yesNo(kiosk.nativeStatus['cameraRunning'] == true),
                  ok: kiosk.nativeStatus['cameraRunning'] == true,
                ),
                if (kiosk.nativeStatus['lastError'] != null)
                  _statusRow(
                    'Motion error',
                    '${kiosk.nativeStatus['lastError']}',
                    ok: false,
                  ),
                _statusRow('Current URL', kiosk.currentUrl, ok: true),

                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: <Widget>[
                    OutlinedButton(
                      onPressed: () =>
                          ref.read(auraPlatformProvider).openAdminActivation(),
                      child: const Text('Activate device admin'),
                    ),
                    OutlinedButton(
                      onPressed: () =>
                          ref.read(auraPlatformProvider).openOverlaySettings(),
                      child: const Text('Overlay permission'),
                    ),
                    OutlinedButton(
                      onPressed: () =>
                          ref.read(auraPlatformProvider).openWriteSettings(),
                      child: const Text('Write settings permission'),
                    ),
                    OutlinedButton(
                      onPressed: () =>
                          ref.read(auraPlatformProvider).openHomeAppSettings(),
                      child: const Text('Set as Home app'),
                    ),
                    OutlinedButton(
                      onPressed: () => ref
                          .read(auraPlatformProvider)
                          .applyDeviceOwnerPolicies(),
                      child: const Text('Re-apply policies'),
                    ),
                    OutlinedButton(
                      onPressed: () =>
                          ref.read(kioskControllerProvider.notifier).reload(
                                clearCache: true,
                              ),
                      child: const Text('Clear cache & reload'),
                    ),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orangeAccent,
                      ),
                      onPressed: () async {
                        await ref.read(auraPlatformProvider).releaseKiosk();
                        widget.onClose();
                      },
                      child: const Text('Exit kiosk (unlock)'),
                    ),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                      ),
                      onPressed: _confirmReset,
                      child: const Text('Reset all settings'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Reset all settings?'),
        content: const Text(
          'Start URL, MQTT credentials and the admin PIN return to defaults.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(settingsControllerProvider.notifier).resetToDefaults();
    if (mounted) widget.onClose();
  }

  // -------------------------------------------------------------------------
  // Small form helpers
  // -------------------------------------------------------------------------

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 28, bottom: 8),
        child: Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF38BDF8),
            fontSize: 12,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _textField({
    required String key,
    required String label,
    required String value,
    required ValueChanged<String> onChanged,
    bool obscure = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: _controllerFor(key, value),
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: Colors.white10,
          border: const OutlineInputBorder(),
        ),
        onChanged: onChanged,
      ),
    );
  }

  Widget _numberField({
    required String key,
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: _controllerFor(key, value.toString()),
        keyboardType: TextInputType.number,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: Colors.white10,
          border: const OutlineInputBorder(),
        ),
        onChanged: (String raw) => onChanged(int.tryParse(raw) ?? value),
      ),
    );
  }

  Widget _switch(
    String title,
    bool value,
    ValueChanged<bool> onChanged, {
    String? subtitle,
  }) {
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(color: Colors.white)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
      value: value,
      onChanged: (bool next) => setState(() => onChanged(next)),
    );
  }

  Widget _dropdown<T>({
    required String label,
    required T value,
    required Map<T, String> items,
    required ValueChanged<T> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: Colors.white10,
          border: const OutlineInputBorder(),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            isExpanded: true,
            value: value,
            dropdownColor: const Color(0xFF14213A),
            style: const TextStyle(color: Colors.white),
            items: items.entries
                .map(
                  (MapEntry<T, String> entry) => DropdownMenuItem<T>(
                    value: entry.key,
                    child: Text(entry.value),
                  ),
                )
                .toList(growable: false),
            onChanged: (T? next) {
              if (next != null) setState(() => onChanged(next));
            },
          ),
        ),
      ),
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double> onChanged,
    int? divisions,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(label, style: const TextStyle(color: Colors.white)),
              Text(display, style: const TextStyle(color: Colors.white54)),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: (double next) => setState(() => onChanged(next)),
          ),
        ],
      ),
    );
  }

  Widget _statusRow(String label, String value, {required bool ok}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 16,
            color: ok ? Colors.greenAccent : Colors.orangeAccent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: const TextStyle(color: Colors.white70)),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  static String _yesNo(bool value) => value ? 'yes' : 'no';
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose, required this.onSave});

  final VoidCallback onClose;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.tune, color: Colors.white70),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Aura Display settings',
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
          ),
          TextButton(onPressed: onClose, child: const Text('Close')),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: onSave,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
