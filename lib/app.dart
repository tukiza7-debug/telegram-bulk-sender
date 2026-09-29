import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/constants.dart';
import 'core/design_system/app_theme.dart';
import 'core/notifications/notification_service.dart';
import 'core/providers.dart';
import 'core/router/app_router.dart';

class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App> {
  @override
  void initState() {
    super.initState();
    NotificationService.onNotificationTap = (route) => appRouter.push(route);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await ref.read(botSessionProvider.notifier).restore();
    // Reattach progress UI if a bulk send survived in the foreground service.
    await ref.read(sendProvider.notifier).reattach();
    // Fresh silent check so the Home banner is up to date on open.
    await ref.read(updateProvider.notifier).refreshFromBackgroundCheck();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      routerConfig: appRouter,
    );
  }
}
