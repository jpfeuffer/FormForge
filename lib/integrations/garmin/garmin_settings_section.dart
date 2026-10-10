import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'garmin_exceptions.dart';
import 'garmin_providers.dart';
import 'garmin_push_button.dart';
import 'garmin_push_providers.dart';

class GarminSettingsSection extends ConsumerStatefulWidget {
  const GarminSettingsSection({super.key});

  @override
  ConsumerState<GarminSettingsSection> createState() =>
      _GarminSettingsSectionState();
}

class _GarminSettingsSectionState extends ConsumerState<GarminSettingsSection> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  var _busy = false;
  double? _progress;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on GarminException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Unexpected error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _login() => _run(() async {
    await ref
        .read(garminAccountProvider.notifier)
        .login(_email.text.trim(), _password.text, promptMfa: _promptMfa);
    _password.clear();
  });

  Future<String> _promptMfa() async {
    if (!mounted) return '';
    final code = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _MfaDialog(),
    );
    return code ?? '';
  }

  Future<void> _sync() => _run(() async {
    final count = await ref.read(garminSyncServiceProvider).syncRecent();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Synced $count activities from Garmin')),
    );
  });

  Future<void> _push() => _run(() async {
    final today = DateTime.now();
    final from = DateTime(today.year, today.month, today.day);
    try {
      await pushToGarmin(
        context,
        ref,
        from,
        DateTime(from.year, from.month, from.day + 13),
        onProgress: (done, total) {
          if (mounted) setState(() => _progress = done / total);
        },
      );
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  });

  Future<void> _cleanup() => _run(() async {
    final today = DateTime.now();
    final result = await ref
        .read(garminPushServiceProvider)
        .cleanupOrphans(
          from: DateTime(today.year, today.month, today.day - 7),
          to: DateTime(today.year, today.month, today.day + 120),
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(result.message)));
  });

  Future<void> _logout() =>
      _run(() => ref.read(garminAccountProvider.notifier).logout());

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(garminAccountProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        switch (account) {
          AsyncData(value: final name?) => _connected(name),
          AsyncData() || AsyncError() => _loginForm(),
          _ => const LinearProgressIndicator(),
        },
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }

  Widget _connected(String name) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('Connected as $name'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: _busy ? null : _sync,
            icon: _busy ? const _Spinner() : const Icon(Icons.sync),
            label: const Text('Sync recent activities'),
          ),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _push,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: const Text('Push next 14 days to Garmin'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : _cleanup,
            child: const Text('Clean up old FormForge workouts'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : _logout,
            child: const Text('Logout'),
          ),
        ],
      ),
      if (_progress != null) ...[
        const SizedBox(height: 8),
        LinearProgressIndicator(value: _progress),
      ],
    ],
  );

  Widget _loginForm() => AutofillGroup(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Sign in with your Garmin account. Only access tokens '
          'are stored; your password is never saved.',
        ),
        TextField(
          controller: _email,
          enabled: !_busy,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        TextField(
          controller: _password,
          enabled: !_busy,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          decoration: const InputDecoration(labelText: 'Password'),
          onSubmitted: (_) => _busy ? null : _login(),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _login,
          icon: _busy ? const _Spinner() : const Icon(Icons.login),
          label: const Text('Login'),
        ),
      ],
    ),
  );
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 16,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}

class _MfaDialog extends StatefulWidget {
  const _MfaDialog();

  @override
  State<_MfaDialog> createState() => _MfaDialogState();
}

class _MfaDialogState extends State<_MfaDialog> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Garmin verification code'),
    content: TextField(
      controller: _code,
      autofocus: true,
      keyboardType: TextInputType.number,
      autofillHints: const [AutofillHints.oneTimeCode],
      decoration: const InputDecoration(
        labelText: 'Code from your email, SMS or authenticator app',
      ),
      onSubmitted: (v) => Navigator.pop(context, v.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _code.text.trim()),
        child: const Text('Verify'),
      ),
    ],
  );
}
