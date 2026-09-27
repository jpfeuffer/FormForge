import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import 'garmin_endpoints.dart';
import 'garmin_exceptions.dart';
import 'garmin_tokens.dart';
import 'oauth1.dart';
import 'sso_html.dart';

typedef MfaPrompt = Future<String> Function();

typedef _Ticket = ({String ticket, String serviceUrl});

typedef _Strategy = Future<_Ticket> Function(
  _Http http,
  String email,
  String password,
  MfaPrompt prompt,
);

/// Unofficial Garmin SSO login: credentials → CAS service ticket → OAuth2
/// bearer tokens. The password is only held for the duration of [login].
class GarminAuth {
  GarminAuth({
    Dio? dio,
    DateTime Function()? clock,
    Duration Function()? widgetDelay,
    this._consumer,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 30),
               receiveTimeout: const Duration(seconds: 30),
             ),
           ),
       _clock = clock ?? DateTime.now,
       _widgetDelay = widgetDelay ?? _randomWidgetDelay;

  final Dio _dio;
  final DateTime Function() _clock;
  final Duration Function() _widgetDelay;
  OAuth1Credentials? _consumer;

  // Cloudflare flags an instant GET→POST on the widget as bot traffic.
  static Duration _randomWidgetDelay() =>
      Duration(milliseconds: 3000 + Random().nextInt(5000));

  Future<GarminTokens> login(
    String email,
    String password, {
    required MfaPrompt promptMfa,
  }) async {
    var prompted = false;
    Future<String> prompt() async {
      prompted = true;
      final code = (await promptMfa()).trim();
      if (code.isEmpty) throw const GarminMfaRequired();
      return code;
    }

    final errors = <GarminException>[];
    for (final _Strategy strategy in [_mobileLogin, _widgetLogin]) {
      try {
        final t = await strategy(_Http(_dio), email, password, prompt);
        return await exchangeTicket(t.ticket, t.serviceUrl);
      } on GarminInvalidCredentials {
        rethrow;
      } on GarminException catch (e) {
        // A second strategy would ask for another MFA code.
        if (prompted) rethrow;
        errors.add(e);
      }
    }
    throw errors.firstWhere(
      (e) => e is GarminRateLimited,
      orElse: () => errors.last,
    );
  }

  /// Trades a CAS service ticket for tokens: DI OAuth2 first, legacy
  /// garth OAuth1 → OAuth2 exchange as fallback.
  Future<GarminTokens> exchangeTicket(String ticket, String serviceUrl) async {
    try {
      return await _diExchange(ticket, serviceUrl);
    } on GarminRateLimited {
      rethrow;
    } on GarminException {
      return _legacyExchange(ticket, serviceUrl);
    }
  }

  Future<GarminTokens> refresh(GarminTokens tokens) async {
    if (tokens.hasDiRefresh) {
      try {
        return (await _diRefresh(tokens)).inheritOAuth1(tokens);
      } on GarminNotConnected {
        if (!tokens.hasOAuth1) rethrow;
      }
    }
    if (tokens.hasOAuth1) {
      return _oauth1Exchange(
        tokens.oauth1Token!,
        tokens.oauth1Secret!,
        tokens.mfaToken,
      );
    }
    throw const GarminNotConnected();
  }

  Future<_Ticket> _mobileLogin(
    _Http http,
    String email,
    String password,
    MfaPrompt prompt,
  ) async {
    const service = GarminEndpoints.iosServiceUrl;
    const query = {
      'clientId': GarminEndpoints.iosClientId,
      'locale': 'en-US',
      'service': service,
    };
    const headers = {
      'User-Agent': GarminEndpoints.iosLoginUserAgent,
      'Accept': 'application/json, text/plain, */*',
      'Origin': GarminEndpoints.sso,
    };
    var json = _ssoJson(
      await http.send(
        'POST',
        '${GarminEndpoints.sso}/mobile/api/login',
        query: query,
        headers: headers,
        json: {
          'username': email,
          'password': password,
          'rememberMe': true,
          'captchaToken': '',
        },
      ),
    );
    switch (_responseType(json)) {
      case 'SUCCESSFUL':
        return (ticket: _serviceTicket(json), serviceUrl: service);
      case 'MFA_REQUIRED':
        final info = json['customerMfaInfo'];
        final method =
            (info is Map ? info['mfaLastMethodUsed'] : null) ?? 'email';
        final code = await prompt();
        json = _ssoJson(
          await http.send(
            'POST',
            '${GarminEndpoints.sso}/mobile/api/mfa/verifyCode',
            query: query,
            headers: headers,
            json: {
              'mfaMethod': method,
              'mfaVerificationCode': code,
              'rememberMyBrowser': true,
              'reconsentList': <Object>[],
              'mfaSetup': false,
            },
          ),
        );
        if (_responseType(json) != 'SUCCESSFUL') throw const GarminMfaFailed();
        return (ticket: _serviceTicket(json), serviceUrl: service);
      case 'INVALID_USERNAME_PASSWORD':
        throw const GarminInvalidCredentials();
      case 'CAPTCHA_REQUIRED':
        throw const GarminBlocked();
      case final type:
        throw GarminUnexpectedResponse(
          'mobile login status ${type ?? 'unknown'}',
        );
    }
  }

  Future<_Ticket> _widgetLogin(
    _Http http,
    String email,
    String password,
    MfaPrompt prompt,
  ) async {
    const ssoBase = '${GarminEndpoints.sso}/sso';
    const embed = GarminEndpoints.ssoEmbed;
    const ua = {'User-Agent': GarminEndpoints.desktopUserAgent};
    const embedQuery = {
      'id': 'gauth-widget',
      'embedWidget': 'true',
      'gauthHost': ssoBase,
    };
    final signinQuery = {
      ...embedQuery,
      'gauthHost': embed,
      'service': embed,
      'source': embed,
      'redirectAfterAccountLoginUrl': embed,
      'redirectAfterAccountCreationUrl': embed,
    };
    final signinUrl = Uri.parse('$ssoBase/signin')
        .replace(queryParameters: signinQuery)
        .toString();

    _html(await http.send('GET', embed, query: embedQuery, headers: ua));
    final signinPage = _html(
      await http.send(
        'GET',
        '$ssoBase/signin',
        query: signinQuery,
        headers: {...ua, 'Referer': embed},
      ),
    );
    final csrf =
        SsoHtml.csrf(signinPage) ??
        (throw const GarminUnexpectedResponse(
          'sign-in page without CSRF token',
        ));

    await Future<void>.delayed(_widgetDelay());
    var html = _html(
      await http.send(
        'POST',
        '$ssoBase/signin',
        query: signinQuery,
        headers: {...ua, 'Referer': signinUrl},
        form: {
          'username': email,
          'password': password,
          'embed': 'true',
          '_csrf': csrf,
        },
      ),
    );
    final title = SsoHtml.title(html);
    final lower = title.toLowerCase();
    if ([
      'locked',
      'invalid',
      'incorrect',
      'account error',
    ].any(lower.contains)) {
      throw const GarminInvalidCredentials();
    }
    final vars = SsoHtml.mfaVars(html);
    final isMfa =
        lower.contains('mfa') ||
        (lower.contains('authentication application') &&
            (vars['mfaMethod'] ?? '').isNotEmpty);
    if (isMfa) {
      await _requestWidgetMfaCode(http, vars, signinUrl);
      final code = await prompt();
      final mfaCsrf =
          SsoHtml.csrf(html) ??
          (throw const GarminUnexpectedResponse('MFA page without CSRF token'));
      html = _html(
        await http.send(
          'POST',
          '$ssoBase/verifyMFA/loginEnterMfaCode',
          query: signinQuery,
          headers: {...ua, 'Referer': signinUrl},
          form: {
            'mfa-code': code,
            'embed': 'true',
            '_csrf': mfaCsrf,
            'fromPage': 'setupEnterMfaCode',
          },
        ),
      );
      if (SsoHtml.title(html) != 'Success') throw const GarminMfaFailed();
    } else if (title != 'Success') {
      throw GarminUnexpectedResponse('sign-in page "$title"');
    }
    final ticket =
        SsoHtml.ticket(html) ??
        (throw const GarminUnexpectedResponse(
          'no service ticket on success page',
        ));
    return (ticket: ticket, serviceUrl: embed);
  }

  // Email/SMS codes are not always sent by the credential POST itself.
  Future<void> _requestWidgetMfaCode(
    _Http http,
    Map<String, String> vars,
    String referer,
  ) async {
    final method = (vars['mfaMethod'] ?? '').toLowerCase();
    if ((method != 'email' && method != 'sms') ||
        (vars['codeSentTo'] ?? '').isNotEmpty) {
      return;
    }
    final r = await http.send(
      'POST',
      '${GarminEndpoints.sso}/sso/verifyMFA/mfaCode',
      query: {'clientId': vars['clientId'] ?? ''},
      headers: {
        'User-Agent': GarminEndpoints.desktopUserAgent,
        'Accept': 'application/json, text/plain, */*',
        'Referer': referer,
      },
      json: {
        'customerGuid': vars['customerGuid'] ?? '',
        'mfaMethod': vars['mfaMethod'],
        'locale': vars['locale'] ?? '',
      },
    );
    if (r.statusCode == 429) throw const GarminRateLimited();
  }

  Future<GarminTokens> _diExchange(String ticket, String serviceUrl) async {
    for (final clientId in GarminEndpoints.diClientIds) {
      final r = await _Http(_dio).send(
        'POST',
        GarminEndpoints.diToken,
        headers: _diHeaders(clientId),
        form: {
          'client_id': clientId,
          'service_ticket': ticket,
          'grant_type': GarminEndpoints.diGrantType,
          'service_url': serviceUrl,
        },
      );
      if (r.statusCode == 429) throw const GarminRateLimited();
      if (_ok(r)) {
        if (_parseDi(r.data, clientId) case final tokens?) return tokens;
      }
    }
    throw const GarminUnexpectedResponse('DI token exchange failed');
  }

  Future<GarminTokens> _diRefresh(GarminTokens t) async {
    final r = await _Http(_dio).send(
      'POST',
      GarminEndpoints.diToken,
      headers: _diHeaders(t.clientId!),
      form: {
        'grant_type': 'refresh_token',
        'client_id': t.clientId!,
        'refresh_token': t.refreshToken!,
      },
    );
    final status = r.statusCode ?? 0;
    if (status == 429) throw const GarminRateLimited();
    if (status >= 500) {
      throw GarminUnexpectedResponse('token refresh HTTP $status');
    }
    final fresh = _ok(r)
        ? _parseDi(r.data, t.clientId!, fallbackRefresh: t.refreshToken)
        : null;
    return fresh ?? (throw const GarminNotConnected(_sessionExpired));
  }

  Map<String, String> _diHeaders(String clientId) => {
    ...GarminEndpoints.nativeHeaders,
    'Authorization': 'Basic ${base64.encode(utf8.encode('$clientId:'))}',
    'Accept': 'application/json',
    'Cache-Control': 'no-cache',
  };

  GarminTokens? _parseDi(
    String? body,
    String clientId, {
    String? fallbackRefresh,
  }) {
    final json = _tryJson(body);
    final access = json?['access_token'];
    if (access is! String) return null;
    final claims = _jwtClaims(access);
    return GarminTokens(
      accessToken: access,
      refreshToken: json!['refresh_token'] as String? ?? fallbackRefresh,
      expiresAt: _expiry(json['expires_in'], claims),
      clientId: claims?['client_id'] as String? ?? clientId,
    );
  }

  Future<GarminTokens> _legacyExchange(String ticket, String serviceUrl) async {
    final consumer = await _loadConsumer();
    final uri = Uri.parse('${GarminEndpoints.oauthService}/preauthorized')
        .replace(
          queryParameters: {
            'ticket': ticket,
            'login-url': serviceUrl,
            'accepts-mfa-tokens': 'true',
          },
        );
    final r = await _Http(_dio).send(
      'GET',
      uri.toString(),
      headers: {
        'User-Agent': GarminEndpoints.oauthUserAgent,
        'Authorization': OAuth1.authorizationHeader(
          method: 'GET',
          uri: uri,
          credentials: consumer,
        ),
      },
    );
    _check(r, 'OAuth1 preauthorization');
    final fields = Uri.splitQueryString(r.data ?? '');
    final (token, secret) = (
      fields['oauth_token'],
      fields['oauth_token_secret'],
    );
    if (token == null || secret == null) {
      throw const GarminUnexpectedResponse('no OAuth1 token');
    }
    return _oauth1Exchange(token, secret, fields['mfa_token'], login: true);
  }

  Future<GarminTokens> _oauth1Exchange(
    String token,
    String secret,
    String? mfaToken, {
    bool login = false,
  }) async {
    final consumer = await _loadConsumer();
    final uri = Uri.parse('${GarminEndpoints.oauthService}/exchange/user/2.0');
    final body = {
      if (login) 'audience': 'GARMIN_CONNECT_MOBILE_ANDROID_DI',
      'mfa_token': ?mfaToken,
    };
    final credentials = OAuth1Credentials(
      consumerKey: consumer.consumerKey,
      consumerSecret: consumer.consumerSecret,
      token: token,
      tokenSecret: secret,
    );
    final r = await _Http(_dio).send(
      'POST',
      uri.toString(),
      headers: {
        'User-Agent': GarminEndpoints.oauthUserAgent,
        'Authorization': OAuth1.authorizationHeader(
          method: 'POST',
          uri: uri,
          credentials: credentials,
          bodyParams: body,
        ),
      },
      form: body,
    );
    if (r.statusCode == 401) throw const GarminNotConnected(_sessionExpired);
    _check(r, 'OAuth2 exchange');
    final json = _tryJson(r.data);
    final access = json?['access_token'];
    if (access is! String) {
      throw const GarminUnexpectedResponse(
        'OAuth2 exchange without access token',
      );
    }
    return GarminTokens(
      accessToken: access,
      refreshToken: json!['refresh_token'] as String?,
      expiresAt: _expiry(json['expires_in'], _jwtClaims(access)),
      oauth1Token: token,
      oauth1Secret: secret,
      mfaToken: mfaToken,
    );
  }

  Future<OAuth1Credentials> _loadConsumer() async {
    if (_consumer case final c?) return c;
    final r = await _Http(_dio).send('GET', GarminEndpoints.oauthConsumerUrl);
    final json = _ok(r) ? _tryJson(r.data) : null;
    final (key, secret) = (json?['consumer_key'], json?['consumer_secret']);
    if (key is! String || secret is! String) {
      throw const GarminUnexpectedResponse('OAuth consumer unavailable');
    }
    return _consumer = OAuth1Credentials(
      consumerKey: key,
      consumerSecret: secret,
    );
  }

  DateTime _expiry(Object? expiresIn, Map<String, Object?>? claims) {
    if (expiresIn is num) {
      return _clock().add(Duration(seconds: expiresIn.toInt()));
    }
    if (claims?['exp'] case final num exp) {
      return DateTime.fromMillisecondsSinceEpoch(
        exp.toInt() * 1000,
        isUtc: true,
      );
    }
    return _clock().add(const Duration(hours: 1));
  }

  static const _sessionExpired = 'Garmin session expired. Please log in again.';
}

