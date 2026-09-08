import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../../domain/models/device_telemetry.dart';
import '../../domain/models/remote_command.dart';

/// On-device HTTP control API.
///
/// This is the "no broker required" path. A lot of Home Assistant installs do
/// not run MQTT, and for those a `rest_command` against this server is the
/// shortest route to the same control surface:
///
/// ```yaml
/// rest_command:
///   hallway_screen_off:
///     url: "http://192.168.1.40:2323/api/command"
///     method: post
///     headers:
///       authorization: "Bearer 1234"       # the admin PIN
///     content_type: "application/json"
///     payload: '{"command": "screen_off"}'
/// ```
///
/// Security posture, stated plainly: this listens on the LAN with bearer-token
/// auth only, no TLS. That is a deliberate trade for a device whose whole job
/// is to be controlled by other things on the same private network - but the
/// token is the admin PIN, so a default PIN of 1234 means anyone on the wifi
/// can drive the display. The admin panel warns about that.
class AuraRestServer {
  AuraRestServer({
    required Future<void> Function(RemoteCommand command) onCommand,
    required DeviceTelemetry Function() telemetry,
    required Map<String, dynamic> Function() status,
  })  : _onCommand = onCommand,
        _telemetry = telemetry,
        _status = status;

  final Future<void> Function(RemoteCommand command) _onCommand;
  final DeviceTelemetry Function() _telemetry;
  final Map<String, dynamic> Function() _status;

  HttpServer? _server;

  bool get isRunning => _server != null;
  int? get port => _server?.port;

  Future<void> start({required int port, required String token}) async {
    await stop();

    final router = Router()
      ..get('/health', (Request request) => _json({'status': 'ok'}))
      ..get('/api/state', (Request request) => _json(_telemetry().toJson()))
      ..get('/api/status', (Request request) => _json(_status()))
      ..post('/api/command', _handleCommand)
      // Convenience GETs so a browser or `curl` can drive the display without
      // composing JSON. Same auth, same executor.
      ..get('/api/screen/<state>', (Request request, String state) async {
        final command = RemoteCommand.fromJson(<String, dynamic>{
          'command': 'set_screen',
          'value': state,
        });
        return _dispatch(command);
      })
      ..get('/api/reload', (Request request) => _dispatch(const Reload()))
      ..get('/api/navigate', (Request request) {
        final url = request.url.queryParameters['url'];
        if (url == null || url.isEmpty) {
          return _json({'error': 'missing url parameter'}, status: 400);
        }
        return _dispatch(NavigateTo(url));
      });

    final handler = const Pipeline()
        .addMiddleware(_errorMiddleware())
        .addMiddleware(_authMiddleware(token))
        .addHandler(router.call);

    try {
      _server = await shelf_io.serve(
        handler,
        InternetAddress.anyIPv4,
        port,
        shared: false,
      );
      debugPrint('Aura: REST API listening on :$port');
    } catch (error) {
      // A busy port must not stop the dashboard from coming up.
      debugPrint('Aura: REST API failed to bind port $port: $error');
      _server = null;
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
      debugPrint('Aura: REST API stopped');
    }
  }

  Future<Response> _handleCommand(Request request) async {
    final body = await request.readAsString();
    Map<String, dynamic> decoded;
    try {
      final raw = jsonDecode(body);
      if (raw is! Map<String, dynamic>) {
        return _json({'error': 'body must be a JSON object'}, status: 400);
      }
      decoded = raw;
    } catch (error) {
      return _json({'error': 'invalid JSON: $error'}, status: 400);
    }

    final command = RemoteCommand.fromJson(decoded);
    return _dispatch(command);
  }

  Future<Response> _dispatch(RemoteCommand? command) async {
    if (command == null) {
      return _json({'error': 'unknown or malformed command'}, status: 400);
    }
    await _onCommand(command);
    return _json({'status': 'accepted', 'command': command.runtimeType.toString()});
  }

  /// Bearer-token auth. `/health` is intentionally open so an uptime monitor
  /// does not need the token.
  Middleware _authMiddleware(String token) {
    return (Handler inner) {
      return (Request request) async {
        if (request.url.path == 'health') return inner(request);
        if (token.isEmpty) return inner(request);

        final header = request.headers['authorization'] ?? '';
        final provided = header.toLowerCase().startsWith('bearer ')
            ? header.substring(7).trim()
            : request.url.queryParameters['token'] ?? '';

        if (provided != token) {
          return _json({'error': 'unauthorized'}, status: 401);
        }
        return inner(request);
      };
    };
  }

  Middleware _errorMiddleware() {
    return (Handler inner) {
      return (Request request) async {
        try {
          return await inner(request);
        } catch (error, stack) {
          debugPrint('Aura: REST handler error: $error');
          debugPrintStack(stackTrace: stack);
          return _json({'error': 'internal error'}, status: 500);
        }
      };
    };
  }

  Response _json(Map<String, dynamic> body, {int status = 200}) => Response(
        status,
        body: jsonEncode(body),
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
}
