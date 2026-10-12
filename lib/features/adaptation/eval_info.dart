import 'package:flutter/material.dart';
import 'package:training_core/training_core.dart';

/// Hover (desktop) or tap (mobile) explanation for an evaluation value.
class Info extends StatelessWidget {
  const Info(this.message, {super.key, required this.child});

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: message,
    waitDuration: const Duration(milliseconds: 350),
    showDuration: const Duration(seconds: 8),
    triggerMode: TooltipTriggerMode.tap,
    constraints: const BoxConstraints(maxWidth: 320),
    padding: const EdgeInsets.all(10),
    child: child,
  );
}

abstract final class EvalInfo {
  static const pace = 'Average pace over the whole activity as recorded by the '
      'watch. Time with the timer stopped is not included.';

  static const avgHr = 'Average heart rate over the activity.';

  static const maxHr = 'Highest heart rate recorded.';

  static const efficiency =
      'Efficiency factor: metres covered per minute per heartbeat. Higher '
      'means more speed for the same heart rate. Compare it between similar '
      'easy runs; a rising value over weeks means your aerobic fitness is '
      'improving.';

  static const decoupling =
      'Aerobic decoupling (Pa:HR): how much the speed-per-heartbeat '
      'dropped from the first to the second half of the run. Under 5 % is a '
      'solid aerobic base; above about 10 % means the effort, heat or '
      'fatigue was too much. Only shown for steady runs of 40+ minutes.';

  static const hrTss =
      'Heart-rate training stress: how taxing the run was, scaled so that one '
      'hour at your threshold heart rate is 100. It feeds your fitness / '
      'fatigue / form chart.';

  static const completed =
      'Share of the planned work you actually did, weighted by step length. '
      'Below 75 % the session counts as incomplete.';

  static const paceInTarget =
      'Share of the work-step time your pace was inside the planned pace '
      'band, ignoring pauses.';

  static const hrInTarget =
      'Share of the work-step time your heart rate was inside the planned '
      'band, ignoring pauses. HR lags behind pace, so short intervals score '
      'lower here.';

  static String session(SessionVerdict v) => switch (v) {
    SessionVerdict.onTarget =>
      'Overall the run matched the plan: less than half of the work time '
          'was clearly too fast or too slow.',
    SessionVerdict.tooHard =>
      'At least half of the work time was faster than the planned pace band '
          '(more than 3 % over) or with a heart rate above the band.',
    SessionVerdict.tooEasy =>
      'At least half of the work time was slower than the planned pace band '
          '(more than 3 % under).',
    SessionVerdict.incomplete =>
      'Less than 75 % of the planned workout was completed.',
  };

  static String step(StepVerdict v) => switch (v) {
    StepVerdict.onTarget =>
      'Average pace and heart rate were within the plan, allowing 3 % '
          'tolerance. Recovery steps are not judged.',
    StepVerdict.tooFast =>
      'Average pace was more than 3 % faster than the upper end of the '
          'planned band.',
    StepVerdict.tooSlow =>
      'Average pace was more than 3 % slower than the lower end of the '
          'planned band.',
    StepVerdict.hrTooHigh =>
      'Average heart rate was more than 3 % above the planned band. Only '
          'judged on work steps of at least 3 minutes.',
    StepVerdict.notCompleted =>
      'Less than 85 % of this step was executed, or it was not found in the '
          'recording.',
  };

  static const targetBand =
      'The planned target range of this step, drawn only while the step was '
      'planned.';
}
