import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/secrets.dart';
import 'package:formforge/integrations/google/google_auth.dart';

import '../garmin/fake_http.dart';

class MemorySecrets extends Secrets {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

void main() {
  test(
    'desktop OAuth uses loopback, state and PKCE; persists account securely',
    () async {
      final secrets = MemorySecrets();
      Uri? authorizationUri;
      final http = FakeAdapter((request) {
        if (request.uri.path == '/token') {
          final fields = request.data as Map;
          expect(fields['grant_type'], 'authorization_code');
          expect(fields['code'], 'fake-code');
          expect(
            fields['redirect_uri'],
            authorizationUri!.queryParameters['redirect_uri'],
          );
          final challenge = base64Url
              .encode(
                sha256
                    .convert(ascii.encode(fields['code_verifier'] as String))
                    .bytes,
              )
              .replaceAll('=', '');
          expect(
            challenge,
            authorizationUri!.queryParameters['code_challenge'],
          );
          return FakeResponse.json({
            'access_token': 'fake-access',
            'refresh_token': 'fake-refresh',
            'expires_in': 3600,
            'token_type': 'Bearer',
            'scope': 'openid email $driveScope',
          });
        }
        expect(request.uri.host, 'openidconnect.googleapis.com');
        expect(request.headers['Authorization'], 'Bearer fake-access');
        return FakeResponse.json({
          'sub': 'account-1',
          'email': 'test@example.invalid',
          'email_verified': true,
        });
      });
      final auth = DesktopGoogleAuthorization(
        secrets,
        clientId: 'test-desktop',
        clientSecret: 'test-public-client',
        dio: http.dio,
        openBrowser: (uri) async {
          authorizationUri = uri;
          expect(uri.host, 'accounts.google.com');
          expect(uri.queryParameters['scope'], contains(driveScope));
          final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
          expect(redirect.host, '127.0.0.1');
          final client = HttpClient();
          try {
            final wrong = await client.getUrl(
              redirect.replace(
                queryParameters: {'state': 'wrong', 'code': 'bad'},
              ),
            );
            final wrongResponse = await wrong.close();
            expect(wrongResponse.statusCode, 400);
            await wrongResponse.drain<void>();
            final callback = await client.getUrl(
              redirect.replace(
                queryParameters: {
                  'state': uri.queryParameters['state']!,
                  'code': 'fake-code',
                },
              ),
            );
            final response = await callback.close();
            expect(response.statusCode, 200);
            await response.drain<void>();
          } finally {
            client.close(force: true);
          }
          return true;
        },
      );
      await auth.signIn();
      expect(auth.account?.id, 'account-1');
      expect(await auth.accessToken(), 'fake-access');
      final restarted = DesktopGoogleAuthorization(
        secrets,
        clientId: 'test-desktop',
      );
      await restarted.initialize();
      expect(restarted.account?.email, 'test@example.invalid');
      await restarted.signOut();
      expect(secrets.values, isEmpty);
      expect(restarted.account, isNull);
    },
  );

  test(
    'expired desktop token refreshes and retains refresh authorization',
    () async {
      final secrets = MemorySecrets();
      await secrets.write(
        Secrets.googleDesktopTokens,
        jsonEncode({
          'clientId': 'desktop',
          'id': 'account',
          'email': 'test@example.invalid',
          'access_token': 'expired',
          'refresh_token': 'fake-refresh',
          'expiresAt': DateTime(2020).toIso8601String(),
        }),
      );
      final http = FakeAdapter((request) {
        expect((request.data as Map)['grant_type'], 'refresh_token');
        expect((request.data as Map)['refresh_token'], 'fake-refresh');
        return FakeResponse.json({
          'access_token': 'new-token',
          'expires_in': 3600,
          'token_type': 'Bearer',
        });
      });
      final auth = DesktopGoogleAuthorization(
        secrets,
        clientId: 'desktop',
        clientSecret: 'public-client',
        dio: http.dio,
      );
      await auth.initialize();
      expect(await auth.accessToken(), 'new-token');
      expect(
        jsonDecode(
          secrets.values[Secrets.googleDesktopTokens]!,
        )['refresh_token'],
        'fake-refresh',
      );
      expect(await auth.accessToken(), 'new-token');
      expect(http.requests.length, 1);
    },
  );

  test('different OAuth client does not reuse stored tokens', () async {
    final secrets = MemorySecrets();
    await secrets.write(
      Secrets.googleDesktopTokens,
      jsonEncode({'clientId': 'old-client'}),
    );
    final auth = DesktopGoogleAuthorization(secrets, clientId: 'new-client');
    await auth.initialize();
    expect(auth.account, isNull);
    await expectLater(auth.accessToken(), throwsStateError);
  });

  test('missing configuration and browser failure fail explicitly', () async {
    final secrets = MemorySecrets();
    await expectLater(
      DesktopGoogleAuthorization(
        secrets,
        clientId: '',
        clientSecret: '',
      ).signIn(),
      throwsStateError,
    );
    final auth = DesktopGoogleAuthorization(
      secrets,
      clientId: 'configured',
      clientSecret: 'public',
      openBrowser: (_) async => false,
    );
    await expectLater(auth.signIn(), throwsStateError);
    expect(auth.account, isNull);
    expect(secrets.values, isEmpty);
  });

  test('Google consent denial does not save account or tokens', () async {
    final secrets = MemorySecrets();
    final auth = DesktopGoogleAuthorization(
      secrets,
      clientId: 'configured',
      clientSecret: 'public',
      openBrowser: (uri) async {
        final callback = Uri.parse(uri.queryParameters['redirect_uri']!)
            .replace(
              queryParameters: {
                'state': uri.queryParameters['state']!,
                'error': 'access_denied',
              },
            );
        final client = HttpClient();
        try {
          final request = await client.getUrl(callback);
          await (await request.close()).drain<void>();
        } finally {
          client.close(force: true);
        }
        return true;
      },
    );
    await expectLater(auth.signIn(), throwsStateError);
    expect(secrets.values, isEmpty);
  });
}
