import 'dart:convert';
import 'dart:io';

/// DeepSeek 调用失败的统一异常。
///
/// 批改和 OCR 都要把失败原因展示给用户，而且失败不该让整批处理停摆，所以错误
/// 消息要是人话，并且带上可判断的类型。
class DeepSeekException implements Exception {
  DeepSeekException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// DeepSeek 的 HTTP 客户端。
///
/// 批改和文字识别都是一次「文字指令 + 一张图」的对话补全，只有提示词和解析方式
/// 不同，所以 HTTP 这部分抽出来共用。
class DeepSeekClient {
  DeepSeekClient({
    required this.apiKey,
    this.model = 'deepseek-flash',
    this.endpoint = 'https://api.deepseek.com/chat/completions',
    Duration? timeout,
  }) : timeout = timeout ?? const Duration(seconds: 90);

  final String apiKey;
  final String model;
  final String endpoint;
  final Duration timeout;

  /// 单图上限 32 MiB，内联进 JSON 的整包上限 48 MiB，base64 还要膨胀约 1/3。
  /// 按 16 MB 原图设限，留足余量。
  static const maxImageBytes = 16 * 1024 * 1024;

  bool get hasKey => apiKey.trim().isNotEmpty;

  /// 纯文字请求，要求模型回 JSON。变式题用得上——不需要传图。
  Future<String> chatJsonOnly(String prompt) async {
    if (!hasKey) {
      throw DeepSeekException('还没有配置 DeepSeek API Key');
    }

    final payload = <String, Object?>{
      'model': model,
      'messages': [
        {
          'role': 'user',
          'content': prompt,
        },
      ],
      'response_format': {'type': 'json_object'},
      'temperature': 0.4,
    };

    return _send(payload);
  }

  /// 发一次「指令 + 图片」的请求，返回助手回复的正文。
  ///
  /// [detail] 传 `high` 或 `low`：手写笔迹和公式需要 high；单纯的印刷体文字
  /// 用 low 更快更省。
  Future<String> chatWithImage({
    required String prompt,
    required List<int> imageBytes,
    String detail = 'high',
    bool jsonOutput = true,
  }) async {
    if (!hasKey) {
      throw DeepSeekException('还没有配置 DeepSeek API Key');
    }
    if (imageBytes.length > maxImageBytes) {
      throw DeepSeekException('图片太大了（超过 16 MB），无法上传处理');
    }

    final payload = <String, Object?>{
      'model': model,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt},
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:image/jpeg;base64,${base64Encode(imageBytes)}',
                'detail': detail,
              },
            },
          ],
        },
      ],
      'temperature': 0,
      if (jsonOutput) 'response_format': {'type': 'json_object'},
    };

    return _send(payload);
  }

  /// 发一次请求并取回助手正文。错误统一翻译成人话。
  Future<String> _send(Map<String, Object?> payload) async {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    try {
      final request = await client
          .postUrl(Uri.parse(endpoint))
          .timeout(timeout);
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
        ..contentType = ContentType('application', 'json', charset: 'utf-8');
      request.add(utf8.encode(jsonEncode(payload)));

      final response = await request.close().timeout(timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);

      if (response.statusCode != 200) {
        throw DeepSeekException(_explain(response.statusCode, text));
      }
      return extractContent(text);
    } on DeepSeekException {
      rethrow;
    } on SocketException {
      throw DeepSeekException('连不上 DeepSeek，检查网络');
    } on HttpException catch (error) {
      throw DeepSeekException('网络错误：${error.message}');
    } catch (error) {
      throw DeepSeekException('调用失败：$error');
    } finally {
      client.close(force: true);
    }
  }

  String _explain(int code, String body) => switch (code) {
    401 => 'API Key 无效',
    402 => 'DeepSeek 账户余额不足',
    429 => '请求太频繁，稍后再试',
    400 => '请求被拒绝（图片可能过大或格式不支持）',
    _ => 'DeepSeek 返回 $code：${body.length > 200 ? body.substring(0, 200) : body}',
  };

  /// 从 OpenAI 兼容的响应里取 `choices[0].message.content`。
  static String extractContent(String raw) {
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
      // 响应形状不对，按原文返回，交给上层解析。
    }
    return raw;
  }

  /// 取正文里第一个完整的 JSON 对象。
  ///
  /// 即便要求了 json_object，模型偶尔还是会加上解释或代码围栏，所以不假设正文
  /// 就是纯 JSON。花括号计数时要跳过字符串里的括号和转义引号。
  static Map<String, Object?>? firstJsonObject(String text) {
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
