import 'notification_policy.dart';
import 'personal_classifier.dart';

class NotificationExample {
  const NotificationExample(
    this.id,
    this.package,
    this.title,
    this.snippet,
    this.isTransaction,
  );
  final String id, package, title, snippet;
  final bool isTransaction;
}

class NotificationAssessment {
  const NotificationAssessment(this.isTransaction, this.support);
  final bool isTransaction;
  final int support;
  String get evidence => '이 앱의 비슷한 알림에서 직접 확인한 $support건을 참고했어요.';
}

/// 분류 모델과 정답을 섞지 않고 같은 로지스틱 회귀 엔진만 재사용한다.
/// 학습 결과는 확인 카드의 제안이다. 자동 확정·자동 숨김에는 사용하지 않는다.
class NotificationClassifier {
  NotificationClassifier(List<NotificationExample> examples)
    : examples = List.unmodifiable(examples);
  final List<NotificationExample> examples;

  LearningInput _input(String package, String title, String text) {
    final heading = normalizedNotificationSnippet(title);
    return LearningInput(
      account: package,
      destination: '',
      party:
          '${heading.substring(0, heading.length.clamp(0, 30))} ${normalizedNotificationSnippet(text)}',
      // 공통 엔진의 거래 전용 특성은 상수로 고정해 판독 입력에 섞이지 않게 한다.
      direction: 'in',
      amount: 1,
      at: DateTime(2000),
    );
  }

  NotificationAssessment? predict(
    String package,
    String title,
    String text, {
    String? excludeId,
  }) {
    final samples = examples
        .where((e) => e.package == package && e.id != excludeId)
        .toList();
    if (samples.length < 2) return null;
    final model = PersonalClassifier([
      for (final e in samples)
        LearningExample(
          e.id,
          _input(e.package, e.title, e.snippet),
          LearningLabel(
            'income',
            e.isTransaction ? 'transaction' : 'not_transaction',
          ),
        ),
    ]);
    final prediction = model.predict(_input(package, title, text));
    if (prediction == null) return null;
    return NotificationAssessment(
      prediction.label.category == 'transaction',
      prediction.support,
    );
  }
}
