import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/data/file_sync.dart';
import 'package:formforge/data/snapshot.dart';
import 'package:formforge/integrations/google/google_auth.dart';
import 'package:formforge/integrations/google/google_drive_store.dart';

import '../garmin/fake_http.dart';

class FakeGoogleAuthorization implements GoogleAuthorization {
  FakeGoogleAuthorization([String id = 'account'])
    : account = GoogleAccount(id, 'test@example.invalid');
  @override
  GoogleAccount? account;
  final refreshes = <bool>[];
  @override
  Future<void> initialize() async {}
  @override
  Future<void> signIn() async {}
  @override
  Future<void> signOut() async => account = null;
  @override
  Future<String> accessToken({bool refresh = false}) async {
    refreshes.add(refresh);
    return refresh ? 'fresh-token' : 'initial-token';
  }
}

class FakeDrive {
  final files = <String, Snapshot>{};
  final parents = <String, List<String>>{};
  Map<String, dynamic>? pending;
  Snapshot? uploading;
  void Function(String)? afterUpload;
  int nextId = 0;
  late final adapter = FakeAdapter(handle);

  Map<String, Object?> metadata(String id) => {
    'id': id,
    'size': '${files[id]!.encode().length}',
    'createdTime': '2026-11-08T12:${nextId.toString().padLeft(2, '0')}:00Z',
    'appProperties': {
      'formforgeBackup': '1',
      'revision': files[id]!.revision,
      for (var i = 0; i < parents[id]!.length; i++) 'parent$i': parents[id]![i],
    },
  };

  void add(String id, Snapshot snapshot, [List<String> previous = const []]) {
    files[id] = snapshot;
    parents[id] = previous;
  }

  FakeResponse handle(RequestOptions request) {
    if (request.method == 'GET' && request.uri.path.endsWith('/files')) {
      expect(request.queryParameters['spaces'], 'appDataFolder');
      expect(request.queryParameters['q'], contains('formforgeBackup'));
      return FakeResponse.json({
        'files': [for (final id in files.keys) metadata(id)],
      });
    }
    if (request.method == 'GET') {
      expect(request.queryParameters['alt'], 'media');
      return FakeResponse(
        200,
        files[request.uri.pathSegments.last]!.encode(),
        contentType: 'application/octet-stream',
      );
    }
    if (request.method == 'POST') {
      expect(request.queryParameters['uploadType'], 'resumable');
      pending = Map<String, dynamic>.from(request.data as Map);
      expect(pending!['parents'], ['appDataFolder']);
      return FakeResponse.json(
        {},
        headers: {
          'location': [
            'https://www.googleapis.com/upload/drive/v3/files?upload_id=fake',
          ],
        },
      );
    }
    expect(request.method, 'PUT');
    final id = 'file${++nextId}';
    final props = Map<String, dynamic>.from(pending!['appProperties'] as Map);
    add(id, uploading!, [
      for (final entry in props.entries)
        if (entry.key.startsWith('parent')) entry.value as String,
    ]);
    expect(props['revision'], uploading!.revision);
    afterUpload?.call(id);
    return FakeResponse.json({'id': id});
  }
}

