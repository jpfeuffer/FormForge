sealed class GarminException implements Exception {
  const GarminException(this.message);

  /// User-facing description; never contains tokens or credentials.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class GarminInvalidCredentials extends GarminException {
  const GarminInvalidCredentials([
    super.message = 'Invalid Garmin email or password.',
  ]);
}

final class GarminMfaRequired extends GarminException {
  const GarminMfaRequired([
    super.message = 'Garmin requires a verification code to sign in.',
  ]);
}

final class GarminMfaFailed extends GarminException {
  const GarminMfaFailed([
    super.message = 'The verification code was rejected by Garmin.',
  ]);
}

final class GarminRateLimited extends GarminException {
  const GarminRateLimited([
    super.message =
        'Garmin is rate limiting requests from this network. '
        'Wait a while before trying again.',
  ]);
}

/// Cloudflare challenge, CAPTCHA or other bot protection.
final class GarminBlocked extends GarminException {
  const GarminBlocked([
    super.message =
        'Garmin blocked the sign-in (bot protection). '
        'Try again later or from another network.',
  ]);
}

final class GarminUnexpectedResponse extends GarminException {
  const GarminUnexpectedResponse(String detail)
    : super('Unexpected response from Garmin: $detail');
}

/// No usable tokens: the user has to log in (again).
final class GarminNotConnected extends GarminException {
  const GarminNotConnected([
    super.message = 'Not connected to Garmin. Please log in.',
  ]);
}

final class GarminNetworkError extends GarminException {
  const GarminNetworkError(String detail)
    : super('Could not reach Garmin ($detail).');
}

final class GarminApiException extends GarminException {
  const GarminApiException(this.statusCode, String path)
    : super('Garmin API error $statusCode on $path.');
  final int statusCode;
}
