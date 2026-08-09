import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/performance_api.g.dart',
    swiftOut: 'ios/Runner/Performance/Performance.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: false),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
@HostApi()
abstract class PerformanceApi {
  void timelineInteractive();
}
