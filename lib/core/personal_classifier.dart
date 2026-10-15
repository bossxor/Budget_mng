import 'dart:convert';
import 'dart:math' as math;

/// 승인된 정답으로만 다시 훈련하는 작은 다중 클래스 로지스틱 회귀 모델.
/// 원문, 예측 분류, 검토 메모는 입력하지 않아 정답 누설을 막는다.
class LearningInput {
  const LearningInput({
    required this.account,
    required this.destination,
    required this.party,
    required this.direction,
    required this.amount,
    required this.at,
    this.destinationRole = 'unset',
  });
  final String account, destination, party, direction, destinationRole;
  final int amount;
  final DateTime at;

  static String normalize(String value) {
    final text = value.toLowerCase().replaceAll(
      RegExp(r'[\s\d\p{P}\p{S}]+', unicode: true),
      '',
    );
    return text.substring(0, math.min(80, text.length));
  }

  String get normalizedParty => normalize(party);
  bool get hasParty =>
      normalizedParty.length >= 2 &&
      !{'알수없음', '출금결제', '입금', '현금', '이체', '송금', '저축'}.contains(normalizedParty);

  Set<String> get grams {
    final text = normalizedParty;
    return {
      for (var i = 0; i + 2 <= text.length; i++) text.substring(i, i + 2),
    };
  }

  Map<String, double> get features {
    final result = <String, double>{
      'bias': 0.5,
      'dir:$direction': 0.5,
      if (account.isNotEmpty) 'account:$account': 1,
      if (destination.isNotEmpty) 'route:$account>$destination': 2,
      if (destinationRole != 'unset') 'role:$destinationRole': 1,
      if (hasParty) 'party:$normalizedParty': 0.8,
      'amount:${(math.log(math.max(1, amount)) / math.ln10 * 2).floor()}': 0.5,
      'monthday:${(at.day - 1) ~/ 5}': 0.4,
      'weekday:${at.weekday}': 0.2,
    };
    if (hasParty) {
      final tokens = grams;
      for (final token in tokens) {
        result['text:$token'] = 2 / math.sqrt(tokens.length);
      }
    }
    return result;
  }

  bool similarTo(LearningInput other) {
    if (direction != other.direction) return false;
    if (account.isNotEmpty &&
        destination.isNotEmpty &&
        account == other.account &&
        destination == other.destination) {
      return true;
    }
    if (!hasParty || !other.hasParty) return false;
    if (normalizedParty == other.normalizedParty) return true;
    final a = grams, b = other.grams;
    final overlap = a.intersection(b).length / a.union(b).length;
    return overlap >= 0.75 && account == other.account;
  }

  Map<String, Object?> toJson() => {
    'account': account,
    'destination': destination,
    'party': party,
    'direction': direction,
    'amount': amount,
    'at': at.millisecondsSinceEpoch,
    'role': destinationRole,
  };
  factory LearningInput.fromJson(Map<String, dynamic> m) => LearningInput(
    account: m['account'] as String,
    destination: m['destination'] as String,
    party: m['party'] as String,
    direction: m['direction'] as String,
    amount: m['amount'] as int,
    at: DateTime.fromMillisecondsSinceEpoch(m['at'] as int),
    destinationRole: m['role'] as String? ?? 'unset',
  );
}

class LearningLabel {
  const LearningLabel(this.type, this.category);
  final String type, category;
  String get key => jsonEncode([type, category]);
  factory LearningLabel.decode(String key) {
    final values = jsonDecode(key) as List;
    return LearningLabel(values[0] as String, values[1] as String);
  }
  bool fits(String direction) =>
      type == 'transfer' ||
      (direction == 'out' && type == 'expense') ||
      (direction == 'in' && type == 'income');
}

class LearningExample {
  const LearningExample(this.id, this.input, this.label);
  final String id;
  final LearningInput input;
  final LearningLabel label;
}

class PersonalPrediction {
  const PersonalPrediction(this.label, this.score, this.support, this.evidence);
  final LearningLabel label;

  /// 모델의 상대 점수이며 실측 정확도가 아니다. 사용자에게 %로 표시하지 않는다.
  final double score;
  final int support;
  final String evidence;
}

class PersonalClassifier {
  PersonalClassifier(List<LearningExample> examples)
    : examples = List.unmodifiable(examples) {
    _train();
  }
  final List<LearningExample> examples;
  final _weights = <String, Map<String, double>>{};

  Map<String, double> _probabilities(
    Map<String, double> x,
    Iterable<String> labels,
  ) {
    final scores = {
      for (final label in labels)
        label: x.entries.fold<double>(
          0,
          (sum, e) => sum + e.value * (_weights[label]?[e.key] ?? 0),
        ),
    };
    if (scores.isEmpty) return {};
    final maxScore = scores.values.reduce(math.max);
    final exp = scores.map(
      (key, value) => MapEntry(key, math.exp(value - maxScore)),
    );
    final sum = exp.values.fold<double>(0, (a, b) => a + b);
    return exp.map((key, value) => MapEntry(key, value / sum));
  }

  void _train() {
    for (final e in examples) {
      _weights.putIfAbsent(e.label.key, () => {});
    }
    final vectors = {for (final e in examples) e.id: e.input.features};
    for (var epoch = 0; epoch < 18; epoch++) {
      final ordered = epoch.isEven ? examples : examples.reversed;
      for (final e in ordered) {
        final x = vectors[e.id]!;
        final labels = _weights.keys.where(
          (k) => LearningLabel.decode(k).fits(e.input.direction),
        );
        final probabilities = _probabilities(x, labels);
        for (final p in probabilities.entries) {
          final error = (p.key == e.label.key ? 1.0 : 0.0) - p.value;
          final weights = _weights[p.key]!;
          for (final f in x.entries) {
            final old = weights[f.key] ?? 0;
            weights[f.key] =
                old +
                0.12 / (1 + epoch * 0.1) * (error * f.value - 0.002 * old);
          }
        }
      }
    }
  }

  PersonalPrediction? predict(LearningInput input, {String? excludeId}) {
    final near = examples
        .where((e) => e.id != excludeId && input.similarTo(e.input))
        .toList();
    if (near.length < 2) return null;
    final probabilities = _probabilities(
      input.features,
      _weights.keys.where((k) => LearningLabel.decode(k).fits(input.direction)),
    );
    if (probabilities.isEmpty) return null;
    final ranked = probabilities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final best = ranked.first;
    final support = near.where((e) => e.label.key == best.key).length;
    if (support < 2 ||
        support / near.length < 0.75 ||
        best.value < 0.6 ||
        (ranked.length > 1 && best.value - ranked[1].value < 0.2)) {
      return null;
    }
    return PersonalPrediction(
      LearningLabel.decode(best.key),
      math.min(0.95, best.value),
      support,
      '비슷한 거래에서 직접 확인한 $support건을 바탕으로 추천했어요.',
    );
  }
}
