import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// RFC 5849 §3.6 percent-encoding.
String oauthPercentEncode(String value) {
  final out = StringBuffer();
  for (final b in utf8.encode(value)) {
    final unreserved =
        (b >= 0x30 && b <= 0x39) ||
        (b >= 0x41 && b <= 0x5A) ||
        (b >= 0x61 && b <= 0x7A) ||
        b == 0x2D ||
        b == 0x2E ||
        b == 0x5F ||
        b == 0x7E;
    out.write(
      unreserved
          ? String.fromCharCode(b)
          : '%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}',
    );
  }
  return out.toString();
}

class OAuth1Credentials {
  const OAuth1Credentials({
    required this.consumerKey,
    required this.consumerSecret,
    this.token,
    this.tokenSecret,
  });

  final String consumerKey;
  final String consumerSecret;
  final String? token;
  final String? tokenSecret;

  @override
  String toString() => 'OAuth1Credentials(<redacted>)';
}

/// HMAC-SHA1 request signing (RFC 5849 §3.4).
abstract final class OAuth1 {
  static String baseStringUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final defaultPort =
        (scheme == 'http' && uri.port == 80) ||
        (scheme == 'https' && uri.port == 443);
    final port = uri.hasPort && !defaultPort ? ':${uri.port}' : '';
    final path = uri.path.isEmpty ? '/' : uri.path;
    return '$scheme://${uri.host.toLowerCase()}$port$path';
  }

  /// [params] are decoded name/value pairs from query, body and oauth_* fields.
  static String baseString(
    String method,
    Uri uri,
    Iterable<(String, String)> params,
  ) {
    final encoded =
        [
          for (final (k, v) in params)
            (oauthPercentEncode(k), oauthPercentEncode(v)),
        ]..sort((a, b) {
          final byName = a.$1.compareTo(b.$1);
          return byName != 0 ? byName : a.$2.compareTo(b.$2);
        });
    final normalized = encoded.map((p) => '${p.$1}=${p.$2}').join('&');
    return [
      method.toUpperCase(),
      oauthPercentEncode(baseStringUri(uri)),
      oauthPercentEncode(normalized),
    ].join('&');
  }

  static String hmacSha1(
    String baseString,
    String consumerSecret,
    String? tokenSecret,
  ) {
    final key =
        '${oauthPercentEncode(consumerSecret)}&${oauthPercentEncode(tokenSecret ?? '')}';
    final digest = Hmac(
      sha1,
      utf8.encode(key),
    ).convert(utf8.encode(baseString));
    return base64.encode(digest.bytes);
  }

  /// Builds the `Authorization: OAuth ...` header value for a request.
  /// [bodyParams] must be the decoded form fields of an
  /// `application/x-www-form-urlencoded` body (empty otherwise).
  static String authorizationHeader({
    required String method,
    required Uri uri,
    required OAuth1Credentials credentials,
    Map<String, String> bodyParams = const {},
    String? nonce,
    int? timestamp,
    bool includeVersion = true,
  }) {
    final oauth = <String, String>{
      'oauth_consumer_key': credentials.consumerKey,
      'oauth_nonce': nonce ?? _nonce(),
      'oauth_signature_method': 'HMAC-SHA1',
      'oauth_timestamp':
          '${timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000}',
      if (credentials.token != null) 'oauth_token': credentials.token!,
      if (includeVersion) 'oauth_version': '1.0',
    };
    final params = <(String, String)>[
      for (final e in uri.queryParametersAll.entries)
        for (final v in e.value) (e.key, v),
      for (final e in bodyParams.entries) (e.key, e.value),
      for (final e in oauth.entries) (e.key, e.value),
    ];
    oauth['oauth_signature'] = hmacSha1(
      baseString(method, uri, params),
      credentials.consumerSecret,
      credentials.tokenSecret,
    );
    return 'OAuth ${oauth.entries.map((e) => '${oauthPercentEncode(e.key)}="${oauthPercentEncode(e.value)}"').join(', ')}';
  }

  static String _nonce() {
    final r = Random.secure();
    return List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
