import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/secrets.dart';

const driveScope = 'https://www.googleapis.com/auth/drive.appdata';

class GoogleAccount {
  const GoogleAccount(this.id, this.email);
  final String id;
  final String email;
}

abstract class GoogleAuthorization {
  GoogleAccount? get account;
  Future<void> initialize();
  Future<void> signIn();
  Future<void> signOut();
  Future<String> accessToken({bool refresh = false});
}

class AndroidGoogleAuthorization implements GoogleAuthorization {
  static const serverClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
  );
  final _google = GoogleSignIn.instance;
  GoogleSignInAccount? _user;
  Future<void>? _initialization;

  @override
  GoogleAccount? get account =>
      _user == null ? null : GoogleAccount(_user!.id, _user!.email);

  Future<void> _initializeSdk() =>
      _initialization ??= _google.initialize(serverClientId: serverClientId);

  @override
  Future<void> initialize() async {
    if (serverClientId.isEmpty) return;
    await _initializeSdk();
    _user = await _google.attemptLightweightAuthentication();
  }

  @override
  Future<void> signIn() async {
    if (serverClientId.isEmpty) {
      throw StateError(
        'Google sign-in is not configured. Build with GOOGLE_SERVER_CLIENT_ID and register the Android package/signing SHA in Google Cloud.',
      );
    }
    await _initializeSdk();
    final user = await _google.authenticate(scopeHint: [driveScope]);
    await user.authorizationClient.authorizeScopes([driveScope]);
    _user = user;
  }

  @override
  Future<String> accessToken({bool refresh = false}) async {
    final user = _user;
    if (user == null) throw StateError('Sign in to Google first');
    final client = user.authorizationClient;
    if (refresh) {
      final previous = await client.authorizationForScopes([driveScope]);
      if (previous != null) {
        await client.clearAuthorizationToken(accessToken: previous.accessToken);
      }
    }
    final authorization =
        await client.authorizationForScopes([driveScope]) ??
        await client.authorizeScopes([driveScope]);
    return authorization.accessToken;
  }

  @override
  Future<void> signOut() async {
    await _google.signOut();
    _user = null;
  }
}

class DesktopGoogleAuthorization implements GoogleAuthorization {
  DesktopGoogleAuthorization(
    this.secrets, {
    this.clientId = const String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_ID'),
    this.clientSecret = const String.fromEnvironment(
      'GOOGLE_DESKTOP_CLIENT_SECRET',
    ),
    Dio? dio,
    Future<bool> Function(Uri)? openBrowser,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 30),
               receiveTimeout: const Duration(seconds: 30),
             ),
           ),
       _openBrowser =
           openBrowser ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));

  final Secrets secrets;
  final String clientId;
  final String clientSecret;
  final Dio _dio;
  final Future<bool> Function(Uri) _openBrowser;
  Map<String, dynamic>? _tokens;
  GoogleAccount? _account;
  @override
  GoogleAccount? get account => _account;

  @override
  Future<void> initialize() async {
    final stored = await secrets.read(Secrets.googleDesktopTokens);
    if (stored == null) return;
    final value = jsonDecode(stored) as Map<String, dynamic>;
    if (value['clientId'] != clientId) return;
    _account = GoogleAccount(value['id'] as String, value['email'] as String);
    _tokens = value;
  }

  static String _random() => base64Url
      .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');

  @override
  Future<void> signIn() async {
    if (clientId.isEmpty || clientSecret.isEmpty) {
      throw StateError(
        'Google desktop sign-in is not configured. Build with GOOGLE_DESKTOP_CLIENT_ID and GOOGLE_DESKTOP_CLIENT_SECRET from a Desktop OAuth client.',
      );
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}/callback';
    final state = _random();
    final verifier = _random();
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final code = Completer<({String? code, String? error})>();
    final subscription = server.listen((request) async {
      if (request.uri.path != '/callback') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final params = request.uri.queryParameters;
      if (params['state'] != state) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(
          'Invalid sign-in state. Return to FormForge and retry.',
        );
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.text;
      if (!code.isCompleted) {
        if (params['error'] != null) {
          code.complete((
            code: null,
            error: 'Google authorization failed: ${params['error']}',
          ));
        } else if (params['code']?.isNotEmpty == true) {
          code.complete((code: params['code'], error: null));
        } else {
          code.complete((
            code: null,
            error: 'Google did not return an authorization code',
          ));
        }
      }
      request.response.write(
        'Authorization received. Return to FormForge to finish sign-in.',
      );
      await request.response.close();
    });
    try {
      final uri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': clientId,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': 'openid email $driveScope',
        'access_type': 'offline',
        'prompt': 'consent',
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      });
      if (!await _openBrowser(uri)) {
        throw StateError('Could not open your browser for Google sign-in');
      }
      final callback = await code.future.timeout(const Duration(minutes: 3));
      if (callback.error != null) throw StateError(callback.error!);
      final token = await _exchange({
        'grant_type': 'authorization_code',
        'code': callback.code!,
        'redirect_uri': redirect,
        'code_verifier': verifier,
      });
      final profile = await _dio.get<Map<String, dynamic>>(
        'https://openidconnect.googleapis.com/v1/userinfo',
        options: Options(
          headers: {'Authorization': 'Bearer ${token['access_token']}'},
        ),
      );
      final data = profile.data;
      if (data == null ||
          data['sub'] is! String ||
          data['email'] is! String ||
          data['email_verified'] != true ||
          token['refresh_token'] is! String) {
        throw const FormatException(
          'Google did not return a verified account and offline authorization',
        );
      }
      final stored = {
        ...token,
        'clientId': clientId,
        'id': data['sub'],
        'email': data['email'],
      };
      await secrets.write(Secrets.googleDesktopTokens, jsonEncode(stored));
      _tokens = stored;
      _account = GoogleAccount(data['sub'] as String, data['email'] as String);
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _exchange(Map<String, String> fields) async {
    final response = await _dio.post<Map<String, dynamic>>(
      'https://oauth2.googleapis.com/token',
      data: {...fields, 'client_id': clientId, 'client_secret': clientSecret},
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final value = response.data;
    if (value == null ||
        value['access_token'] is! String ||
        value['expires_in'] is! num ||
        (value['expires_in'] as num) <= 0 ||
        value['token_type'] != 'Bearer') {
      throw const FormatException('Invalid Google token response');
    }
    final scope = value['scope'];
    if (scope is String && !scope.split(' ').contains(driveScope)) {
      throw StateError('Google Drive backup permission was not granted');
    }
    return {
      ...value,
      'expiresAt': DateTime.now()
          .add(Duration(seconds: (value['expires_in'] as num).toInt()))
          .toIso8601String(),
    };
  }

  @override
  Future<String> accessToken({bool refresh = false}) async {
    final stored = _tokens;
    if (stored == null) throw StateError('Sign in to Google first');
    final expiry = DateTime.parse(stored['expiresAt'] as String);
    if (refresh ||
        expiry.isBefore(DateTime.now().add(const Duration(minutes: 1)))) {
      final updated = await _exchange({
        'grant_type': 'refresh_token',
        'refresh_token': stored['refresh_token'] as String,
      });
      final merged = {...stored, ...updated};
      await secrets.write(Secrets.googleDesktopTokens, jsonEncode(merged));
      _tokens = merged;
    }
    return _tokens!['access_token'] as String;
  }

  @override
  Future<void> signOut() async {
    await secrets.write(Secrets.googleDesktopTokens, null);
    _tokens = null;
    _account = null;
  }
}
