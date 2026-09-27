import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/integrations/garmin/garmin_auth.dart';
import 'package:formforge/integrations/garmin/garmin_exceptions.dart';
import 'package:formforge/integrations/garmin/garmin_tokens.dart';
import 'package:formforge/integrations/garmin/oauth1.dart';

import 'fake_http.dart';

final now = DateTime.utc(2026, 9, 27, 12);
const consumer = OAuth1Credentials(consumerKey: 'ck', consumerSecret: 'cs');

GarminAuth authWith(FakeAdapter fake) => GarminAuth(
  dio: fake.dio,
  clock: () => now,
  widgetDelay: () => Duration.zero,
  consumer: consumer,
);

FakeResponse diTokens({String access = 'di-access', int expiresIn = 3600}) =>
    FakeResponse.json({
      'access_token': access,
      'refresh_token': 'di-refresh',
      'expires_in': expiresIn,
    });

Future<String> noMfa() async => fail('MFA prompt not expected');

void main() {
  test('mobile login + DI token exchange', () async {
    final fake = FakeAdapter(
      (o) => switch (route(o)) {
        'POST sso.garmin.com/mobile/api/login' => FakeResponse.json({
          'responseStatus': {'type': 'SUCCESSFUL'},
          'serviceTicketId': 'ST-mobile',
        }),
        'POST diauth.garmin.com/di-oauth2-service/oauth/token' => diTokens(),
        _ => FakeResponse.text('not found', status: 404),
      },
    );

    final tokens = await authWith(fake).login('a@b.c', 'pw', promptMfa: noMfa);

    expect(tokens.accessToken, 'di-access');
    expect(tokens.refreshToken, 'di-refresh');
    expect(tokens.clientId, 'GARMIN_CONNECT_MOBILE_ANDROID_DI_2025Q2');
    expect(tokens.expiresAt, now.add(const Duration(hours: 1)));
    expect(tokens.hasOAuth1, isFalse);

    final login = fake.requests.first;
    expect(login.queryParameters['clientId'], 'GCM_IOS_DARK');
    expect((login.data as Map)['username'], 'a@b.c');
    final exchange = fake.requests[1];
    expect(
      exchange.headers['Authorization'],
      'Basic ${base64.encode(utf8.encode('GARMIN_CONNECT_MOBILE_ANDROID_DI_2025Q2:'))}',
    );
    expect(exchange.data, containsPair('service_ticket', 'ST-mobile'));
    expect(
      exchange.data,
      containsPair(
        'service_url',
        'https://mobile.integration.garmin.com/gcm/ios',
      ),
    );
    expect(exchange.contentType, Headers.formUrlEncodedContentType);
  });

  test('mobile MFA flow prompts once and verifies the code', () async {
    var prompts = 0;
    final fake = FakeAdapter(
      (o) => switch (route(o)) {
        'POST sso.garmin.com/mobile/api/login' => FakeResponse.json(
          {
            'responseStatus': {'type': 'MFA_REQUIRED'},
            'customerMfaInfo': {'mfaLastMethodUsed': 'sms'},
          },
          headers: {
            'set-cookie': ['SESSION=abc; Path=/; Secure; HttpOnly'],
          },
        ),
        'POST sso.garmin.com/mobile/api/mfa/verifyCode' =>
          (o.data as Map)['mfaVerificationCode'] == '123456'
              ? FakeResponse.json({
                  'responseStatus': {'type': 'SUCCESSFUL'},
                  'serviceTicketId': 'ST-mfa',
                })
              : FakeResponse.json({
                  'responseStatus': {'type': 'INVALID_MFA_CODE'},
                }),
        'POST diauth.garmin.com/di-oauth2-service/oauth/token' => diTokens(),
        _ => FakeResponse.text('', status: 404),
      },
    );

    final tokens = await authWith(fake).login(
      'a@b.c',
      'pw',
      promptMfa: () async {
        prompts++;
        return ' 123456 ';
      },
    );

    expect(prompts, 1);
    expect(tokens.accessToken, 'di-access');
    final verify = fake.requests[1];
    expect(verify.data, containsPair('mfaMethod', 'sms'));
    expect(verify.headers['Cookie'], 'SESSION=abc');
  });

  test('wrong MFA code fails without trying another strategy', () async {
    final fake = FakeAdapter(
      (o) => switch (route(o)) {
        'POST sso.garmin.com/mobile/api/login' => FakeResponse.json({
          'responseStatus': {'type': 'MFA_REQUIRED'},
        }),
        _ => FakeResponse.json({
          'responseStatus': {'type': 'INVALID_MFA_CODE'},
        }),
      },
    );
    await expectLater(
      authWith(fake).login('a', 'b', promptMfa: () async => '1'),
      throwsA(isA<GarminMfaFailed>()),
    );
    expect(fake.requests, hasLength(2));
  });

  test('cancelled MFA prompt surfaces as MFA required', () async {
    final fake = FakeAdapter(
      (_) => FakeResponse.json({
        'responseStatus': {'type': 'MFA_REQUIRED'},
      }),
    );
    await expectLater(
      authWith(fake).login('a', 'b', promptMfa: () async => ''),
      throwsA(isA<GarminMfaRequired>()),
    );
  });

  test('invalid credentials stop immediately', () async {
    final fake = FakeAdapter(
      (_) => FakeResponse.json({
        'responseStatus': {'type': 'INVALID_USERNAME_PASSWORD'},
      }),
    );
    await expectLater(
      authWith(fake).login('a', 'b', promptMfa: noMfa),
      throwsA(isA<GarminInvalidCredentials>()),
    );
    expect(fake.requests, hasLength(1));
  });

  test('rate limiting on every strategy is reported as such', () async {
    final fake = FakeAdapter(
      (_) => FakeResponse.text('Too Many Requests', status: 429),
    );
    await expectLater(
      authWith(fake).login('a', 'b', promptMfa: noMfa),
      throwsA(isA<GarminRateLimited>()),
    );
  });

  test('falls back to the SSO widget flow with CSRF and cookies', () async {
    final fake = FakeAdapter(
      (o) => switch (route(o)) {
        'POST sso.garmin.com/mobile/api/login' => FakeResponse.text(
          '<title>Just a moment...</title>',
          status: 403,
        ),
        'GET sso.garmin.com/sso/embed' => FakeResponse.text(
          '<html>embed</html>',
          headers: {
            'set-cookie': ['GARMIN-SSO=1; Path=/', '__cf_bm=cf; Path=/'],
          },
        ),
        'GET sso.garmin.com/sso/signin' => FakeResponse.text(
          '<title>GARMIN Authentication Application</title>'
          '<input type="hidden" name="_csrf" value="csrf-1"/>',
        ),
        'POST sso.garmin.com/sso/signin' => FakeResponse.text(
          '<title>Success</title><script>var u = "https://sso.garmin.com/sso/embed?ticket=ST-widget-1";</script>',
        ),
        'POST diauth.garmin.com/di-oauth2-service/oauth/token' => diTokens(),
        _ => FakeResponse.text('', status: 404),
      },
    );

    final tokens = await authWith(fake).login('a@b.c', 'pw', promptMfa: noMfa);

    expect(tokens.accessToken, 'di-access');
    final post = fake.requests.firstWhere(
      (r) => route(r) == 'POST sso.garmin.com/sso/signin',
    );
    expect(post.data, containsPair('_csrf', 'csrf-1'));
    expect(post.data, containsPair('embed', 'true'));
    expect(post.headers['Cookie'], 'GARMIN-SSO=1; __cf_bm=cf');
    final exchange = fake.requests.last;
    expect(exchange.data, containsPair('service_ticket', 'ST-widget-1'));
    expect(
      exchange.data,
      containsPair('service_url', 'https://sso.garmin.com/sso/embed'),
    );
  });

  test('falls back to legacy OAuth1 exchange when DI exchange fails', () async {
    final fake = FakeAdapter(
      (o) => switch (route(o)) {
        'POST sso.garmin.com/mobile/api/login' => FakeResponse.json({
          'responseStatus': {'type': 'SUCCESSFUL'},
          'serviceTicketId': 'ST-1',
        }),
        'POST diauth.garmin.com/di-oauth2-service/oauth/token' =>
          FakeResponse.json({'error': 'invalid_client'}, status: 400),
        'GET connectapi.garmin.com/oauth-service/oauth/preauthorized' =>
          FakeResponse.text(
            'oauth_token=o1&oauth_token_secret=s1&mfa_token=m1',
            contentType: 'text/plain',
          ),
        'POST connectapi.garmin.com/oauth-service/oauth/exchange/user/2.0' =>
          FakeResponse.json({
            'access_token': 'legacy-access',
            'refresh_token': 'legacy-refresh',
            'expires_in': 100,
          }),
        _ => FakeResponse.text('', status: 404),
      },
    );

    final tokens = await authWith(fake).login('a', 'b', promptMfa: noMfa);

    expect(tokens.accessToken, 'legacy-access');
    expect(tokens.clientId, isNull);
    expect(
      (tokens.oauth1Token, tokens.oauth1Secret, tokens.mfaToken),
      ('o1', 's1', 'm1'),
    );
    final preauth = fake.requests.firstWhere(
      (r) => r.uri.path.endsWith('preauthorized'),
    );
    expect(preauth.uri.queryParameters['ticket'], 'ST-1');
    expect(
      preauth.headers['Authorization'],
      contains('oauth_consumer_key="ck"'),
    );
    final exchange = fake.requests.last;
    expect(exchange.headers['Authorization'], contains('oauth_token="o1"'));
    expect(exchange.data, containsPair('mfa_token', 'm1'));
  });

  group('refresh', () {
    test(
      'DI refresh keeps OAuth1 credentials and reads expiry from JWT',
      () async {
        final exp = now.add(const Duration(hours: 2));
        final jwt = fakeJwt({
          'exp': exp.millisecondsSinceEpoch ~/ 1000,
          'client_id': 'CID2',
        });
        final fake = FakeAdapter(
          (o) => FakeResponse.json({'access_token': jwt}),
        );
        final old = GarminTokens(
          accessToken: 'old',
          refreshToken: 'r1',
          clientId: 'CID',
          expiresAt: now,
          oauth1Token: 'o1',
          oauth1Secret: 's1',
        );

        final fresh = await authWith(fake).refresh(old);

        expect(fresh.accessToken, jwt);
        expect(fresh.refreshToken, 'r1');
        expect(fresh.clientId, 'CID2');
        expect(fresh.expiresAt, exp);
        expect(fresh.oauth1Token, 'o1');
        expect(fake.requests.single.data, {
          'grant_type': 'refresh_token',
          'client_id': 'CID',
          'refresh_token': 'r1',
        });
      },
    );

    test('legacy tokens are refreshed by re-exchanging OAuth1', () async {
      final fake = FakeAdapter(
        (o) => FakeResponse.json({'access_token': 'a2', 'expires_in': 60}),
      );
      final fresh = await authWith(fake).refresh(
        GarminTokens(
          accessToken: 'a1',
          expiresAt: now,
          oauth1Token: 'o1',
          oauth1Secret: 's1',
        ),
      );
      expect(fresh.accessToken, 'a2');
      expect(
        route(fake.requests.single),
        'POST connectapi.garmin.com/oauth-service/oauth/exchange/user/2.0',
      );
    });

    test('rejected refresh without OAuth1 requires a new login', () async {
      final fake = FakeAdapter(
        (o) => FakeResponse.json({'error': 'invalid_grant'}, status: 400),
      );
      await expectLater(
        authWith(fake).refresh(
          GarminTokens(
            accessToken: 'a',
            refreshToken: 'r',
            clientId: 'c',
            expiresAt: now,
          ),
        ),
        throwsA(isA<GarminNotConnected>()),
      );
    });
  });
}
