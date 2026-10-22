import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oasx/modules/args/index.dart';

class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('Argument race tests must never contact a server');
}

Map<String, dynamic> _payload(String value) => {
  'settings': [
    {'name': 'first', 'value': value, 'type': 'string'},
    {'name': 'second', 'value': value, 'type': 'string'},
    {
      'name': 'choices',
      'value': ['one'],
      'type': 'multi_enum',
      'enumEnum': ['one', 'two', 'three'],
    },
  ],
};

typedef _Write = ({
  String config,
  String task,
  String argument,
  String type,
  dynamic value,
});

class _RecordingArgs extends ArgsController {
  _RecordingArgs() : super(loadArguments: (_, __) async => _payload('initial'));
  final writes = <_Write>[];
  final firstWrite = Completer<bool>();

  @override
  Future<bool> setArgument(
    String? config,
    String? task,
    String group,
    String argument,
    String type,
    dynamic value,
  ) async {
    writes.add((
      config: config!,
      task: task!,
      argument: argument,
      type: type,
      value: value,
    ));
    return writes.length == 1 ? firstWrite.future : true;
  }
}

void _edit(
  ArgsController controller,
  String field,
  dynamic value, {
  String type = 'string',
}) {
  controller.stageArgumentChange('settings', field, value, type);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpOverrides? previousOverrides;
  setUp(() {
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _NoNetwork();
    Get.testMode = true;
  });
  tearDown(() async {
    HttpOverrides.global = previousOverrides;
    Get.reset();
  });

  test('late A read cannot replace B form or its dirty values', () async {
    final a = Completer<Map<String, dynamic>>();
    final b = Completer<Map<String, dynamic>>();
    final controller = ArgsController(
      loadArguments: (config, _) => config == 'a' ? a.future : b.future,
    );
    final loadA = controller.loadGroups(
      config: 'a',
      task: 'taskA',
      stagingMode: true,
    );
    final loadB = controller.loadGroups(
      config: 'b',
      task: 'taskB',
      stagingMode: true,
    );
    b.complete(_payload('B'));
    await loadB;
    _edit(controller, 'first', 'B edit');
    a.complete(_payload('A'));
    await loadA;
    expect(controller.currentConfig, 'b');
    expect(controller.currentTask, 'taskB');
    expect(controller.findArgument('settings', 'first')!.value, 'B edit');
    expect(controller.isFieldDirty('settings', 'first'), isTrue);
  });

  test('same account and task reload also rejects its older request', () async {
    final old = Completer<Map<String, dynamic>>();
    var reads = 0;
    final controller = ArgsController(
      loadArguments: (_, __) async =>
          ++reads == 1 ? old.future : _payload('new'),
    );
    final first = controller.loadGroups(config: 'a', task: 'same');
    await controller.loadGroups(config: 'a', task: 'same');
    old.complete(_payload('old'));
    await first;
    expect(controller.findArgument('settings', 'first')!.value, 'new');
  });

  test(
    'new read immediately isolates old fields and failure leaves no old form',
    () async {
      final next = Completer<Map<String, dynamic>>();
      final controller = ArgsController(
        loadArguments: (config, _) async =>
            config == 'a' ? _payload('A') : next.future,
      );
      await controller.loadGroups(config: 'a', task: 'task', stagingMode: true);
      _edit(controller, 'first', 'dirty A');
      final load = controller.loadGroups(
        config: 'b',
        task: 'task',
        stagingMode: true,
      );
      expect(controller.groupsData.value, isEmpty);
      expect(controller.groupsName.value, isEmpty);
      expect(controller.hasDraftChanges, isFalse);
      next.completeError(StateError('read failed'));
      await expectLater(load, throwsStateError);
      expect(controller.groupsData.value, isEmpty);
    },
  );

  test(
    'save freezes scope task fields and values across account change',
    () async {
      final controller = _RecordingArgs();
      await controller.loadGroups(
        config: 'a',
        task: 'oldTask',
        stagingMode: true,
        scopeScripts: ['a', 'linked'],
      );
      _edit(controller, 'first', 'old first');
      _edit(controller, 'second', 'old second');
      final save = controller.saveDraftChanges();
      expect(controller.writes, hasLength(1));
      await controller.loadGroups(
        config: 'b',
        task: 'newTask',
        stagingMode: true,
        scopeScripts: ['b', 'other'],
      );
      _edit(controller, 'first', 'new draft');
      // A second save cannot overlap with the outstanding old draft.
      expect(await controller.saveDraftChanges(), isFalse);
      expect(controller.isSavingDraft.value, isTrue);
      controller.firstWrite.complete(true);
      expect(await save, isTrue);
      expect(controller.writes, [
        (
          config: 'a',
          task: 'oldTask',
          argument: 'first',
          type: 'string',
          value: 'old first',
        ),
        (
          config: 'linked',
          task: 'oldTask',
          argument: 'first',
          type: 'string',
          value: 'old first',
        ),
        (
          config: 'a',
          task: 'oldTask',
          argument: 'second',
          type: 'string',
          value: 'old second',
        ),
        (
          config: 'linked',
          task: 'oldTask',
          argument: 'second',
          type: 'string',
          value: 'old second',
        ),
      ]);
      expect(controller.findArgument('settings', 'first')!.value, 'new draft');
      expect(controller.isFieldDirty('settings', 'first'), isTrue);
      await controller.discardDraftChanges();
      expect(controller.findArgument('settings', 'first')!.value, 'initial');
    },
  );

  test(
    'save keeps original callback after a new form supplies another',
    () async {
      final first = Completer<bool>();
      final writes = <String>[];
      final controller = ArgsController(
        loadArguments: (_, __) async => _payload('initial'),
      );
      await controller.loadGroups(
        config: 'a',
        task: 'old',
        stagingMode: true,
        saveArgumentOverride: (c, t, g, a, type, value) async {
          writes.add('$c/$t/$a/$type/$value');
          return writes.length == 1 ? first.future : true;
        },
      );
      _edit(controller, 'first', 'one');
      _edit(controller, 'second', 'two');
      final save = controller.saveDraftChanges();
      await controller.loadGroups(
        config: 'b',
        task: 'new',
        stagingMode: true,
        saveArgumentOverride: (_, __, ___, ____, _____, ______) async =>
            fail('Old save must not call the new callback'),
      );
      first.complete(true);
      await save;
      expect(writes, ['a/old/first/string/one', 'a/old/second/string/two']);
    },
  );

  for (final next in ['new edit', 'initial']) {
    test(
      'editing to $next during save remains dirty against persisted value',
      () async {
        final controller = _RecordingArgs();
        await controller.loadGroups(
          config: 'a',
          task: 'task',
          stagingMode: true,
        );
        _edit(controller, 'first', 'submitted');
        final save = controller.saveDraftChanges();
        _edit(controller, 'first', next);
        controller.firstWrite.complete(true);
        expect(await save, isTrue);
        expect(controller.findArgument('settings', 'first')!.value, next);
        expect(controller.isFieldDirty('settings', 'first'), isTrue);
        await controller.discardDraftChanges();
        expect(
          controller.findArgument('settings', 'first')!.value,
          'submitted',
        );
      },
    );
  }

  test(
    'discarding while a save is pending cannot hide the persisted difference',
    () async {
      final controller = _RecordingArgs();
      await controller.loadGroups(config: 'a', task: 'task', stagingMode: true);
      _edit(controller, 'first', 'submitted');
      final save = controller.saveDraftChanges();
      await controller.discardDraftChanges();
      controller.firstWrite.complete(true);
      await save;
      expect(controller.findArgument('settings', 'first')!.value, 'initial');
      expect(controller.isFieldDirty('settings', 'first'), isTrue);
    },
  );

  test(
    'list snapshot is independent for source target and newer draft',
    () async {
      final controller = _RecordingArgs();
      await controller.loadGroups(
        config: 'a',
        task: 'task',
        stagingMode: true,
        scopeScripts: ['a', 'linked'],
      );
      final choices = ['one', 'two'];
      _edit(controller, 'choices', choices, type: 'multi_enum');
      final save = controller.saveDraftChanges();
      choices.add('three');
      _edit(controller, 'choices', choices, type: 'multi_enum');
      controller.firstWrite.complete(true);
      await save;
      expect(controller.writes.map((write) => write.value), [
        ['one', 'two'],
        ['one', 'two'],
      ]);
      expect(controller.isFieldDirty('settings', 'choices'), isTrue);
      await controller.discardDraftChanges();
      final restored =
          controller.findArgument('settings', 'choices')!.value as List;
      expect(restored, ['one', 'two']);
      restored.add('three');
      await controller.discardDraftChanges();
      expect(controller.findArgument('settings', 'choices')!.value, [
        'one',
        'two',
      ]);
    },
  );

  test('failed field remains dirty and succeeds on explicit retry', () async {
    final controller = _RecordingArgs();
    await controller.loadGroups(config: 'a', task: 'task', stagingMode: true);
    _edit(controller, 'first', 'submitted');
    final save = controller.saveDraftChanges();
    controller.firstWrite.complete(false);
    expect(await save, isFalse);
    expect(controller.isFieldDirty('settings', 'first'), isTrue);
    expect(controller.isSavingDraft.value, isFalse);
    expect(await controller.saveDraftChanges(), isTrue);
    expect(controller.hasDraftChanges, isFalse);
  });

  test(
    'exception releases save guard without clearing the unsaved draft',
    () async {
      final controller = _RecordingArgs();
      await controller.loadGroups(config: 'a', task: 'task', stagingMode: true);
      _edit(controller, 'first', 'submitted');
      final save = controller.saveDraftChanges();
      controller.firstWrite.completeError(StateError('offline'));
      await expectLater(save, throwsStateError);
      expect(controller.isSavingDraft.value, isFalse);
      expect(controller.hasDraftChanges, isTrue);
    },
  );

  testWidgets('old debounced editor cannot alter fields during a new load', (
    tester,
  ) async {
    final next = Completer<Map<String, dynamic>>();
    final controller = Get.put(
      ArgsController(
        loadArguments: (config, _) async =>
            config == 'a' ? _payload('A') : next.future,
      ),
    );
    await controller.loadGroups(config: 'a', task: 'task', stagingMode: true);
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: ArgumentView(
            scriptName: 'a',
            taskName: 'task',
            getGroupName: () => 'settings',
            index: 0,
            setArgument: (_, __, ___, ____, _____, ______) =>
                fail('Draft cannot write'),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextFormField), 'late A edit');
    final load = controller.loadGroups(
      config: 'b',
      task: 'task',
      stagingMode: true,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    next.complete(_payload('B'));
    await load;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(controller.findArgument('settings', 'first')!.value, 'B');
    expect(controller.hasDraftChanges, isFalse);
  });

  for (final switchThroughB in [false, true]) {
    testWidgets(
      'Args remains editable after ${switchThroughB ? 'A-B-A' : 'same task'} reload without an intermediate frame',
      (tester) async {
        var reads = 0;
        final controller = Get.put(
          ArgsController(
            loadArguments: (config, _) async => _payload('$config-${++reads}'),
          ),
        );
        await controller.loadGroups(
          config: 'a',
          task: 'task',
          stagingMode: true,
        );
        await tester.pumpWidget(
          const GetMaterialApp(
            home: Scaffold(
              body: Args(
                scriptName: 'a',
                taskName: 'task',
                groupDraggable: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final firstField = find.descendant(
          of: find.byKey(const ValueKey('args-a-task-settings-first')),
          matching: find.byType(TextFormField),
        );
        expect(firstField, findsOneWidget);
        final oldChanged = tester.widget<TextFormField>(firstField).onChanged!;
        oldChanged('old pending value');
        if (switchThroughB) {
          await controller.loadGroups(
            config: 'b',
            task: 'other',
            stagingMode: true,
          );
        }
        await controller.loadGroups(
          config: 'a',
          task: 'task',
          stagingMode: true,
        );
        final expected = switchThroughB ? 'a-3' : 'a-2';
        // Reloads finish before Flutter renders an empty/loading frame.
        await tester.pumpAndSettle(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
        expect(firstField, findsOneWidget);
        expect(controller.findArgument('settings', 'first')!.value, expected);
        expect(controller.hasDraftChanges, isFalse);
        await tester.enterText(firstField, 'current edit');
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          controller.findArgument('settings', 'first')!.value,
          'current edit',
        );
        expect(controller.isFieldDirty('settings', 'first'), isTrue);
        // A callback retained by a dismissed input surface cannot touch the
        // replacement widget's model, even after the new field was edited.
        oldChanged('stale callback');
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
        expect(
          controller.findArgument('settings', 'first')!.value,
          'current edit',
        );
      },
    );
  }
}
