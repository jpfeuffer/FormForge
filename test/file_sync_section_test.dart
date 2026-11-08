import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:formforge/data/database.dart';
import 'package:formforge/data/file_sync.dart';
import 'package:formforge/features/settings/file_sync_section.dart';

void main() {
  testWidgets(
    'Sync asks before replacing independent data; cancel preserves both',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final sync = _ConflictSync(db);
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [fileSyncProvider.overrideWith((ref) async => sync)],
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
