/// Hosts, client ids and headers mirrored from python-garminconnect 0.3.16
/// (Sep 2026), which tracks the Garmin Connect mobile app.
abstract final class GarminEndpoints {
  static const sso = 'https://sso.garmin.com';
  static const connectApi = 'https://connectapi.garmin.com';
  static const diToken =
      'https://diauth.garmin.com/di-oauth2-service/oauth/token';
  static const diGrantType =
      'https://connectapi.garmin.com/di-oauth2-service/oauth/grant/service_ticket';
  static const diClientIds = [
    'GARMIN_CONNECT_MOBILE_ANDROID_DI_2025Q2',
    'GARMIN_CONNECT_MOBILE_ANDROID_DI_2024Q4',
    'GARMIN_CONNECT_MOBILE_ANDROID_DI',
    'GARMIN_CONNECT_MOBILE_IOS_DI',
  ];

  static const iosClientId = 'GCM_IOS_DARK';
  static const iosServiceUrl = 'https://mobile.integration.garmin.com/gcm/ios';
  static const ssoEmbed = '$sso/sso/embed';

  /// Legacy garth OAuth1 consumer (key/secret of the Android app).
  static const oauthConsumerUrl =
      'https://thegarth.s3.amazonaws.com/oauth_consumer.json';
  static const oauthService = '$connectApi/oauth-service/oauth';
  static const oauthUserAgent = 'com.garmin.android.apps.connectmobile';

  static const iosLoginUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';
  static const desktopUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const nativeHeaders = {
    'User-Agent': 'GCM-Android-5.23',
    'X-Garmin-User-Agent':
        'com.garmin.android.apps.connectmobile/5.23; ; Google/sdk_gphone64_arm64/google; '
        'Android/33; Dalvik/2.1.0',
    'X-Garmin-Paired-App-Version': '10861',
    'X-Garmin-Client-Platform': 'Android',
    'X-App-Ver': '10861',
    'X-Lang': 'en',
    'X-GCExperience': 'GC5',
    'Accept-Language': 'en-US,en;q=0.9',
  };
}
