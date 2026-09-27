import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/llm_client.dart';
import '../../data/secrets.dart';
import '../../integrations/garmin/garmin_settings_section.dart';
import '../../providers.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  var _kind = LlmProviderKind.openAiCompatible;
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _apiKey = TextEditingController();
  String? _status;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await loadLlmConfig(
        ref.read(databaseProvider), ref.read(secretsProvider));
    if (!mounted) return;
    setState(() {
      _kind = config?.kind ?? _kind;
      _baseUrl.text = config?.baseUrl ?? _kind.defaultBaseUrl;
      _model.text = config?.model ?? '';
      _apiKey.text = config?.apiKey ?? '';
    });
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final db = ref.read(databaseProvider);
    await db.setSetting(SettingKeys.llmKind, _kind.name);
    await db.setSetting(SettingKeys.llmBaseUrl, _baseUrl.text.trim());
    await db.setSetting(SettingKeys.llmModel, _model.text.trim());
    await ref.read(secretsProvider).write(Secrets.llmApiKey, _apiKey.text.trim());
    setState(() => _status = 'Saved');
  }

  Future<void> _test() async {
    await _save();
    setState(() => _busy = true);
    try {
      final config = await loadLlmConfig(
          ref.read(databaseProvider), ref.read(secretsProvider));
      final reply = await LlmClient(config!).complete(
        system: 'You are a connectivity check.',
        prompt: 'Reply with the single word OK.',
      );
      setState(() => _status = 'Response: ${reply.trim()}');
    } catch (e) {
      setState(() => _status = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('AI coach', style: text.titleMedium),
          const Text('Bring your own key. Stored only in the OS keystore.'),
          const SizedBox(height: 8),
          DropdownButtonFormField<LlmProviderKind>(
            initialValue: _kind,
            decoration: const InputDecoration(labelText: 'Provider'),
            items: [
              for (final k in LlmProviderKind.values)
                DropdownMenuItem(value: k, child: Text(k.label)),
            ],
            onChanged: (k) => setState(() {
              _kind = k!;
              _baseUrl.text = k.defaultBaseUrl;
            }),
          ),
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(labelText: 'Base URL'),
          ),
          TextField(
            controller: _model,
            decoration: const InputDecoration(labelText: 'Model'),
          ),
          TextField(
            controller: _apiKey,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: 'API key (optional for local models)'),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 12, children: [
            FilledButton(onPressed: _save, child: const Text('Save')),
            OutlinedButton(
              onPressed: _busy ? null : _test,
              child: const Text('Test connection'),
            ),
          ]),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!),
          ],
          const Divider(height: 32),
          Text('Garmin Connect', style: text.titleMedium),
          const GarminSettingsSection(),
        ],
      ),
    );
  }
}
