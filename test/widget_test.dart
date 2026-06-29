import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_companion/main.dart';

void main() {
  test('new recorder chart maps endpoints correctly', () {
    expect(fingeringForNote('E4').holes, const [1, 1, 1, 1, 1, 1]);
    expect(fingeringForNote('C5').holes, const [0, 0, 0, 0, 0, 0]);
    expect(fingeringForNote('C#5').holes, const [0, 1, 1, 1, 1, 1]);
  });

  test('manual event preserves only second hole', () {
    final event = FingeringEvent.manual(
      durationMs: 500,
      holes: const [0, 1, 0, 0, 0, 0],
    );

    expect(event.note, FingeringEvent.manualNoteName);
    expect(event.breath, 0);
    expect(event.bitMask, 2);
    expect(event.holes, const [0, 1, 0, 0, 0, 0]);
  });

  test('manual saved event can load without breath', () {
    final event = FingeringEvent.fromJson({
      'note': FingeringEvent.manualNoteName,
      'durationMs': 500,
      'holes': const [0, 1, 0, 0, 0, 0],
    });

    expect(event.bitMask, 2);
    expect(event.breath, 0);
  });

  test('connected playback bridges active manual arrangements', () {
    final event = FingeringEvent.manual(
      durationMs: 500,
      holes: const [1, 1, 1, 0, 0, 0],
    );

    expect(event.scaledDurationMs(1), 500);
    expect(
      event.bleDurationMs(1, bridgeToNext: true),
      500 + solenoidBridgeHoldMs,
    );
  });

  test('rests still release immediately during bridged playback', () {
    final rest = FingeringEvent.rest();

    expect(rest.activeCount, 0);
    expect(rest.bleDurationMs(1, bridgeToNext: true), rest.scaledDurationMs(1));
  });

  testWidgets('dashboard renders core controls', (tester) async {
    await tester.pumpWidget(const CobanApp());

    expect(find.text(appTitle), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Sheet photos'), findsOneWidget);
    expect(find.text('Manual'), findsOneWidget);
    expect(find.text('Demo'), findsNothing);
    expect(find.byTooltip('Stop'), findsOneWidget);
    expect(find.text('Breath'), findsOneWidget);
    expect(find.text('Fingering'), findsOneWidget);
  });

  testWidgets('manual mode exposes delay divider', (tester) async {
    await tester.pumpWidget(const CobanApp());

    await tester.tap(find.text('Manual'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Manual timing'), findsOneWidget);
    expect(find.text('Divide by'), findsOneWidget);
    expect(find.text('Save delays'), findsOneWidget);
  });

  testWidgets('manual fingering stage exposes editable duration', (
    tester,
  ) async {
    await tester.pumpWidget(const CobanApp());

    await tester.tap(find.text('Manual'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Tap'));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.tap(find.text('Tap again'));
    await tester.pump();

    await tester.tap(find.text('Save delays'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Manual fingerings'), findsOneWidget);
    expect(find.text('Duration'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), '640');
    expect(find.text('640'), findsOneWidget);
  });
}
