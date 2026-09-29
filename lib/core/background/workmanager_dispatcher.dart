import 'package:workmanager/workmanager.dart';

import '../constants.dart';
import '../notifications/notification_service.dart';
import 'update_check_service.dart';

/// Top-level callback dispatcher required by workmanager.
/// Must be a function that is not closable in the Dart snapshot.
///
/// The workmanager callback runs in a FRESH background isolate that has its
/// own plugin registration but no app-level initialization — in particular
/// flutter_local_notifications must be initialized here before any
/// notification can be shown, or the update alert silently fails.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == AppConstants.updateCheckTaskName) {
      await NotificationService.instance.init();
      await UpdateCheckService.run(notify: true);
    }
    return true;
  });
}

/// Registers the periodic 6-hour update check (network constraint).
/// Existing work is kept so re-registering on every app start is a no-op.
Future<void> registerPeriodicUpdateCheck() async {
  await Workmanager().registerPeriodicTask(
    AppConstants.updateCheckTaskUniqueName,
    AppConstants.updateCheckTaskName,
    frequency: const Duration(hours: 6),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}
