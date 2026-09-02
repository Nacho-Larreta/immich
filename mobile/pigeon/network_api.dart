import 'package:pigeon/pigeon.dart';

class ClientCertData {
  Uint8List data;
  String password;

  ClientCertData(this.data, this.password);
}

class ClientCertPrompt {
  String title;
  String message;
  String cancel;
  String confirm;

  ClientCertPrompt(this.title, this.message, this.cancel, this.confirm);
}

enum NetworkEndpointSchemePolicy { httpsOnly, explicitlyApprovedHttp, registeredLocalHttp }

enum NetworkTransportRetirementStatus { retired, temporarilyUnproven, unsupported }

class NetworkTransportIdentitySnapshot {
  String incarnation;
  int generation;
  bool confirmed;

  NetworkTransportIdentitySnapshot(this.incarnation, this.generation, this.confirmed);
}

class NetworkTransportClaimDescriptor {
  String? incarnation;
  int generation;

  NetworkTransportClaimDescriptor(this.incarnation, this.generation);
}

class NetworkRequestContextSnapshot {
  int clientPointer;
  String? apiEndpoint;
  String? canonicalOrigin;
  NetworkEndpointSchemePolicy? schemePolicy;
  int sessionEpoch;
  int generation;
  String transportIncarnation;
  bool confirmed;

  NetworkRequestContextSnapshot(
    this.clientPointer,
    this.apiEndpoint,
    this.canonicalOrigin,
    this.schemePolicy,
    this.sessionEpoch,
    this.generation,
    this.transportIncarnation,
    this.confirmed,
  );
}

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/network_api.g.dart',
    swiftOut: 'ios/Runner/Core/Network.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: false),
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/core/Network.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.core', includeErrorClass: true),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
@HostApi()
abstract class NetworkApi {
  @async
  void addCertificate(ClientCertData clientData);

  @async
  void selectCertificate(ClientCertPrompt promptText);

  @async
  void removeCertificate();

  bool hasCertificate();

  int getClientPointer();

  NetworkRequestContextSnapshot getRequestContextSnapshot();

  NetworkTransportIdentitySnapshot getForegroundTransportIdentity();

  NetworkRequestContextSnapshot? getRequestContextSnapshotForIdentity(String incarnation, int generation);

  NetworkTransportRetirementStatus retireForegroundTransports(List<NetworkTransportClaimDescriptor> claims);

  void setRequestHeaders(Map<String, String> headers, List<String> serverUrls, String? token);

  void replaceRequestContext(
    Map<String, String> headers,
    String? apiEndpoint,
    String? canonicalOrigin,
    NetworkEndpointSchemePolicy? schemePolicy,
    String? token,
    int sessionEpoch,
  );

  void failClosedRequestContext();
}
