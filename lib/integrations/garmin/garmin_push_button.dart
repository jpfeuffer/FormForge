import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../fit/watch_export_service.dart';
import 'garmin_providers.dart';
import 'garmin_push_providers.dart';
import 'garmin_push_service.dart';

/// Pushes `[from, to]` to Garmin and reports via SnackBar; `null` if not connected.
Future<PushSummary?> pushToGarmin(
  BuildContext context,
  WidgetRef ref,
  DateTime from,
  DateTime to, {
  void Function(int done, int total)? onProgress,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (ref.read(garminAccountProvider).value == null) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Connect your Garmin account in Settings first'),
      ),
    );
    return null;
  }
  final summary = await ref
      .read(garminPushServiceProvider)
      .pushRange(from, to, onProgress: onProgress);
  messenger.showSnackBar(SnackBar(content: Text(summary.message)));
  return summary;
}

Future<void> showFitExportResult(
  BuildContext context,
  WatchExportResult result,
) async {
  if (result is ExportedToFolder) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('FIT files saved'),
        content: Text(result.message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return;
  }
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(result.message)));
}

enum _Action { push, exportFit }

/// AppBar action with "Push to Garmin" and "Export FIT files…" for a date range.
class GarminPushButton extends ConsumerStatefulWidget {
  const GarminPushButton({super.key, required this.from, required this.to});

  final DateTime from;
  final DateTime to;

  @override
  ConsumerState<GarminPushButton> createState() => _GarminPushButtonState();
}

class _GarminPushButtonState extends ConsumerState<GarminPushButton> {
  var _busy = false;

  Future<void> _run(_Action action) async {
    setState(() => _busy = true);
    try {
      switch (action) {
        case _Action.push:
          await pushToGarmin(context, ref, widget.from, widget.to);
        case _Action.exportFit:
          final result = await ref
              .read(watchExportServiceProvider)
              .exportFitForRange(widget.from, widget.to);
          if (mounted) await showFitExportResult(context, result);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopupMenuButton<_Action>(
    tooltip: 'Garmin',
    enabled: !_busy,
    onSelected: _run,
    icon: _busy
        ? const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.watch_outlined),
    itemBuilder: (_) => const [
      PopupMenuItem(
        value: _Action.push,
        child: ListTile(
          leading: Icon(Icons.cloud_upload_outlined),
          title: Text('Push week to Garmin'),
        ),
      ),
      PopupMenuItem(
        value: _Action.exportFit,
        child: ListTile(
          leading: Icon(Icons.file_download_outlined),
          title: Text('Export FIT files…'),
        ),
      ),
    ],
  );
}
