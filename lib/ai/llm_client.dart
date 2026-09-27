import 'dart:convert';

import 'package:dio/dio.dart';

enum LlmProviderKind {
  openAiCompatible('OpenAI-compatible (OpenAI, OpenRouter, Ollama, LM Studio…)',
      'https://api.openai.com/v1'),
  anthropic('Anthropic Claude', 'https://api.anthropic.com/v1'),
  gemini('Google Gemini', 'https://generativelanguage.googleapis.com/v1beta');

  const LlmProviderKind(this.label, this.defaultBaseUrl);
  final String label;
  final String defaultBaseUrl;
}

class LlmConfig {
  const LlmConfig({
    required this.kind,
    required this.baseUrl,
    required this.model,
    this.apiKey,
  });

  final LlmProviderKind kind;
  final String baseUrl;
  final String model;

  /// Optional for local servers such as Ollama.
  final String? apiKey;
}

class LlmException implements Exception {
  LlmException(this.message);
  final String message;
  @override
  String toString() => 'LlmException: $message';
}

/// Provider-agnostic text/JSON completion. The caller always validates output.
abstract interface class LlmClient {
  /// Returns raw text; when [jsonSchema] is set, the text is a JSON document.
  Future<String> complete({
    required String system,
    required String prompt,
    Map<String, Object?>? jsonSchema,
  });

  factory LlmClient(LlmConfig config, {Dio? dio}) {
    final http = dio ?? Dio();
    return switch (config.kind) {
      LlmProviderKind.openAiCompatible => _OpenAiCompatibleClient(config, http),
      LlmProviderKind.anthropic => _AnthropicClient(config, http),
      LlmProviderKind.gemini => _GeminiClient(config, http),
    };
  }
}

String _withSchema(String system, Map<String, Object?>? schema) => schema ==
        null
    ? system
    : '$system\n\nRespond ONLY with a JSON document matching this JSON Schema:\n'
        '${jsonEncode(schema)}';

String _trimSlash(String url) =>
    url.endsWith('/') ? url.substring(0, url.length - 1) : url;

class _OpenAiCompatibleClient implements LlmClient {
  _OpenAiCompatibleClient(this.config, this.dio);
  final LlmConfig config;
  final Dio dio;

  @override
  Future<String> complete({
    required String system,
    required String prompt,
    Map<String, Object?>? jsonSchema,
  }) async {
    final res = await dio.post<Map<String, dynamic>>(
      '${_trimSlash(config.baseUrl)}/chat/completions',
      options: Options(headers: {
        if (config.apiKey?.isNotEmpty ?? false)
          'Authorization': 'Bearer ${config.apiKey}',
      }),
      data: {
        'model': config.model,
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': prompt},
        ],
        if (jsonSchema != null)
          'response_format': {
            'type': 'json_schema',
            'json_schema': {'name': 'result', 'schema': jsonSchema},
          },
      },
    );
    final content = res.data?['choices']?[0]?['message']?['content'];
    if (content is! String) throw LlmException('Empty response');
    return content;
  }
}

class _AnthropicClient implements LlmClient {
  _AnthropicClient(this.config, this.dio);
  final LlmConfig config;
  final Dio dio;

  @override
  Future<String> complete({
    required String system,
    required String prompt,
    Map<String, Object?>? jsonSchema,
  }) async {
    final res = await dio.post<Map<String, dynamic>>(
      '${_trimSlash(config.baseUrl)}/messages',
      options: Options(headers: {
        'x-api-key': config.apiKey,
        'anthropic-version': '2023-06-01',
      }),
      data: {
        'model': config.model,
        'max_tokens': 4096,
        'system': _withSchema(system, jsonSchema),
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      },
    );
    final blocks = (res.data?['content'] as List?) ?? const [];
    final text = blocks
        .whereType<Map>()
        .where((b) => b['type'] == 'text')
        .map((b) => b['text'] as String)
        .join();
    if (text.isEmpty) throw LlmException('Empty response');
    return text;
  }
}

class _GeminiClient implements LlmClient {
  _GeminiClient(this.config, this.dio);
  final LlmConfig config;
  final Dio dio;

  @override
  Future<String> complete({
    required String system,
    required String prompt,
    Map<String, Object?>? jsonSchema,
  }) async {
    final res = await dio.post<Map<String, dynamic>>(
      '${_trimSlash(config.baseUrl)}/models/${config.model}:generateContent',
      options: Options(headers: {'x-goog-api-key': config.apiKey}),
      data: {
        'systemInstruction': {
          'parts': [
            {'text': _withSchema(system, jsonSchema)}
          ]
        },
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': prompt}
            ]
          }
        ],
        if (jsonSchema != null)
          'generationConfig': {'responseMimeType': 'application/json'},
      },
    );
    final parts =
        (res.data?['candidates']?[0]?['content']?['parts'] as List?) ?? const [];
    final text = parts.whereType<Map>().map((p) => p['text'] ?? '').join();
    if (text.isEmpty) throw LlmException('Empty response');
    return text;
  }
}
