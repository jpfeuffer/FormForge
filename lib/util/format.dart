/// Parses `ss`, `mm:ss` or `h:mm:ss`.
Duration? parseDuration(String input) {
  final parts = input.trim().split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  final nums = parts.map(int.tryParse).toList();
  if (nums.any((n) => n == null || n < 0)) return null;
  var seconds = 0;
  for (final n in nums) {
    seconds = seconds * 60 + n!;
  }
  return seconds > 0 ? Duration(seconds: seconds) : null;
}

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

String formatKm(double meters) => '${(meters / 1000).toStringAsFixed(2)} km';
