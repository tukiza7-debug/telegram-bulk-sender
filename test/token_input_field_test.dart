import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:telegram_bulk_sender/features/common/token_input_field.dart';

const clean = '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawk';
const second = '987654321:AABbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQq';
const mixedCase = '123456789:AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQq';

void _setClipboard(WidgetTester tester, String text) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.getData') {
        // The messenger encodes the returned object with the channel codec
        // itself — return the raw payload, never an encoded envelope.
        return <String, String?>{'text': text};
      }
      return null;
    },
  );
}

Future<void> _pump(WidgetTester tester, TextEditingController controller) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TokenInputField(controller: controller),
      ),
    ),
  );
}

Future<void> _tapPaste(WidgetTester tester) async {
  await tester.tap(find.byIcon(Symbols.content_paste_rounded));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('paste & clean fills the field with the extracted token',
      (tester) async {
    final controller = TextEditingController();
    _setClipboard(
      tester,
      'Use this token to access the HTTP Bot API:\n$clean\n\nKeep it secure!',
    );
    await _pump(tester, controller);

    await _tapPaste(tester);

    expect(controller.text, clean);
    expect(find.textContaining('Cleaned automatically'), findsOneWidget);
  });

  testWidgets('a clean clipboard paste shows no cleaning note',
      (tester) async {
    final controller = TextEditingController();
    _setClipboard(tester, clean);
    await _pump(tester, controller);

    await _tapPaste(tester);

    expect(controller.text, clean);
    expect(find.textContaining('Cleaned automatically'), findsNothing);
  });

  testWidgets('two tokens in the clipboard open the picker', (tester) async {
    final controller = TextEditingController();
    _setClipboard(tester, 'A: $clean B: $second');
    await _pump(tester, controller);

    await _tapPaste(tester);

    // The picker lists both candidates by fingerprint, never in full.
    expect(find.byType(ListTile), findsNWidgets(2));
    expect(find.textContaining('AAHdqTcvCH1vGWJxfSeofSAs'), findsNothing);

    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();

    expect(controller.text, clean);
    expect(find.textContaining('Cleaned automatically'), findsOneWidget);
  });

  testWidgets('an empty clipboard shows a hint, not a crash', (tester) async {
    final controller = TextEditingController();
    _setClipboard(tester, '');
    await _pump(tester, controller);

    await _tapPaste(tester);

    expect(controller.text, isEmpty);
    expect(find.textContaining('Clipboard is empty'), findsOneWidget);
  });

  testWidgets('a clipboard without any token shows the friendly note',
      (tester) async {
    final controller = TextEditingController();
    _setClipboard(tester, 'https://t.me/my_bulk_bot');
    await _pump(tester, controller);

    await _tapPaste(tester);

    expect(controller.text, isEmpty);
    expect(find.textContaining('No bot token found'), findsOneWidget);
  });

  testWidgets('IME assists are fully disabled on the field', (tester) async {
    final controller = TextEditingController();
    await _pump(tester, controller);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    expect(field.smartDashesType, SmartDashesType.disabled);
    expect(field.smartQuotesType, SmartQuotesType.disabled);
    expect(field.textCapitalization, TextCapitalization.none);
    expect(field.keyboardType, TextInputType.visiblePassword);
    expect(field.obscureText, isTrue, reason: 'the eye toggle starts hidden');
  });

  testWidgets('typing preserves the exact characters (byte-exact)',
      (tester) async {
    final controller = TextEditingController();
    await _pump(tester, controller);

    await tester.enterText(find.byType(TextField), mixedCase);
    await tester.pump();

    expect(controller.text, mixedCase);
  });
}
