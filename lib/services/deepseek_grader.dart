import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 批改结果。
class GradeOutcome {
  const GradeOutcome({
    required this.isCorrect,
    this.correctAnswer,
    this.reason,
  });

  final bool isCorrect;

  /// 正确答案。做错的题尤其需要——孩子重做时可以直接对照。
  final String? correctAnswer;

  /// 模型给出的简短理由，展示在确认页帮助家长复核。
  final String? reason;

  String get gradeResult => isCorrect ? 'correct' : 'wrong';
}

/// 批改失败的原因。批量批改时要能逐题报告，而不是整批崩掉。
class GradeException implements Exception {
  GradeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 用 DeepSeek 的视觉模型批改一道题。
///
/// 为什么走模型而不是传统的答案比对：题目是**手写**在纸上的，答案也是手写的，
/// 而且题型五花八门（计算、填空、应用题）。要对上答案得先有一份标准答案，这里
/// 没有。视觉模型能同时看见题干和孩子写的答案，直接判断对错并给出正确答案。
///
/// 用的是 `deepseek-flash`，它是多模态的（见
/// https://api-docs.deepseek.com/zh-cn/guides/vision/）。
class DeepSeekGrader {
  DeepSeekGrader({
    required this.apiKey,
    this.model = 'deepseek-flash',
    this.endpoint = 'https://api.deepseek.com/chat/completions',
    Duration? timeout,
  }) : timeout = timeout ?? const Duration(seconds: 90);

  final String apiKey;
  final String model;
  final String endpoint;
  final Duration timeout;

  /// 单张图片的请求体上限是 32 MiB，内联进 JSON 的整包上限 48 MiB。
  /// base64 会膨胀约 1/3，所以按 20 MB 原图设限，留足余量。
  static const maxImageBytes = 20 * 1024 * 1024;

  /// 批改一道题。[imageBytes] 是切出来的那道题（含孩子的手写答案）。
  Future<GradeOutcome> grade({
    required Uint8List imageBytes,
    required int grade,
    String? subject,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw GradeException('还没有配置 DeepSeek API Key');
    }
    if (imageBytes.length > maxImageBytes) {
      throw GradeException('这道题的图片太大了，无法上传批改');
    }

    final body = jsonEncode({
      'model': model,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': _prompt(grade: grade, subject: subject)},
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:image/jpeg;base64,${base64Encode(imageBytes)}',
                // 手写字要看清笔迹，low 会缩到 512×512，不够。
                'detail': 'high',
              },
            },
          ],
        },
      ],
      // 让模型直接输出 JSON，省掉解析自然语言的不确定性。
      'response_format': {'type': 'json_object'},
      'temperature': 0,
    });

    final client = HttpClient();
    client.connectionTimeout = timeout;
    try {
      final request = await client
          .postUrl(Uri.parse(endpoint))
          .timeout(timeout);
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
        ..contentType = ContentType('application', 'json', charset: 'utf-8');
      request.add(utf8.encode(body));

      final response = await request.close().timeout(timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);

      if (response.statusCode != 200) {
        throw GradeException(_explainHttpError(response.statusCode, text));
      }
      return parseResponse(text);
    } on GradeException {
      rethrow;
    } on SocketException {
      throw GradeException('连不上 DeepSeek，检查网络');
    } catch (error) {
      throw GradeException('批改失败：$error');
    } finally {
      client.close(force: true);
    }
  }

  /// 解析模型的响应。
  ///
  /// 单独暴露出来是为了能在离线状态下测——这段逻辑要处理模型不听话的各种情况
  /// （加了解释、包了代码围栏、字段名写错），比网络调用更需要测试。
  static GradeOutcome parseResponse(String raw) => _parseStatic(raw);

  String _explainHttpError(int code, String body) => switch (code) {
    401 => 'API Key 无效',
    402 => 'DeepSeek 账户余额不足',
    429 => '请求太频繁，稍后再试',
    _ => 'DeepSeek 返回 $code：${body.length > 200 ? body.substring(0, 200) : body}',
  };

  String _prompt({required int grade, String? subject}) {
    final gradeText = switch (grade) {
      <= 6 => '小学${_cn(grade)}年级',
      <= 9 => '初中${_cn(grade - 6)}年级',
      _ => '高中${_cn(grade - 9)}年级',
    };
    final subjectText = (subject == null || subject.isEmpty)
        ? ''
        : '这应该是$subject题。';

    return '''
你是批改作业的老师。图片是一道题的照片，上面有题目和学生的**手写答案**。

学生情况：$gradeText。$subjectText

请判断学生这道题**做对了还是做错了**，并按下面的 JSON 格式回答，不要输出别的内容：

{
  "correct": true 或 false,
  "correctAnswer": "这道题的正确答案",
  "reason": "一句话说明判断依据"
}

判断要求：
1. 仔细辨认学生的手写答案。字迹潦草时结合上下文推断，不要因为看不清就判错。
2. 如果学生没有作答、或者答案被涂改得无法辨认，correct 填 false，并在 reason 里说明。
3. correctAnswer 要给出**这道题本身**的正确答案（不是学生的答案）。
   如果题目有多个空，把每个空的答案都写出来。
4. 只判断对错，不要重新出题，不要评价学生。
''';
  }

  String _cn(int n) => const [
    '',
    '一',
    '二',
    '三',
    '四',
    '五',
    '六',
  ].elementAt(n.clamp(0, 6));

  static GradeOutcome _parseStatic(String raw) {
    final content = _extractContentStatic(raw);
    final decoded = _firstJsonObjectStatic(content);
    if (decoded == null) {
      throw GradeException('模型返回的内容看不懂');
    }

    final correct = decoded['correct'];
    final isCorrect = correct is bool
        ? correct
        : correct?.toString().toLowerCase() == 'true';

    String? clean(Object? value) {
      if (value == null) return null;
      final text = value.toString().trim();
      return text.isEmpty ? null : text;
    }

    return GradeOutcome(
      isCorrect: isCorrect,
      correctAnswer: clean(
        decoded['correctAnswer'] ?? decoded['correct_answer'],
      ),
      reason: clean(decoded['reason']),
    );
  }

  /// 从 OpenAI 兼容的响应里取 `choices[0].message.content`。
  static String _extractContentStatic(String raw) {
    try {
      final body = jsonDecode(raw);
      if (body is Map && body['choices'] is List) {
        final choices = body['choices'] as List;
        if (choices.isNotEmpty) {
          final message = (choices.first as Map)['message'];
          if (message is Map && message['content'] != null) {
            return message['content'].toString();
          }
        }
      }
    } catch (_) {
      // 响应不是预期的形状，交给下面按原文处理。
    }
    return raw;
  }

  /// 取正文里第一个完整的 JSON 对象。
  ///
  /// 即便要求了 json_object，模型偶尔还是会加上解释或代码围栏，所以不假设正文
  /// 就是纯 JSON。花括号计数时要注意字符串里的括号和转义引号。
  static Map<String, Object?>? _firstJsonObjectStatic(String text) {
    final start = text.indexOf('{');
    if (start == -1) return null;

    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          try {
            final parsed = jsonDecode(text.substring(start, i + 1));
            return parsed is Map<String, Object?> ? parsed : null;
          } catch (_) {
            return null;
          }
        }
      }
    }
    return null;
  }
}

/// 从磁盘读一张题图，读不到就抛 [GradeException]。
Future<Uint8List> readQuestionImage(String path) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw GradeException('找不到题目图片');
  }
  return file.readAsBytes();
}
