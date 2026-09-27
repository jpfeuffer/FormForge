import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class FakeResponse {
  FakeResponse(
    this.status,
    List<int> body, {
    this.contentType = 'application/json',
    this.headers = const {},
  }) : body = Uint8List.fromList(body);

  FakeResponse.json(
    Object? json, {
    int status = 200,
    Map<String, List<String>> headers = const {},
  }) : this(status, utf8.encode(jsonEncode(json)), headers: headers);

  FakeResponse.text(
    String text, {
    int status = 200,
    String contentType = 'text/html',
    Map<String, List<String>> headers = const {},
  }) : this(
         status,
         utf8.encode(text),
         contentType: contentType,
         headers: headers,
       );

  final int status;
  final Uint8List body;
  final String contentType;
  final Map<String, List<String>> headers;
}

typedef FakeHandler = FakeResponse Function(RequestOptions request);

/// Routes requests to [handler] and records them; never touches the network.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);
  final FakeHandler handler;
  final requests = <RequestOptions>[];

  Dio get dio => Dio()..httpClientAdapter = this;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final r = handler(options);
    return ResponseBody.fromBytes(
      r.body,
      r.status,
      headers: {
        Headers.contentTypeHeader: [r.contentType],
        ...r.headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String route(RequestOptions o) => '${o.method} ${o.uri.host}${o.uri.path}';

/// Unsigned JWT carrying [claims], enough for client-side claim parsing.
String fakeJwt(Map<String, Object?> claims) {
  String part(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'RS256'})}.${part(claims)}.sig';
}
