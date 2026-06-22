// 声で秘書に話しかけるアプリの最小スモークテスト。
import 'package:flutter_test/flutter_test.dart';

import 'package:koe_secretary/main.dart';

void main() {
  testWidgets('起動してホーム画面（Koely）が出る', (WidgetTester tester) async {
    await tester.pumpWidget(const KoeSecretaryApp());
    await tester.pump();

    // タイトルが表示される。
    expect(find.text('Koely'), findsOneWidget);
  });
}
