void validateHttpResource(Uri uri, String argumentName) {
  if (!_isHttpScheme(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasFragment) {
    throw ArgumentError.value(uri, argumentName, 'Must be an absolute HTTP(S) resource without user info or fragment');
  }
}

void validateHttpEndpoint(Uri uri, String argumentName) {
  validateHttpResource(uri, argumentName);
  if (uri.hasQuery) {
    throw ArgumentError.value(uri, argumentName, 'Must not contain a query');
  }
}

void validateHttpOrigin(Uri uri, String argumentName) {
  validateHttpEndpoint(uri, argumentName);
  if (uri.path.isNotEmpty) {
    throw ArgumentError.value(uri, argumentName, 'Must not contain a path');
  }
}

bool _isHttpScheme(String scheme) => scheme == 'http' || scheme == 'https';
