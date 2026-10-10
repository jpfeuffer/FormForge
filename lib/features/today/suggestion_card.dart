import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_core/training_core.dart';

import '../adaptation/adaptation_providers.dart';
import '../adaptation/plan_regenerator.dart';
import '../adaptation/verdict_style.dart';

class SuggestionCard extends ConsumerWidget {
  const SuggestionCard({super.key, required this.suggestion});

  final AdaptationSuggestion suggestion;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final applicable = canApply(
      suggestion.action,
      regenerator: ref.watch(planRegeneratorProvider),
      adjuster: ref.watch(planAdjusterProvider),
    );

    Future<void> apply() async {
      final messenger = ScaffoldMessenger.of(context);
      try {
        final message = await ref
            .read(suggestionApplierProvider)
            .apply(suggestion);
        messenger.showSnackBar(SnackBar(content: Text(message)));
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Could not apply: $e')));
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                Icon(
                  suggestion.severity.icon,
                  color: suggestion.severity.color(scheme),
                ),
                Expanded(child: Text(suggestion.message)),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => ref
                        .read(dismissedSuggestionsProvider.notifier)
                        .dismiss(suggestion.key),
                    child: const Text('Dismiss'),
                  ),
                  if (applicable)
                    FilledButton(onPressed: apply, child: const Text('Apply')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
