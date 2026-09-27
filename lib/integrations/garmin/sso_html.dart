/// Parsers for the HTML pages of the SSO embed widget flow.
abstract final class SsoHtml {
  static final _csrf = RegExp(r'name="_csrf"\s+value="(.+?)"');
  static final _title = RegExp(r'<title>(.+?)</title>', dotAll: true);
  static final _ticket = RegExp(r'[?&]ticket=(ST-[^"&\s<]+)');
  static final _mfaVars = RegExp(
    r'var\s+(customerGuid|mfaMethod|locale|clientId|codeSentTo)\s*=\s*"([^"]*)"\s*;',
  );

  static String? csrf(String html) => _csrf.firstMatch(html)?.group(1);

  static String title(String html) =>
      _title.firstMatch(html)?.group(1)?.trim() ?? '';

  static String? ticket(String html) => _ticket.firstMatch(html)?.group(1);

  static Map<String, String> mfaVars(String html) => {
    for (final m in _mfaVars.allMatches(html)) m.group(1)!: m.group(2)!,
  };
}
