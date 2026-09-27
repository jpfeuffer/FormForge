import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/integrations/garmin/sso_html.dart';

void main() {
  const signinPage = '''
<!DOCTYPE html><html><head><title>GARMIN Authentication Application</title></head>
<body><form method="post">
  <input type="hidden" name="_csrf" value="3F2A-csrf-token-XYZ" />
</form></body></html>''';

  const successPage = '''
<html><head><title>Success</title>
<script type="text/javascript">
  var redirectAfterAccountLoginUrl = "https://sso.garmin.com/sso/embed";
  var response_url = "https:\\/\\/sso.garmin.com\\/sso\\/embed?ticket=ST-0123456-AbCdEfGhIjKl-cas";
</script></head><body></body></html>''';

  const mfaPage = '''
<html><head><title>GARMIN Authentication Application</title>
<script>
  var customerGuid = "guid-1";
  var mfaMethod = "email";
  var codeSentTo = "";
  var clientId = "GarminConnect";
</script></head>
<input type="hidden" name="_csrf" value="mfa-csrf"/></html>''';

  test('extracts CSRF token', () {
    expect(SsoHtml.csrf(signinPage), '3F2A-csrf-token-XYZ');
    expect(SsoHtml.csrf('<html></html>'), isNull);
  });

  test('extracts page title', () {
    expect(SsoHtml.title(successPage), 'Success');
    expect(SsoHtml.title('<p>no title</p>'), '');
  });

  test('extracts service ticket from success page', () {
    expect(SsoHtml.ticket(successPage), 'ST-0123456-AbCdEfGhIjKl-cas');
    expect(SsoHtml.ticket(signinPage), isNull);
  });

  test('extracts MFA page variables', () {
    expect(SsoHtml.mfaVars(mfaPage), {
      'customerGuid': 'guid-1',
      'mfaMethod': 'email',
      'codeSentTo': '',
      'clientId': 'GarminConnect',
    });
    expect(SsoHtml.csrf(mfaPage), 'mfa-csrf');
  });
}
