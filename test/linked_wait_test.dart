import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_nb_net/flutter_net.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oasx/api/api_client.dart';
import 'package:oasx/modules/home/controllers/dashboard_controller.dart';
import 'package:oasx/service/profile_service.dart';
import 'package:oasx/service/script_service.dart';
import 'package:oasx/service/websocket_service.dart';

class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('Only in-memory HTTP is allowed');
}

class _OfflineScripts extends ScriptService {
  @override
  // ignore: must_call_super
  Future<void> onInit() async {}
}

class _Storage implements HomeDashboardStorage {
  @override
  dynamic read(String key) => null;
  @override
  void write(String key, dynamic value) {}
}

class _Adapter implements HttpClientAdapter {
  final writes = <RequestOptions>[];
  final unsupported = <String>{};
  final failed = <String>{};
  Completer<void>? started;
  Completer<void>? resume;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancelFuture) async {
    final account = options.path.split('/')[1];
    String result;
    if (options.method == 'GET' && options.path.endsWith('/args')) {
      result = unsupported.contains(account) ? '{}' : '{"scheduler": []}';
    } else if (options.method == 'PUT' &&
        options.path.endsWith('/sync_next_run')) {
      writes.add(options);
      if (writes.length == 1 && started != null) {
        started!.complete();
        await resume!.future;
      }
      result = failed.contains(account) ? 'false' : 'true';
    } else {
      throw StateError('Unexpected HTTP operation: ${options.method} ${options.path}');
    }
    return ResponseBody.fromString(result, 200,
        headers: {Headers.contentTypeHeader: ['application/json']});
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpOverrides? previous;
  late _Adapter adapter;
  late HomeDashboardController dashboard;
  setUpAll(() async {
    previous = HttpOverrides.current;
    HttpOverrides.global = _NoNetwork();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (_) async => 'wifi');
    final root = await Directory.systemTemp.createTemp('oasx-linked-wait-test-');
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (_) async => root.path);
    await ProfileService.initialize(projectDirectory: root);
    ApiClient();
  });
  setUp(() {
    Get.testMode = true;
    Get.put<WebSocketService>(WebSocketService());
    final scripts = Get.put<ScriptService>(_OfflineScripts());
    for (final name in ['a', 'b', 'missing', 'new']) {
      scripts.addScriptModel(name);
    }
    adapter = _Adapter();
    NetOptions.instance.dio.httpClientAdapter = adapter;
    dashboard = HomeDashboardController(storage: _Storage());
  });
  tearDown(() => Get.reset());
  tearDownAll(() {
    NetOptions.instance.dio.close(force: true);
    HttpOverrides.global = previous;
  });

  test('single account uses normalized target exactly once', () async {
    expect(await dashboard.syncTaskNextRun(scriptName: ' a ', taskName: ' Chess ', targetDt: '2030-01-02 03:04:05'), isTrue);
    expect(adapter.writes.map((r) => r.path), ['/a/Chess/sync_next_run']);
    expect(adapter.writes.single.queryParameters['target_dt'], '2030-01-02 03:04:05');
  });

  test('linked wait writes each supported account once and retains requested time', () async {
    dashboard.isLinkModeEnabled.value = true;
    dashboard.linkedScriptList.value = ['a', 'b', 'b', 'missing'];
    adapter.unsupported.add('missing');
    expect(await dashboard.syncTaskNextRun(scriptName: 'a', taskName: 'Chess', targetDt: '2030-01-02 03:04:05'), isTrue);
    expect(adapter.writes.map((r) => r.path), ['/a/Chess/sync_next_run', '/b/Chess/sync_next_run']);
    expect(adapter.writes.every((r) => r.queryParameters['target_dt'] == '2030-01-02 03:04:05'), isTrue);
  });

  test('link selection changed while saving cannot redirect pending targets', () async {
    dashboard.isLinkModeEnabled.value = true;
    dashboard.linkedScriptList.value = ['a', 'b'];
    adapter.started = Completer<void>();
    adapter.resume = Completer<void>();
    final action = dashboard.syncTaskNextRun(scriptName: 'a', taskName: 'Chess');
    await adapter.started!.future;
    dashboard.linkedScriptList.value = ['a', 'new'];
    adapter.resume!.complete();
    expect(await action, isTrue);
    expect(adapter.writes.map((r) => r.path), ['/a/Chess/sync_next_run', '/b/Chess/sync_next_run']);
  });

  test('failure is reported without repeating a write or skipping later target', () async {
    dashboard.isLinkModeEnabled.value = true;
    dashboard.linkedScriptList.value = ['a', 'b'];
    adapter.failed.add('a');
    expect(await dashboard.syncTaskNextRun(scriptName: 'a', taskName: 'Chess'), isFalse);
    expect(adapter.writes.map((r) => r.path), ['/a/Chess/sync_next_run', '/b/Chess/sync_next_run']);
  });
}
