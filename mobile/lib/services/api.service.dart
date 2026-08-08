import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/models/auth/auxilary_endpoint.model.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:immich_mobile/utils/url_helper.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';

class ApiService {
  late ApiServiceGraph _graph;
  final Client? _clientOverride;

  ApiService({Client? client, String? initialEndpoint}) : _clientOverride = client {
    final endpoint = initialEndpoint ?? Store.tryGet(StoreKey.serverEndpoint) ?? '';
    setEndpoint(endpoint);
  }
  final _log = Logger("ApiService");

  Future<void> updateHeaders() async {
    await NetworkRepository.setHeaders(getRequestHeaders(), getServerUrls());
    apiClient.client = NetworkRepository.client;
  }

  void setEndpoint(String endpoint) {
    installGraph(prepareGraph(endpoint));
  }

  ApiServiceGraph prepareGraph(String endpoint) =>
      ApiServiceGraph(endpoint, _clientOverride ?? NetworkRepository.client);

  void installGraph(ApiServiceGraph graph) {
    graph.apiClient.client = _clientOverride ?? NetworkRepository.client;
    _graph = graph;
  }

  Future<String> resolveAndSetEndpoint(String serverUrl) async {
    final endpoint = await resolveEndpoint(serverUrl);
    setEndpoint(endpoint);

    // Save in local database for next startup
    await Store.put(StoreKey.serverEndpoint, endpoint);
    return endpoint;
  }

  /// Takes a server URL and attempts to resolve the API endpoint.
  ///
  /// Input: [schema://]host[:port][/path]
  ///  schema - optional (default: https)
  ///  host   - required
  ///  port   - optional (default: based on schema)
  ///  path   - optional
  Future<String> resolveEndpoint(String serverUrl) async {
    String url = sanitizeUrl(serverUrl);

    // Check for /.well-known/immich
    final wellKnownEndpoint = await _getWellKnownEndpoint(url);
    if (wellKnownEndpoint.isNotEmpty) {
      url = sanitizeUrl(wellKnownEndpoint);
    }

    if (!await _isEndpointAvailable(url)) {
      throw ApiException(503, "Server is not reachable");
    }

    // Otherwise, assume the URL provided is the api endpoint
    return url;
  }

  Future<bool> _isEndpointAvailable(String serverUrl) async {
    if (!serverUrl.endsWith('/api')) {
      serverUrl += '/api';
    }

    try {
      setEndpoint(serverUrl);
      await serverInfoApi.pingServer().timeout(const Duration(seconds: 5));
    } on TimeoutException catch (_) {
      return false;
    } on SocketException catch (_) {
      return false;
    } catch (error, stackTrace) {
      _log.severe("Error while checking server availability", error, stackTrace);
      return false;
    }
    return true;
  }

  Future<String> _getWellKnownEndpoint(String baseUrl) async {
    try {
      final res = await NetworkRepository.client
          .get(Uri.parse("$baseUrl/.well-known/immich"))
          .timeout(const Duration(seconds: 5));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final endpoint = data['api']['endpoint'].toString();

        if (endpoint.startsWith('/')) {
          // Full URL is relative to base
          return "$baseUrl$endpoint";
        }
        return endpoint;
      }
    } catch (e) {
      dPrint(() => "Could not locate /.well-known/immich at $baseUrl");
    }