bool _ok(Response<Object?> r) {
  final s = r.statusCode ?? 0;
  return s >= 200 && s < 300;
}

void _check(Response<String> r, String step) {
  final s = r.statusCode ?? 0;
  if (s == 429) throw const GarminRateLimited();
  if (s == 403) throw const GarminBlocked();
  if (!_ok(r)) throw GarminUnexpectedResponse('$step HTTP $s');
}

String _html(Response<String> r) {
  _check(r, 'SSO page');
  final html = r.data ?? '';
  final title = SsoHtml.title(html).toLowerCase();
  if (title.contains('just a moment') || title.contains('attention required')) {
    throw const GarminBlocked();
  }
  return html;
}

Map<String, Object?> _ssoJson(Response<String> r) {
  final s = r.statusCode ?? 0;
  if (s == 429) throw const GarminRateLimited();
  if (s == 403) throw const GarminBlocked();
  final json =
      _tryJson(r.data) ??
      (throw GarminUnexpectedResponse('SSO HTTP $s without JSON body'));
  final error = json['error'];
  if (error is Map && '${error['status-code']}' == '429') {
    throw const GarminRateLimited();
  }
  return json;
}

String? _responseType(Map<String, Object?> json) {
  final status = json['responseStatus'];
  return status is Map ? status['type'] as String? : null;
}

