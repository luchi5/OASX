import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:oasx/modules/log/log_mixin.dart';

class _LogController extends GetxController with LogMixin {
  @override
  int get maxLines => 3;

  @override
  int get maxBuffer => 5;

  @override
  Duration get uiRefreshInterval => Duration.zero;
}

Future<void> _withLogController(
  Future<void> Function(_LogController) body,
) async {
  final controller = _LogController()..onInit();
  try {
    await body(controller);
  } finally {
    controller.onClose();
  }
}

void main() {
  setUp(() => Get.testMode = true);
  tearDown(() async => Get.reset());

  testWidgets('paused scrolling keeps only the newest bounded log history', (
    tester,
  ) async {
    await _withLogController((controller) async {
      controller.autoScroll.value = false;

      for (var batch = 0; batch < 20; batch++) {
        for (var line = 0; line < 4; line++) {
          controller.addLog('line ${batch * 4 + line}\n');
        }
        await tester.pump(const Duration(milliseconds: 50));
        expect(controller.logs.length, lessThanOrEqualTo(controller.maxBuffer));
      }

      expect(controller.autoScroll.value, false);
      expect(controller.logs, [
        'line 75\n',
        'line 76\n',
        'line 77\n',
        'line 78\n',
        'line 79\n',
      ]);
    });
  });

  testWidgets('resuming auto scroll retains the normal live log limit', (
    tester,
  ) async {
    await _withLogController((controller) async {
      controller.autoScroll.value = false;
      for (var line = 0; line < 5; line++) {
        controller.addLog('line $line\n');
      }
      controller.flushPendingLogs();

      var forcedScrolls = 0;
      controller.scrollLogs =
          ({isJump = false, force = false, scrollOffset = -1}) {
            if (force) forcedScrolls++;
          };
      controller.toggleAutoScroll();
      controller.addLog('line 5\n');
      await tester.pump(const Duration(milliseconds: 50));

      expect(controller.autoScroll.value, true);
      expect(forcedScrolls, 1);
      expect(controller.logs, ['line 3\n', 'line 4\n', 'line 5\n']);
    });
  });

  testWidgets(
    'clear removes visible and queued lines before the next refresh',
    (tester) async {
      await _withLogController((controller) async {
        controller.addLog('visible\n');
        controller.flushPendingLogs();
        controller.addLog('queued\n');

        controller.clearLog();
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.logs, isEmpty);
        expect(controller.flushPendingLogs(), 0);

        controller.addLog('fresh\n');
        await tester.pump(const Duration(milliseconds: 50));
        expect(controller.logs, ['fresh\n']);
      });
    },
  );

  testWidgets('copy uses the displayed log buffer and preserves line breaks', (
    tester,
  ) async {
    final controller = _LogController();
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    for (var line = 0; line < 5; line++) {
      controller.addLog('line $line\n');
    }
    controller.flushPendingLogs();
    controller.addLog('not displayed yet\n');

    controller.copyLogs();
    await tester.pumpAndSettle();
    expect(copiedText, 'line 2\nline 3\nline 4\n');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