    return "";
  }

  Future<void> setDeviceInfoHeader() async {
    DeviceInfoPlugin deviceInfoPlugin = DeviceInfoPlugin();

    if (Platform.isIOS) {
      final iosInfo = await deviceInfoPlugin.iosInfo;
      authenticationApi.apiClient.addDefaultHeader('deviceModel', iosInfo.utsname.machine);
      authenticationApi.apiClient.addDefaultHeader('deviceType', 'iOS');
    } else if (Platform.isAndroid) {
      final androidInfo = await deviceInfoPlugin.androidInfo;
      authenticationApi.apiClient.addDefaultHeader('deviceModel', androidInfo.model);
      authenticationApi.apiClient.addDefaultHeader('deviceType', 'Android');
    } else {
      authenticationApi.apiClient.addDefaultHeader('deviceModel', 'Unknown');
      authenticationApi.apiClient.addDefaultHeader('deviceType', 'Unknown');
    }
  }

  static List<String> getServerUrls() {
    final urls = <String>[];
    final serverEndpoint = Store.tryGet(StoreKey.serverEndpoint);
    if (serverEndpoint != null && serverEndpoint.isNotEmpty) {
      urls.add(serverEndpoint);
    }
    final localEndpoint = Store.tryGet(StoreKey.localEndpoint);
    if (localEndpoint != null && localEndpoint.isNotEmpty) {
      urls.add(localEndpoint);
    }
    final externalJson = Store.tryGet(StoreKey.externalEndpointList);
    if (externalJson != null) {
      final List<dynamic> list = jsonDecode(externalJson);
      for (final entry in list) {
        final url = AuxilaryEndpoint.fromJson(entry).url;
        if (url.isNotEmpty) urls.add(url);
      }
    }
    return urls;
  }

  static Map<String, String> getRequestHeaders() {
    var customHeadersStr = Store.get(StoreKey.customHeaders, "");
    if (customHeadersStr.isEmpty) {
      return const {};
    }

    return (jsonDecode(customHeadersStr) as Map).cast<String, String>();
  }

  ApiClient get apiClient => _graph.apiClient;
  UsersApi get usersApi => _graph.usersApi;
  AuthenticationApi get authenticationApi => _graph.authenticationApi;
  AuthenticationApi get oAuthApi => _graph.oAuthApi;
  AlbumsApi get albumsApi => _graph.albumsApi;
  AssetsApi get assetsApi => _graph.assetsApi;
  SearchApi get searchApi => _graph.searchApi;
  ServerApi get serverInfoApi => _graph.serverInfoApi;
  MapApi get mapApi => _graph.mapApi;
  PartnersApi get partnersApi => _graph.partnersApi;
  PeopleApi get peopleApi => _graph.peopleApi;
  SharedLinksApi get sharedLinksApi => _graph.sharedLinksApi;
  SyncApi get syncApi => _graph.syncApi;
  SystemConfigApi get systemConfigApi => _graph.systemConfigApi;
  ActivitiesApi get activitiesApi => _graph.activitiesApi;
  DownloadApi get downloadApi => _graph.downloadApi;
  TrashApi get trashApi => _graph.trashApi;
  StacksApi get stacksApi => _graph.stacksApi;
  ViewsApi get viewApi => _graph.viewApi;
  MemoriesApi get memoriesApi => _graph.memoriesApi;
  SessionsApi get sessionsApi => _graph.sessionsApi;
  TagsApi get tagsApi => _graph.tagsApi;
}

final class ApiServiceGraph {
  ApiServiceGraph(String endpoint, Client client) : apiClient = ApiClient(basePath: endpoint) {
    apiClient.client = client;
    usersApi = UsersApi(apiClient);
    authenticationApi = AuthenticationApi(apiClient);
    oAuthApi = AuthenticationApi(apiClient);
    albumsApi = AlbumsApi(apiClient);
    assetsApi = AssetsApi(apiClient);
    searchApi = SearchApi(apiClient);
    serverInfoApi = ServerApi(apiClient);
    mapApi = MapApi(apiClient);
    partnersApi = PartnersApi(apiClient);
    peopleApi = PeopleApi(apiClient);
    sharedLinksApi = SharedLinksApi(apiClient);
    syncApi = SyncApi(apiClient);
    systemConfigApi = SystemConfigApi(apiClient);
    activitiesApi = ActivitiesApi(apiClient);
    downloadApi = DownloadApi(apiClient);
    trashApi = TrashApi(apiClient);
    stacksApi = StacksApi(apiClient);
    viewApi = ViewsApi(apiClient);
    memoriesApi = MemoriesApi(apiClient);
    sessionsApi = SessionsApi(apiClient);
    tagsApi = TagsApi(apiClient);
  }

  final ApiClient apiClient;
  late final UsersApi usersApi;
  late final AuthenticationApi authenticationApi;
  late final AuthenticationApi oAuthApi;
  late final AlbumsApi albumsApi;
  late final AssetsApi assetsApi;
  late final SearchApi searchApi;
  late final ServerApi serverInfoApi;
  late final MapApi mapApi;
  late final PartnersApi partnersApi;
  late final PeopleApi peopleApi;
  late final SharedLinksApi sharedLinksApi;
  late final SyncApi syncApi;
  late final SystemConfigApi systemConfigApi;
  late final ActivitiesApi activitiesApi;
  late final DownloadApi downloadApi;
  late final TrashApi trashApi;
  late final StacksApi stacksApi;
  late final ViewsApi viewApi;
  late final MemoriesApi memoriesApi;
  late final SessionsApi sessionsApi;
  late final TagsApi tagsApi;
}
