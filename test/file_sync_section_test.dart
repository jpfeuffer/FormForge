import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/data/file_sync.dart';
import 'package:formforge/features/settings/file_sync_section.dart';
import 'package:formforge/integrations/google/google_auth.dart';
import 'package:formforge/integrations/google/google_providers.dart';

void main() {
  testWidgets('Google sign-in hides file controls and sign-out restores them', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final sync = _ConflictSync(db);
    final authorization = _FakeGoogleAuthorization();
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            fileSyncProvider.overrideWith((ref) async => sync),
            googleAuthorizationProvider.overrideWith(
              (ref) async => authorization,
            ),
            googleFileSyncProvider.overrideWith((ref) async => sync),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: FileSyncSection()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Create shared file'), findsOneWidget);
      await tester.tap(find.text('Sign in with Google'));
      await tester.pumpAndSettle();
      expect(find.text('Create shared file'), findsNothing);
      expect(find.text('Connect existing file'), findsNothing);
      expect(find.text('Google account: test@example.invalid'), findsOneWidget);
      await tester.tap(find.text('Sign out of Google'));
      await tester.pumpAndSettle();
      expect(find.text('Create shared file'), findsOneWidget);
      expect(find.text('Connect existing file'), findsOneWidget);
      expect(sync.target, 'shared.formforge');
    } finally {
      await db.close();
    }
  });

  testWidgets(
    'Sync asks before replacing independent data; cancel preserves both',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final sync = _ConflictSync(db);
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              fileSyncProvider.overrideWith((ref) async => sync),
              googleAuthorizationProvider.overrideWith(
                (ref) async => _FakeGoogleAuthorization(),
              ),
            ],
            child: const MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(child: FileSyncSection()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sync'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Choose which snapshot to keep'), findsOneWidget);
        expect(find.text('Keep local / upload'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(sync.choice, isNull);
        expect(find.text('Cancelled; no data changed'), findsOneWidget);
      } finally {
        await db.close();
      }
    },
  );
}

class _FakeGoogleAuthorization implements GoogleAuthorization {
  @override
  GoogleAccount? account;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> signIn() async =>
      account = const GoogleAccount('test', 'test@example.invalid');
  @override
  Future<void> signOut() async => account = null;
  @override
  Future<String> accessToken({bool refresh = false}) async => 'test-token';
}

class _ConflictSync extends FileSync {
  _ConflictSync(AppDatabase db) : super(db, Directory.systemTemp) {
    target = 'shared.formforge';
  }

  SnapshotAction? choice;

  @override
  Future<String> sync(
    Future<SnapshotAction?> Function(SnapshotAction) choose,
  ) async {
    choice = await choose(SnapshotAction.conflict);
    return 'Cancelled; no data changed';
  }
}
