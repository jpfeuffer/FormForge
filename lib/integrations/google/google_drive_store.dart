import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../data/snapshot.dart';
import '../../data/snapshot_store.dart';
import 'google_auth.dart';

class GoogleBackupVersion {
  GoogleBackupVersion(
    this.id,
    this.revision,
    this.parents,
    this.created,
    this.size,
  );
  final String id;
  final String revision;
  final List<String> parents;
  final DateTime created;
  final int size;
}

class GoogleDriveStore implements SnapshotStore {
  GoogleDriveStore(this.authorization, {Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 3),
              sendTimeout: const Duration(minutes: 3),
            ),
          );

  final GoogleAuthorization authorization;
  final Dio _dio;
  Future<GoogleBackupVersion?> Function(List<GoogleBackupVersion>)?
  chooseVersion;
  String? _chosenRevision;
  String? _chosenVersion;
  static const _api = 'https://www.googleapis.com/drive/v3/files';
  static const _upload = 'https://www.googleapis.com/upload/drive/v3/files';

  @override
  String get stateFileName {
    final account = authorization.account;
    if (account == null) throw StateError('Sign in to Google first');
    return 'google-backup-${sha256.convert(utf8.encode(account.id))}.json';
  }

  @override
  String get uploadMessage => 'Google Drive backup uploaded and verified.';

  Future<Response<T>> _request<T>(
    String method,
    String url, {
    Object? data,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    ResponseType? responseType,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await authorization.accessToken(refresh: attempt == 1);
      try {
        return await _dio.request<T>(
          url,
          data: data is Uint8List ? Stream.value(data) : data,
          queryParameters: query,
          options: Options(
            method: method,
            responseType: responseType,
            headers: {'Authorization': 'Bearer $token', ...?headers},
          ),
        );
      } on DioException catch (e) {
        if (e.response?.statusCode != 401 || attempt == 1) rethrow;
      }
    }
    throw StateError('Google authorization failed');
  }

  Future<List<GoogleBackupVersion>> _heads() async {
    final versions = <GoogleBackupVersion>[];
    final pages = <String>{};
    String? page;
    do {
      final response = await _request<Map<String, dynamic>>(
        'GET',
        _api,
        query: {
          'spaces': 'appDataFolder',
          'q': "appProperties has { key='formforgeBackup' and value='1' }",
          'fields': 'nextPageToken,files(id,size,createdTime,appProperties)',
          'pageSize': 1000,
          'pageToken': ?page,
        },
      );
      final data = response.data;
      if (data == null || data['files'] is! List) {
        throw const FormatException('Invalid Google backup listing');
      }
      for (final raw in data['files'] as List) {
        if (raw is! Map || raw['appProperties'] is! Map) {
          throw const FormatException('Invalid Google backup metadata');
        }
        final props = Map<String, dynamic>.from(raw['appProperties'] as Map);
        final revision = props['revision'];
        if (raw['id'] is! String ||
            !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(raw['id'] as String) ||
            revision is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(revision) ||
            raw['createdTime'] is! String) {
          throw const FormatException('Invalid Google backup identity');
        }
        final size = raw['size'] is String
            ? int.tryParse(raw['size'] as String)
            : null;
        if (size == null || size <= 0 || size > snapshotLimit) {
          throw const FormatException(
            'Google backup exceeds the supported size limit or is incomplete',
          );
        }
        final parents = <String>[];
        for (final entry in props.entries.where(
          (e) => e.key.startsWith('parent'),
        )) {
          if (entry.value is! String ||
              !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(entry.value as String)) {
            throw const FormatException('Invalid Google backup parent');
          }
          parents.add(entry.value as String);
        }
        versions.add(
          GoogleBackupVersion(
            raw['id'] as String,
            revision,
            parents,
            DateTime.parse(raw['createdTime'] as String),
            size,
          ),
        );
      }
      page = data['nextPageToken'] as String?;
      if (page != null && !pages.add(page)) {
        throw const FormatException('Google backup listing repeated a page');
      }
    } while (page != null);
    final parents = versions.expand((v) => v.parents).toSet();
    final heads = <String, GoogleBackupVersion>{};
    for (final version in versions) {
      if (!parents.contains(version.id)) heads[version.id] = version;
    }
    if (versions.isNotEmpty && heads.isEmpty) {
      throw const FormatException(
        'Google backup history has no current snapshot',
      );
    }
    return heads.values.toList()
      ..sort((a, b) => b.created.compareTo(a.created));
  }

  String _version(List<GoogleBackupVersion> heads) {
    final revisions = heads.map((h) => h.id).toList()..sort();
    return sha256.convert(utf8.encode(revisions.join(','))).toString();
  }

  @override
  Future<RemoteSnapshot?> read(String target) async {
    final heads = await _heads();
    if (heads.isEmpty) return null;
    final version = _version(heads);
    var selected = heads.first;
    if (heads.map((h) => h.revision).toSet().length > 1) {
      final cached = heads.where((h) => h.id == _chosenRevision);
      if (_chosenVersion == version && cached.isNotEmpty) {
        selected = cached.first;
      } else {
        final choose = chooseVersion;
        if (choose == null) {
          throw StateError(
            'Concurrent Google backups found. Choose a snapshot before continuing.',
          );
        }
        final choice = await choose(heads);
        if (choice == null) {
          throw StateError(
            'Google backup selection cancelled; no data changed',
          );
        }
        if (!heads.contains(choice)) {
          throw StateError('Invalid Google backup selection');
        }
        selected = choice;
        _chosenRevision = selected.id;
        _chosenVersion = version;
      }
    }
    return RemoteSnapshot(await _download(selected), version);
  }

  Future<Snapshot> _download(GoogleBackupVersion selected) async {
    final response = await _request<ResponseBody>(
      'GET',
      '$_api/${Uri.encodeComponent(selected.id)}',
      query: {'alt': 'media'},
      responseType: ResponseType.stream,
    );
    final body = response.data;
    if (body == null) {
      throw const FormatException('Empty Google backup response');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      if (bytes.length + chunk.length > snapshotLimit) {
        throw const FormatException('Google backup is too large');
      }
      bytes.add(chunk);
    }
    if (bytes.length != selected.size) {
      throw const FormatException('Google backup size mismatch');
    }
    final snapshot = await Snapshot.decode(bytes.takeBytes());
    if (snapshot.revision != selected.revision) {
      throw const FormatException('Google backup checksum mismatch');
    }
    return snapshot;
  }

  @override
  Future<void> write(
    String target,
    Snapshot snapshot,
    RemoteSnapshot? expected,
  ) async {
    final heads = await _heads();
    if ((heads.isEmpty ? null : _version(heads)) != expected?.version) {
      throw StateError('Google backup changed during sync. Please retry.');
    }
    if (heads.length > 20) {
      throw StateError(
        'Too many concurrent Google backups to resolve in one upload',
      );
    }
    final bytes = snapshot.encode();
    final session = await _request<Map<String, dynamic>>(
      'POST',
      _upload,
      query: {'uploadType': 'resumable', 'fields': 'id'},
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Type': 'application/octet-stream',
        'X-Upload-Content-Length': bytes.length,
      },
      data: {
        'name': 'training-${snapshot.revision}.formforge',
        'parents': ['appDataFolder'],
        'appProperties': {
          'formforgeBackup': '1',
          'revision': snapshot.revision,
          for (var i = 0; i < heads.length; i++) 'parent$i': heads[i].id,
        },
      },
    );
    final location = session.headers.value('location');
    final uri = location == null ? null : Uri.tryParse(location);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'www.googleapis.com' ||
        !uri.path.startsWith('/upload/drive/')) {
      throw const FormatException('Invalid Google upload session URL');
    }
    final upload = await _request<Map<String, dynamic>>(
      'PUT',
      uri.toString(),
      data: bytes,
      headers: {
        'Content-Type': 'application/octet-stream',
        'Content-Length': bytes.length,
      },
    );
    final uploadedId = upload.data?['id'];
    if (uploadedId is! String || uploadedId.isEmpty) {
      throw const FormatException('Google upload did not complete');
    }
    final latest = await _heads();
    final uploaded = latest.where((version) => version.id == uploadedId);
    if (uploaded.isEmpty ||
        latest.any((version) => version.revision != snapshot.revision)) {
      throw StateError(
        'Google backup changed during upload. Both snapshots are preserved; retry and choose which to keep.',
      );
    }
    await _download(uploaded.single);
  }
}
