import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import 'snapshot.dart';

class SharedFile {
  static const _channel = MethodChannel('formforge/shared_file');

  static Future<String?> pick({required bool create}) async {
    if (Platform.isIOS) {
      throw UnsupportedError(
        'Remembered shared files currently support Android and desktop, not iOS.',
      );
    }
    if (Platform.isAndroid) {
      return _channel.invokeMethod<String>(create ? 'create' : 'pick');
    }
    if (create) {
      final directory = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose a synced folder for training.formforge',
      );
      if (directory == null) return null;
      final path = '$directory${Platform.pathSeparator}training.formforge';
      if (await File(path).exists()) {
        throw StateError(
          'training.formforge already exists. Connect the existing file instead.',
        );
      }
      return path;
    }
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Connect shared FormForge backup',
      type: FileType.any,
    );
    return result.isEmpty ? null : result.single.path;
  }

  static Future<Uint8List> read(String target) async {
    if (!Platform.isAndroid) {
      final file = File(target);
      if (await file.length() > snapshotLimit) {
        throw const FormatException('Backup is too large');
      }
      return file.readAsBytes();
    }
    final path = await _channel.invokeMethod<String>('read', {'uri': target});
    if (path == null) {
      throw StateError('Document provider did not return a file');
    }
    try {
      return await File(path).readAsBytes();
    } finally {
      await File(path).delete();
    }
  }

  static Future<void> write(String target, Uint8List bytes) async {
    if (!Platform.isAndroid) {
      final temporary = File(
        '$target.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      try {
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(target);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      return;
    }
    final temporary = await Directory.systemTemp.createTemp(
      'formforge-upload-',
    );
    final file = File('${temporary.path}${Platform.pathSeparator}backup');
    try {
      await file.writeAsBytes(bytes, flush: true);
      await _channel.invokeMethod<void>('write', {
        'uri': target,
        'path': file.path,
      });
    } finally {
      await file.delete();
      await temporary.delete();
    }
  }
}
