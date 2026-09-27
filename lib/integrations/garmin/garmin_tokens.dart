import 'dart:convert';

import '../../data/secrets.dart';

class GarminTokens {
  const GarminTokens({
    required this.accessToken,
    required this.expiresAt,
    this.refreshToken,
    this.clientId,
    this.oauth1Token,
    this.oauth1Secret,
    this.mfaToken,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;

  /// DI OAuth2 client id. Null for legacy garth-style tokens, which are
  /// refreshed by re-exchanging the OAuth1 token.
  final String? clientId;

  final String? oauth1Token;
  final String? oauth1Secret;
  final String? mfaToken;

  bool get hasOAuth1 => oauth1Token != null && oauth1Secret != null;

  bool get hasDiRefresh => clientId != null && refreshToken != null;

  bool expiresWithin(Duration margin, DateTime now) =>
      !now.add(margin).isBefore(expiresAt);

  /// Copies OAuth1 credentials from [previous] when this token set has none.
  GarminTokens inheritOAuth1(GarminTokens previous) => hasOAuth1
      ? this
      : GarminTokens(
          accessToken: accessToken,
          expiresAt: expiresAt,
          refreshToken: refreshToken,
          clientId: clientId,
          oauth1Token: previous.oauth1Token,
          oauth1Secret: previous.oauth1Secret,
          mfaToken: previous.mfaToken,
        );

  Map<String, Object?>? oauth1Json() => hasOAuth1
      ? {'token': oauth1Token, 'secret': oauth1Secret, 'mfaToken': mfaToken}
      : null;

  Map<String, Object?> oauth2Json() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'clientId': clientId,
  };

  Map<String, Object?> toJson() => {
    'oauth1': oauth1Json(),
    'oauth2': oauth2Json(),
  };

  factory GarminTokens.fromJson(Map<String, Object?> json) {
    final o2 = json['oauth2'] as Map<String, Object?>;
    final o1 = json['oauth1'] as Map<String, Object?>?;
    return GarminTokens(
      accessToken: o2['accessToken'] as String,
      refreshToken: o2['refreshToken'] as String?,
      expiresAt: DateTime.parse(o2['expiresAt'] as String),
      clientId: o2['clientId'] as String?,
      oauth1Token: o1?['token'] as String?,
      oauth1Secret: o1?['secret'] as String?,
      mfaToken: o1?['mfaToken'] as String?,
    );
  }

  @override
  String toString() => 'GarminTokens(expiresAt: $expiresAt)';
}

abstract interface class GarminTokenStore {
  Future<GarminTokens?> read();
  Future<void> write(GarminTokens t);
  Future<void> clear();
}

/// Persists tokens in the OS keystore via [Secrets].
class SecretsGarminTokenStore implements GarminTokenStore {
  SecretsGarminTokenStore(this._secrets);
  final Secrets _secrets;

  @override
  Future<GarminTokens?> read() async {
    final o2 = await _secrets.read(Secrets.garminOauth2);
    if (o2 == null) return null;
    final o1 = await _secrets.read(Secrets.garminOauth1);
    try {
      return GarminTokens.fromJson({
        'oauth2': jsonDecode(o2),
        'oauth1': o1 == null ? null : jsonDecode(o1),
      });
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(GarminTokens t) async {
    final o1 = t.oauth1Json();
    await _secrets.write(
      Secrets.garminOauth1,
      o1 == null ? null : jsonEncode(o1),
    );
    await _secrets.write(Secrets.garminOauth2, jsonEncode(t.oauth2Json()));
  }

  @override
  Future<void> clear() async {
    await _secrets.write(Secrets.garminOauth2, null);
    await _secrets.write(Secrets.garminOauth1, null);
  }
}

class InMemoryGarminTokenStore implements GarminTokenStore {
  InMemoryGarminTokenStore([this.tokens]);
  GarminTokens? tokens;

  @override
  Future<GarminTokens?> read() async => tokens;

  @override
  Future<void> write(GarminTokens t) async => tokens = t;

  @override
  Future<void> clear() async => tokens = null;
}
