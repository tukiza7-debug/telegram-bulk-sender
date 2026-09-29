import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/history/history_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/onboarding/permission_primer_screen.dart';
import '../../features/onboarding/token_onboarding_screen.dart';
import '../../features/picker/photo_picker_screen.dart';
import '../../features/send/send_progress_screen.dart';
import '../../features/send/send_review_screen.dart';
import '../../features/settings/permissions_screen.dart';
import '../../features/settings/reconnect_token_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/update/update_screen.dart';

/// Global navigator key so notification taps can navigate from anywhere.
final rootNavigatorKey = GlobalKey<NavigatorState>();

final appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const TokenOnboardingScreen(),
    ),
    GoRoute(
      path: '/onboarding/permissions',
      builder: (context, state) => const PermissionPrimerScreen(),
    ),
    GoRoute(
      path: '/picker',
      builder: (context, state) => const PhotoPickerScreen(),
    ),
    GoRoute(
      path: '/review',
      builder: (context, state) => const SendReviewScreen(),
    ),
    GoRoute(
      path: '/progress',
      builder: (context, state) => const SendProgressScreen(),
    ),
    GoRoute(
      path: '/history',
      builder: (context, state) => const HistoryScreen(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      path: '/settings/permissions',
      builder: (context, state) => const PermissionsScreen(),
    ),
    GoRoute(
      path: '/settings/reconnect',
      builder: (context, state) => const ReconnectTokenScreen(),
    ),
    GoRoute(
      path: '/update',
      builder: (context, state) => const UpdateScreen(),
    ),
  ],
);
