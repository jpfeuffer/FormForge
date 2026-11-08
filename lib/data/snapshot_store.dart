import 'shared_file.dart';
import 'snapshot.dart';

class RemoteSnapshot {
  const RemoteSnapshot(this.snapshot, this.version);
  final Snapshot snapshot;
  final String version;
}

abstract class SnapshotStore {
  String get stateFileName;
  String get uploadMessage;
  Future<RemoteSnapshot?> read(String target);
  Future<void> write(
    String target,
    Snapshot snapshot,
    RemoteSnapshot? expected,
  );
}

class FileSnapshotStore implements SnapshotStore {
  @override
  String get stateFileName => 'shared-file.json';
  @override
  String get uploadMessage =>
      'Shared file updated. Cloud upload timing is controlled by your provider.';

  @override
  Future<RemoteSnapshot> read(String target) async {
    final snapshot = await Snapshot.decode(await SharedFile.read(target));
    return RemoteSnapshot(snapshot, snapshot.revision);
  }

  @override
  Future<void> write(
    String target,
    Snapshot snapshot,
    RemoteSnapshot? expected,
  ) => SharedFile.write(target, snapshot.encode());
}
