import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/io_client.dart';
import 'package:immich_mobile/infrastructure/http/canonical_origin_client.dart';

void main() {
  test('a native client never follows 301, 302, 307, or 308 to a second origin', () async {
    var targetRequestCount = 0;
    var sourceRequestCount = 0;
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final targetSubscription = target.listen((request) async {
      targetRequestCount++;
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
    });
    final sourceSubscription = source.listen((request) async {
      sourceRequestCount++;
      final status = int.parse(request.uri.pathSegments.last);
      request.response
        ..statusCode = status
        ..headers.set(HttpHeaders.locationHeader, 'http://${target.address.address}:${target.port}/stolen');
      await request.response.close();
    });
    final nativeClient = IOClient(HttpClient());
    final sourceOrigin = Uri.parse('http://${source.address.address}:${source.port}');
    final client = CanonicalOriginClient(nativeClient, () => RequestOriginContext.restricted([sourceOrigin]));

    try {
      for (final status in [301, 302, 307, 308]) {
        final request = Request('GET', sourceOrigin.replace(path: '/redirect/$status'))
          ..headers.addAll({
            HttpHeaders.authorizationHeader: 'Bearer secret',
            HttpHeaders.cookieHeader: 'immich_access_token=secret',
            'X-Custom-Auth': 'secret',
          });
        final response = await client.send(request);
        await response.stream.drain<void>();
        expect(response.statusCode, status);
      }

      expect(sourceRequestCount, 4);
      expect(targetRequestCount, 0);
    } finally {
      nativeClient.close();
      await sourceSubscription.cancel();
      await targetSubscription.cancel();
      await source.close(force: true);
      await target.close(force: true);
    }
  });
}