class ConsumingUploadAdapter extends FakeAdapter {
  ConsumingUploadAdapter(FakeDrive drive) : super(drive.handle);
  final uploads = <Uint8List>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'PUT') {
      final bytes = BytesBuilder();
      await for (final chunk in requestStream!) {
        bytes.add(chunk);
      }
      uploads.add(bytes.takeBytes());
      if (uploads.length == 1) {
        return ResponseBody.fromString(
          '{}',
          401,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      }
    }
    return super.fetch(options, requestStream, cancelFuture);
  }
}

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('first cloud Sync creates backup; account baseline is separate from file mode', () async {
    final dir = await Directory.systemTemp.createTemp('formforge-drive-test-');
    try {
      final fake = FakeDrive();
      final auth = FakeGoogleAuthorization();
      final store = GoogleDriveStore(auth, dio: fake.adapter.dio);
      final sync = FileSync(db, dir, store: store)..target = 'Google Drive';
      await db.setSetting('value', 'one');
      fake.uploading = await Snapshot.capture(db);
      expect(
        await sync.sync((_) async => fail('Unexpected prompt')),
        store.uploadMessage,
      );
      expect(fake.files.length, 1);
      final restart = FileSync(db, dir, store: store);
      await restart.load();
      expect(restart.baseline, sync.baseline);
      expect(
        await restart.sync((_) async => fail('Unexpected prompt')),
        'Already up to date',
      );
      final fileMode = FileSync(db, dir);
      await fileMode.load();
      expect(fileMode.baseline, isNull);
      expect(
        GoogleDriveStore(FakeGoogleAuthorization('other')).stateFileName,
        isNot(store.stateFileName),
      );
      expect(await store.read('Google Drive'), isNotNull);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test(
    'upload appends history instead of overwriting and can reuse old content',
    () async {
      final fake = FakeDrive();
      final store = GoogleDriveStore(
        FakeGoogleAuthorization(),
        dio: fake.adapter.dio,
      );
      await db.setSetting('value', 'old');
      final old = await Snapshot.capture(db);
      fake.add('old', old);
      final remote = await store.read('Google Drive');
      await db.setSetting('value', 'new');
      final newer = await Snapshot.capture(db);
      fake.uploading = newer;
      await store.write('Google Drive', newer, remote);
      expect(fake.files['old']!.revision, old.revision);
      expect(fake.parents['file1'], ['old']);
      final latest = await store.read('Google Drive');
      expect(latest!.snapshot.revision, newer.revision);
      fake.uploading = old;
      await store.write('Google Drive', old, latest);
      expect(
        (await store.read('Google Drive'))!.snapshot.revision,
        old.revision,
      );
      expect(fake.files.length, 3);
    },
  );

  test('a new device restores Google data and missing history needs an explicit reset', () async {
    final dir = await Directory.systemTemp.createTemp('formforge-drive-test-');
    try {
      final fake = FakeDrive();
      final store = GoogleDriveStore(
        FakeGoogleAuthorization(),
        dio: fake.adapter.dio,
      );
      await db.setSetting('value', 'cloud data');
      final cloud = await Snapshot.capture(db);
      fake.add('cloud', cloud);
      await db.setSetting('value', 'device data');
      final sync = FileSync(db, dir, store: store)..target = 'Google Drive';
      await sync.sync((action) async {
        expect(action, SnapshotAction.conflict);
        return SnapshotAction.restore;
      });
      expect(await db.getSetting('value'), 'cloud data');
      expect(sync.baseline, cloud.revision);
      expect(await sync.recoveryFiles(), isNotEmpty);
      fake.files.clear();
      fake.parents.clear();
      await expectLater(
        sync.sync((_) async => fail('Unexpected prompt')),
        throwsStateError,
      );
      expect(fake.adapter.requests.where((r) => r.method == 'POST'), isEmpty);
      sync.baseline = null;
      fake.uploading = await Snapshot.capture(db);
      expect(
        await sync.sync((_) async => fail('Unexpected prompt')),
        store.uploadMessage,
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('concurrent content arriving during upload fails verification without prompting', () async {
    final fake = FakeDrive();
    final store = GoogleDriveStore(
      FakeGoogleAuthorization(),
      dio: fake.adapter.dio,
    );
    final original = await Snapshot.capture(db);
    fake.add('original', original);
    final remote = await store.read('Google Drive');
    await db.setSetting('value', 'competing');
    final competing = await Snapshot.capture(db);
    await db.setSetting('value', 'uploaded');
    final uploaded = await Snapshot.capture(db);
    fake.uploading = uploaded;
    fake.afterUpload = (_) => fake.add('competing', competing, ['original']);
    store.chooseVersion = (_) async =>
        fail('Verification must not offer to ignore a competing backup');
    await expectLater(
      store.write('Google Drive', uploaded, remote),
      throwsStateError,
    );
    expect(fake.files.length, 3);
    expect(fake.files['file1']!.revision, uploaded.revision);
    expect(fake.files['competing']!.revision, competing.revision);
  });

  test('listing follows pagination and rejects repeated pages', () async {
    final fake = FakeDrive();
    final old = await Snapshot.capture(db);
    fake.add('old', old);
    await db.setSetting('value', 'new');
    final newer = await Snapshot.capture(db);
    fake.add('new', newer, ['old']);
    final paginated = FakeAdapter((request) {
      if (request.uri.path.endsWith('/files')) {
        return FakeResponse.json(
          request.queryParameters['pageToken'] == null
              ? {
                  'files': [fake.metadata('old')],
                  'nextPageToken': 'tail',
                }
              : {
                  'files': [fake.metadata('new')],
                },
        );
      }
      return fake.handle(request);
    });
    final store = GoogleDriveStore(
      FakeGoogleAuthorization(),
      dio: paginated.dio,
    );
    expect(
      (await store.read('Google Drive'))!.snapshot.revision,
      newer.revision,
    );
    expect(paginated.requests.length, 3);
    final repeated = FakeAdapter(
      (_) => FakeResponse.json({
        'files': [fake.metadata('old')],
        'nextPageToken': 'tail',
      }),
    );
    await expectLater(
      GoogleDriveStore(
        FakeGoogleAuthorization(),
        dio: repeated.dio,
      ).read('Google Drive'),
      throwsFormatException,
    );
    expect(repeated.requests.length, 2);
  });

  test(
    'a 401 during upload retries the complete binary body with a fresh token',
    () async {
      final fake = FakeDrive();
      final auth = FakeGoogleAuthorization();
      final adapter = ConsumingUploadAdapter(fake);
      final store = GoogleDriveStore(auth, dio: adapter.dio);
      await db.setSetting('value', 'upload retry');
      final snapshot = await Snapshot.capture(db);
      fake.uploading = snapshot;
      await store.write('Google Drive', snapshot, null);
      expect(adapter.uploads.length, 2);
      expect(adapter.uploads[0], snapshot.encode());
      expect(adapter.uploads[1], snapshot.encode());
      expect(auth.refreshes, contains(true));
      expect(fake.files.length, 1);
    },
  );

  test(
    'malformed metadata sizes and truncated downloads fail explicitly',
    () async {
      final fake = FakeDrive();
      final snapshot = await Snapshot.capture(db);
      fake.add('backup', snapshot);
      final malformed = FakeAdapter(
        (_) => FakeResponse.json({
          'files': [
            {...fake.metadata('backup'), 'size': 'not-a-number'},
          ],
        }),
      );
      await expectLater(
        GoogleDriveStore(
          FakeGoogleAuthorization(),
          dio: malformed.dio,
        ).read('Google Drive'),
        throwsFormatException,
      );
      final truncated = FakeAdapter((request) {
        if (request.uri.path.endsWith('/files')) return fake.handle(request);
        return FakeResponse(
          200,
          snapshot.encode().sublist(0, 10),
          contentType: 'application/octet-stream',
        );
      });
      await expectLater(
        GoogleDriveStore(
          FakeGoogleAuthorization(),
          dio: truncated.dio,
        ).read('Google Drive'),
        throwsFormatException,
      );
    },
  );

  test('changed cloud heads block upload before starting a session', () async {
    final fake = FakeDrive();
    final store = GoogleDriveStore(
      FakeGoogleAuthorization(),
      dio: fake.adapter.dio,
    );
    final first = await Snapshot.capture(db);
    fake.add('old', first);
    final remote = await store.read('Google Drive');
    await db.setSetting('value', 'remote');
    fake.add('new', await Snapshot.capture(db), ['old']);
    await expectLater(
      store.write('Google Drive', first, remote),
      throwsStateError,
    );
    expect(fake.adapter.requests.where((r) => r.method == 'POST'), isEmpty);
  });

  test(
    'concurrent uploads prompt a choice, retain both, then resolve explicitly',
    () async {
      final fake = FakeDrive();
      final store = GoogleDriveStore(
        FakeGoogleAuthorization(),
        dio: fake.adapter.dio,
      );
      await db.setSetting('value', 'a');
      final a = await Snapshot.capture(db);
      await db.setSetting('value', 'b');
      final b = await Snapshot.capture(db);
      fake.add('a', a);
      fake.add('b', b);
      var prompts = 0;
      store.chooseVersion = (versions) async {
        prompts++;
        return versions.singleWhere((v) => v.id == 'a');
      };
      final remote = await store.read('Google Drive');
      expect(remote!.snapshot.revision, a.revision);
      await store.read('Google Drive');
      expect(prompts, 1);
      fake.uploading = b;
      await store.write('Google Drive', b, remote);
      expect(fake.parents['file1'], containsAll(['a', 'b']));
      expect(fake.files.length, 3);
      expect((await store.read('Google Drive'))!.snapshot.revision, b.revision);
    },
  );

  test(
    'one 401 refreshes authorization, but repeated 401 is an error',
    () async {
      final auth = FakeGoogleAuthorization();
      var calls = 0;
      final fake = FakeAdapter((request) {
        if (calls++ == 0) return FakeResponse.json({}, status: 401);
        expect(request.headers['Authorization'], 'Bearer fresh-token');
        return FakeResponse.json({'files': []});
      });
      expect(
        await GoogleDriveStore(auth, dio: fake.dio).read('Google Drive'),
        isNull,
      );
      expect(auth.refreshes, [false, true]);
      final failing = FakeAdapter((_) => FakeResponse.json({}, status: 401));
      await expectLater(
        GoogleDriveStore(auth, dio: failing.dio).read('Google Drive'),
        throwsA(isA<DioException>()),
      );
      expect(failing.requests.length, 2);
    },
  );

  test(
    'invalid upload destination and corrupt snapshot are rejected',
    () async {
      final empty = await Snapshot.capture(db);
      final corrupt = FakeAdapter((r) {
        if (r.uri.path.endsWith('/files')) {
          return FakeResponse.json({
            'files': [
              {
                'id': 'file',
                'size': '${empty.encode().length}',
                'createdTime': '2026-11-08T12:00:00Z',
                'appProperties': {
                  'revision': List.filled(64, '0').join(),
                  'formforgeBackup': '1',
                },
              },
            ],
          });
        }
        return FakeResponse(
          200,
          empty.encode(),
          contentType: 'application/octet-stream',
        );
      });
      await expectLater(
        GoogleDriveStore(
          FakeGoogleAuthorization(),
          dio: corrupt.dio,
        ).read('Google Drive'),
        throwsFormatException,
      );
      final badSession = FakeAdapter(
        (r) => r.method == 'GET'
            ? FakeResponse.json({'files': []})
            : FakeResponse.json(
                {},
                headers: {
                  'location': ['https://untrusted.invalid/upload'],
                },
              ),
      );
      await expectLater(
        GoogleDriveStore(
          FakeGoogleAuthorization(),
          dio: badSession.dio,
        ).write('Google Drive', empty, null),
        throwsFormatException,
      );
      expect(
        badSession.requests.any((r) => r.uri.host == 'untrusted.invalid'),
        false,
      );
    },
  );
}