String _serviceTicket(Map<String, Object?> json) {
  final ticket = json['serviceTicketId'];
  if (ticket is! String || ticket.isEmpty) {
    throw const GarminUnexpectedResponse('login succeeded without a ticket');
  }
  return ticket;
}

Map<String, Object?>? _tryJson(String? body) {
  if (body == null || body.isEmpty) return null;
  try {
    final json = jsonDecode(body);
    return json is Map<String, Object?> ? json : null;
  } on FormatException {
    return null;
  }
}

/// Reads JWT claims without verifying the signature (only used for expiry).
Map<String, Object?>? _jwtClaims(String token) {
  final parts = token.split('.');
  if (parts.length < 2) return null;
  try {
    return _tryJson(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
  } on FormatException {
    return null;
  }
}

/// Minimal session: cookie jar for the SSO pages, never throws on HTTP status.
class _Http {
  _Http(this._dio);
  final Dio _dio;
  final _cookies = <String, String>{};

  Future<Response<String>> send(
    String method,
    String url, {
    Map<String, String>? query,
    Map<String, String> headers = const {},
    Map<String, Object?>? json,
    Map<String, String>? form,
  }) async {
    final Response<String> r;
    try {
      r = await _dio.request<String>(
        url,
        queryParameters: query,
        data: json ?? form,
        options: Options(
          method: method,
          headers: {
            ...headers,
            if (_cookies.isNotEmpty)
              'Cookie': _cookies.entries
                  .map((e) => '${e.key}=${e.value}')
                  .join('; '),
          },
          contentType: json != null
              ? Headers.jsonContentType
              : form != null
              ? Headers.formUrlEncodedContentType
              : null,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw GarminNetworkError(e.type.name);
    }
    for (final cookie in r.headers['set-cookie'] ?? const <String>[]) {
      final pair = cookie.split(';').first;
      final i = pair.indexOf('=');
      if (i > 0) {
        _cookies[pair.substring(0, i).trim()] = pair.substring(i + 1).trim();
      }
    }
    return r;
  }
}
