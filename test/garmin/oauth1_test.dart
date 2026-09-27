import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/integrations/garmin/oauth1.dart';

void main() {
  test('percent encoding follows RFC 5849 §3.6', () {
    expect(
      oauthPercentEncode('Ladies + Gentlemen'),
      'Ladies%20%2B%20Gentlemen',
    );
    expect(
      oauthPercentEncode('An encoded string!'),
      'An%20encoded%20string%21',
    );
    expect(oauthPercentEncode('-._~azAZ09'), '-._~azAZ09');
    expect(oauthPercentEncode('☃'), '%E2%98%83');
  });

  test('base string matches RFC 5849 §3.4.1.1 example', () {
    final uri = Uri.parse(
      'http://example.com/request?b5=%3D%253D&a3=a&c%40=&a2=r%20b',
    );
    final params = <(String, String)>[
      for (final e in uri.queryParametersAll.entries)
        for (final v in e.value) (e.key, v),
      ('c2', ''),
      ('a3', '2 q'),
      ('oauth_consumer_key', '9djdj82h48djs9d2'),
      ('oauth_token', 'kkk9d7dh3k39sjv7'),
      ('oauth_signature_method', 'HMAC-SHA1'),
      ('oauth_timestamp', '137131201'),
      ('oauth_nonce', '7d8f3e4a'),
    ];
    expect(
      OAuth1.baseString('POST', uri, params),
      'POST&http%3A%2F%2Fexample.com%2Frequest&a2%3Dr%2520b%26a3%3D2%2520q'
      '%26a3%3Da%26b5%3D%253D%25253D%26c%2540%3D%26c2%3D%26oauth_consumer_'
      'key%3D9djdj82h48djs9d2%26oauth_nonce%3D7d8f3e4a%26oauth_signature_m'
      'ethod%3DHMAC-SHA1%26oauth_timestamp%3D137131201%26oauth_token%3Dkkk'
      '9d7dh3k39sjv7',
    );
  });

  test('base string URI normalization', () {
    expect(
      OAuth1.baseStringUri(Uri.parse('HTTP://EXAMPLE.COM:80/r%20v/X?id=123')),
      'http://example.com/r%20v/X',
    );
    expect(
      OAuth1.baseStringUri(Uri.parse('https://www.example.net:8080/?q=1')),
      'https://www.example.net:8080/',
    );
  });

  // docs.x.com "Creating a signature".
  test('HMAC-SHA1 header matches X (Twitter) documented example', () {
    final header = OAuth1.authorizationHeader(
      method: 'POST',
      uri: Uri.parse(
        'https://api.x.com/1.1/statuses/update.json?include_entities=true',
      ),
      credentials: const OAuth1Credentials(
        consumerKey: 'xvz1evFS4wEEPTGEFPHBog',
        consumerSecret: 'kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw',
        token: '370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb',
        tokenSecret: 'LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE',
      ),
      bodyParams: {
        'status': 'Hello Ladies + Gentlemen, a signed OAuth request!',
      },
      nonce: 'kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg',
      timestamp: 1318622958,
    );
    expect(header, startsWith('OAuth '));
    expect(
      header,
      contains('oauth_signature="Ls93hJiZbQ3akF3HF3x1Bz8%2FzU4%3D"'),
    );
    expect(header, contains('oauth_version="1.0"'));
  });

  test('HMAC-SHA1 matches RFC 5849 §1.2 photo request', () {
    final header = OAuth1.authorizationHeader(
      method: 'GET',
      uri: Uri.parse(
        'http://photos.example.net/photos?file=vacation.jpg&size=original',
      ),
      credentials: const OAuth1Credentials(
        consumerKey: 'dpf43f3p2l4k3l03',
        consumerSecret: 'kd94hf93k423kf44',
        token: 'nnch734d00sl2jdk',
        tokenSecret: 'pfkkdhi9sl3r4s00',
      ),
      nonce: 'chapoH',
      timestamp: 137131202,
      includeVersion: false,
    );
    expect(
      header,
      contains('oauth_signature="MdpQcU8iPSUjWoN%2FUDMsK2sui9I%3D"'),
    );
  });

  test('credentials never print secrets', () {
    expect(
      const OAuth1Credentials(
        consumerKey: 'k',
        consumerSecret: 's3cr3t',
      ).toString(),
      isNot(contains('s3cr3t')),
    );
  });
}
