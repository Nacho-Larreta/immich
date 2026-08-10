import 'package:collection/collection.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/models/activities/activity.model.dart';
import 'package:immich_mobile/domain/models/album/remote_album_scope.model.dart';
import 'package:immich_mobile/providers/activity_service.provider.dart';

// ignore: unintended_html_in_doc_comment
/// Maintains the current list of all activities for <share-album-id, asset>

final albumActivityProvider = AsyncNotifierProvider.autoDispose
    .family<AlbumActivity, List<Activity>, RemoteAlbumActivityScope>(AlbumActivity.new);

class AlbumActivity extends AutoDisposeFamilyAsyncNotifier<List<Activity>, RemoteAlbumActivityScope> {
  late RemoteAlbumActivityScope scope;

  @override
  Future<List<Activity>> build(RemoteAlbumActivityScope args) async {
    scope = args;
    return ref.watch(activityServiceProvider).getAllActivities(scope.albumId, assetId: scope.assetId);
  }

  Future<void> removeActivity(String id) async {
    if (await ref.watch(activityServiceProvider).removeActivity(id)) {
      final removedActivity = _removeFromState(id);
      if (removedActivity == null) {
        return;
      }

      if (scope.assetId != null) {
        ref.read(albumActivityProvider(RemoteAlbumActivityScope(album: scope.album)).notifier)._removeFromState(id);
      }
    }
  }

  Future<void> addLike() async {
    final activity = await ref
        .watch(activityServiceProvider)
        .addActivity(scope.albumId, ActivityType.like, assetId: scope.assetId);
    if (activity.hasValue) {
      _addToState(activity.requireValue);
      if (scope.assetId != null) {
        ref
            .read(albumActivityProvider(RemoteAlbumActivityScope(album: scope.album)).notifier)
            ._addToState(activity.requireValue);
      }
    }
  }

  Future<void> addComment(String comment) async {
    final activity = await ref
        .watch(activityServiceProvider)
        .addActivity(scope.albumId, ActivityType.comment, assetId: scope.assetId, comment: comment);

    if (activity.hasValue) {
      _addToState(activity.requireValue);
      if (scope.assetId != null) {
        ref
            .read(albumActivityProvider(RemoteAlbumActivityScope(album: scope.album)).notifier)
            ._addToState(activity.requireValue);
      }
    }
  }

  void _addToState(Activity activity) {
    final activities = state.valueOrNull ?? [];
    if (activities.any((a) => a.id == activity.id)) {
      return;
    }
    state = AsyncData([...activities, activity]);
  }

  Activity? _removeFromState(String id) {
    final activities = state.valueOrNull;
    if (activities == null) {
      return null;
    }
    final activity = activities.firstWhereOrNull((a) => a.id == id);
    if (activity == null) {
      return null;
    }

    final updated = [...activities]..remove(activity);
    state = AsyncData(updated);
    return activity;
  }
}
