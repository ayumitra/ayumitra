// Emulator localhost-bridge settings labels (MSG-090 Main tasking).
// Synthetic only. DemoController stays in memory; the server behind
// WebIntelligence is never contacted (no discover/connect taps).

import 'package:ayumitra/domain/records.dart';
import 'package:ayumitra/preview/demo_controller.dart';
import 'package:ayumitra/services/web_llm.dart';
import 'package:ayumitra/ui/app.dart';
import 'package:ayumitra/ui/profile_files_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Debug-only shape of the coming emulator entrypoint: native persistence
/// path (isPreview false) with localhost bridge model types. Test-local only;
/// production main.dart and the real entrypoint are untouched.
class _EmulatorBridgeController extends DemoController {
  _EmulatorBridgeController({super.intelligence, super.embeddings});
  @override
  bool get isPreview => false;
}

Future<void> _showSettings(
  WidgetTester tester,
  DemoController controller,
) async {
  await tester.binding.setSurfaceSize(const Size(900, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await controller.initialize();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(home: SettingsScreen(controller: controller)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'emulator bridge takes the server branch with the debug bridge label',
    (tester) async {
      await _showSettings(
        tester,
        _EmulatorBridgeController(
          intelligence: WebIntelligence(),
          embeddings: WebEmbeddings(),
        ),
      );

      // Server branch is taken, with the truthful native-debug wording.
      expect(find.text('Connect local models'), findsOneWidget);
      expect(find.textContaining('not on-device inference'), findsOneWidget);
      expect(
        find.textContaining('remain encrypted on Android'),
        findsOneWidget,
      );
      expect(find.textContaining('localhost bridge'), findsOneWidget);
      // Browser RAM wording must not leak into the native path.
      expect(find.textContaining('browser tab'), findsNothing);
      // On-device weights branch stays out of reach here.
      expect(find.text('Choose assistant model'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('browser preview keeps the in-memory RAM label', (tester) async {
    await _showSettings(
      tester,
      DemoController(
        intelligence: WebIntelligence(),
        embeddings: WebEmbeddings(),
      ),
    );

    expect(find.text('Connect local models'), findsOneWidget);
    expect(find.textContaining('browser tab'), findsOneWidget);
    expect(find.textContaining('not on-device inference'), findsNothing);
    expect(find.text('Choose assistant model'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bridge onboarding does not promise on-phone AI', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _EmulatorBridgeController(
      intelligence: WebIntelligence(),
      embeddings: WebEmbeddings(),
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    await tester.pumpWidget(AyumitraApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.textContaining('not on-device inference'), findsOneWidget);
    expect(find.textContaining('stay on this phone'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bridge workspace names the Mac bridge, not on-device AI', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _EmulatorBridgeController(
      intelligence: WebIntelligence(),
      embeddings: WebEmbeddings(),
    );
    await controller.initialize();
    await controller.createProfile(
      'Bridge Child',
      DateTime(2021, 5, 6),
      '',
      true,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(AyumitraApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.textContaining('Development bridge'), findsOneWidget);
    expect(find.textContaining('models run on this Mac'), findsOneWidget);
    expect(find.textContaining('AI stays on this device'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bridge file library states localhost-only inference', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = _EmulatorBridgeController(
      intelligence: WebIntelligence(),
      embeddings: WebEmbeddings(),
    );
    await controller.initialize();
    await controller.createProfile(
      'Bridge Child',
      DateTime(2021, 5, 6),
      '',
      true,
    );
    addTearDown(controller.dispose);
    final id = controller.activeProfileId!;
    controller.data = controller.data.copy(
      reports: [
        Report(
          id: 'e1',
          profileId: id,
          name: 'bridge-lab.txt',
          extension: 'txt',
          digest: 'digest-e1',
          importedAt: DateTime(2026, 10, 12),
          type: 'lab',
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ProfileFilesScreen(
          controller: controller,
          profileId: id,
          onOpenReport: (_) {},
          onOpenOriginal: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('bridge-lab.txt'), findsOneWidget);
    expect(
      find.textContaining('localhost models for development testing'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Nothing is uploaded or copied elsewhere'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
