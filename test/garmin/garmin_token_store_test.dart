import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/secrets.dart';
import 'package:formforge/integrations/garmin/garmin_tokens.dart';

void main() {
  test(
    'SecretsGarminTokenStore splits OAuth1/OAuth2 and clears both',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final secrets = Secrets();
      final store = SecretsGarminTokenStore(secrets);
      final expiresAt = DateTime.utc(2026, 10, 1);

      expect(await store.read(), isNull);
      await store.write(
        GarminTokens(
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: expiresAt,
          oauth1Token: 'o',
          oauth1Secret: 's',
        ),
      );

      expect(await secrets.read(Secrets.garminOauth1), contains('"token":"o"'));
      expect(
        await secrets.read(Secrets.garminOauth2),
        contains('"accessToken":"a"'),
      );
      final back = await store.read();
      expect(
        (back?.accessToken, back?.expiresAt, back?.oauth1Secret),
        ('a', expiresAt, 's'),
      );

      await store.clear();
      expect(await store.read(), isNull);
      expect(await secrets.read(Secrets.garminOauth1), isNull);
    },
  );
}
