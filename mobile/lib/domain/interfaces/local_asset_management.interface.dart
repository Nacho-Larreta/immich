abstract interface class LocalAssetManagementPort {
  Future<List<String>> deleteAll(List<String> assetIds);

  Future<String?> getOriginalFilename(String assetId);
}
