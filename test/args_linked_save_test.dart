import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_nb_net/flutter_net.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oasx/api/api_client.dart';
import 'package:oasx/modules/args/index.dart';
import 'package:oasx/modules/home/controllers/dashboard_controller.dart';
import 'package:oasx/service/profile_service.dart';

class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('Linked save tests must never contact a server');
}

class _OfflineTaskAdapter implements HttpClientAdapter {
  final requests = <String>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.path);
    if (options.method != 'GET' || !options.path.endsWith('/args')) {
      throw StateError('Only simulated availability reads are allowed');
    }
    return ResponseBody.fromString(
      options.path.startsWith('/missing/') ? '{}' : '{"settings": []}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _MemoryStorage implements HomeDashboardStorage {
  @override
  dynamic read(String key) => null;
  @override
  void write(String key, dynamic value) {}
}

class _RecordingArgs extends ArgsController {
  _RecordingArgs()
    : super(
        loadArguments: (_, __) async => {
          'settings': [
            {'name': 'first', 'value': 'initial', 'type': 'string'},
            {'name': 'second', 'value': 'initial', 'type': 'string'},
          ],
        },
      );
  final writes = <String>[];
  final started = Completer<void>();
  final resume = Completer<bool>();
  @override
  Future<bool> setArgument(
    String? config,
    String? task,
    String group,
    String argument,
    String type,
    dynamic value,
  ) async {
    writes.add('$config/$task/$argument/$value');
    if (writes.length == 1) {
      started.complete();
      return resume.future;
    }
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _OfflineTaskAdapter adapter;
  late HttpOverrides? previousOverrides;
  setUpAll(() async {
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _NoNetwork();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'),
          (_) async => 'wifi',
        );
    final root = await Directory.systemTemp.createTemp(
      'oasx-args-linked-test-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    await ProfileService.initialize(projectDirectory: root);
    ApiClient();
    adapter = _OfflineTaskAdapter();
    NetOptions.instance.dio.httpClientAdapter = adapter;
  });
  tearDownAll(() async {
    Get.reset();
    NetOptions.instance.dio.close(force: true);
    HttpOverrides.global = previousOverrides;
  });

  test(
    'real parameter callback freezes linked scope and retains task filtering',
    () async {
      Get.testMode = true;
      final args = Get.put<ArgsController>(_RecordingArgs()) as _RecordingArgs;
      final dashboard = HomeDashboardController(storage: _MemoryStorage());
      var factoryCalls = 0;
      await args.loadGroups(
        config: 'a',
        task: 'Task',
        stagingMode: true,
        scopeScripts: ['a', 'b', 'missing'],
        saveArgumentFactory: (scope) {
          factoryCalls++;
          return dashboard.createParameterSaveCallback(scope);
        },
      );
      args.stageArgumentChange('settings', 'first', 'one', 'string');
      args.stageArgumentChange('settings', 'second', 'two', 'string');
      final save = args.saveDraftChanges();
      await args.started.future;
      dashboard.isLinkModeEnabled.value = true;
      dashboard.linkedScriptList.value = ['a', 'newLinkedAccount'];
      args.updateScopeScripts(['a', 'newLinkedAccount'], config: 'a');
      args.resume.complete(true);
      expect(await save, isTrue);
      expect(factoryCalls, 1);
      expect(args.writes, [
        'a/Task/first/one',
        'b/Task/first/one',
        'a/Task/second/two',
        'b/Task/second/two',
      ]);
      expect(adapter.requests, ['/b/Task/args', '/missing/Task/args']);
      expect(args.hasDraftChanges, isFalse);
    },
  );
}
