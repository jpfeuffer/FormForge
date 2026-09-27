/// A named numeric band, e.g. a HR zone in bpm or a pace zone in m/s.
class Zone {
  const Zone(this.name, this.lower, this.upper) : assert(lower <= upper);

  final String name;
  final double lower;
  final double upper;

  bool contains(double value) => value >= lower && value <= upper;

  double get mid => (lower + upper) / 2;

  @override
  String toString() => 'Zone($name: $lower–$upper)';
}
