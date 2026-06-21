// 声で秘書に話しかけるアプリの最小スモークテスト。
import 'package:flutter_test/flutter_test.dart';

import 'package:koe_secretary/main.dart';

void main() {
  testWidgets('起動して秘書のホーム画面が出る', (WidgetTester tester) async {
    await tester.pumpWidget(const KoeSecretaryApp());
    await tester.pump();

    // 未設定状態の案内とマイク誘導が表示される。
    expect(find.text('タップで話す'), findsOneWidget);
  });
}
