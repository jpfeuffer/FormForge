import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'features/activities/activities_page.dart';
import 'features/calendar/calendar_page.dart';
import 'features/fitness/fitness_page.dart';
import 'features/settings/settings_page.dart';
import 'features/today/today_page.dart';

final _destinations = [
  (path: '/today', label: 'Today', icon: Icons.today, page: const TodayPage()),
  (
    path: '/calendar',
    label: 'Calendar',
    icon: Icons.calendar_month,
    page: const CalendarPage()
  ),
  (
    path: '/activities',
    label: 'Activities',
    icon: Icons.directions_run,
    page: const ActivitiesPage()
  ),
  (
    path: '/fitness',
    label: 'Fitness',
    icon: Icons.monitor_heart,
    page: const FitnessPage()
  ),
  (
    path: '/settings',
    label: 'Settings',
    icon: Icons.settings,
    page: const SettingsPage()
  ),
];

final router = GoRouter(
  initialLocation: '/today',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => _Shell(shell: shell),
      branches: [
        for (final d in _destinations)
          StatefulShellBranch(routes: [
            GoRoute(path: d.path, builder: (_, _) => d.page),
          ]),
      ],
    ),
  ],
);

class FormForgeApp extends StatelessWidget {
  const FormForgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme:
              ColorScheme.fromSeed(seedColor: Colors.deepOrange, brightness: b),
        );
    return MaterialApp.router(
      title: 'FormForge',
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      routerConfig: router,
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({required this.shell});

  final StatefulNavigationShell shell;

  void _go(int i) => shell.goBranch(i, initialLocation: i == shell.currentIndex);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: shell.currentIndex,
            onDestinationSelected: _go,
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final d in _destinations)
                NavigationRailDestination(
                    icon: Icon(d.icon), label: Text(d.label)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: shell),
        ]),
      );
    }
    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: _go,
        destinations: [
          for (final d in _destinations)
            NavigationDestination(icon: Icon(d.icon), label: d.label),
        ],
      ),
    );
  }
}
