/// Garmin typeKeys and the FIT importer's keys both contain `run` for runs.
bool isRunSport(String sport) => sport.contains('run');

bool isStrengthSport(String sport) => sport.contains('strength');
