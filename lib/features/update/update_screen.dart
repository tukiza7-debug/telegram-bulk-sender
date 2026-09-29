import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/design_system/app_dimens.dart';
import '../../core/design_system/app_theme.dart';
import '../../core/updates/github_release_service.dart';
import '../../core/providers.dart';

/// Update screen: current vs new version, release notes, download with
/// progress, SHA-256 verification, and the system install prompt.
/// Nothing installs without explicit user confirmation.
class UpdateScreen extends ConsumerStatefulWidget {
  const UpdateScreen({super.key});

  @override
  ConsumerState<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends ConsumerState<UpdateScreen> {
  @override
  void initState() {
    super.initState();
    // Screen opened manually or via notification tap — ensure a check ran.
    Future<void>.microtask(() {
      final update = ref.read(updateProvider);
      if (update.phase == UpdatePhase.idle ||
          update.phase == UpdatePhase.checking) {
        ref.read(updateProvider.notifier).checkNow();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final update = ref.watch(updateProvider);
    final controller = ref.read(updateProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Updates')),
      body: SafeArea(
        child: Center(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(AppDimens.s24),
            children: [
              Icon(
                Symbols.system_update_rounded,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: AppDimens.s16),
              Center(
                child: Text(
                  update.currentVersion.isEmpty
                      ? 'Version'
                      : 'v${update.currentVersion}',
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: AppDimens.s32),
              switch (update.phase) {
                UpdatePhase.idle ||
                UpdatePhase.checking =>
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                UpdatePhase.upToDate => _UpToDateCard(
                    onCheck: () => controller.checkNow(),
                  ),
                UpdatePhase.available ||
                UpdatePhase.downloading ||
                UpdatePhase.verifying ||
                UpdatePhase.ready ||
                UpdatePhase.installing ||
                UpdatePhase.error =>
                  _AvailableCard(update: update, controller: controller),
              },
            ],
          ),
        ),
      ),
    );
  }
}

class _UpToDateCard extends StatelessWidget {
  const _UpToDateCard({required this.onCheck});

  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(AppDimens.s16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppDimens.radiusLg),
          ),
          child: Row(
            children: [
              Icon(
                Symbols.check_circle_rounded,
                color: AppTheme.tokensOf(context).success,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  "You're up to date. Checks run automatically every 6 hours "
                  'over Wi-Fi or data.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppDimens.s16),
        OutlinedButton(onPressed: onCheck, child: const Text('Check again')),
      ],
    );
  }
}

class _AvailableCard extends ConsumerWidget {
  const _AvailableCard({required this.update, required this.controller});

  final UpdateState update;
  final UpdateController controller;

  GithubRelease? get release => update.release;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final installing =
        update.phase == UpdatePhase.downloading ||
            update.phase == UpdatePhase.verifying ||
            update.phase == UpdatePhase.installing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(AppDimens.s16),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(AppDimens.radiusLg),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Update available: v${release?.version ?? '?'}',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: AppDimens.s4),
              Text(
                'Installs over your current version. Data and settings are '
                'kept — no uninstall needed.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppDimens.s16),
        if (update.installPermissionMissing) ...[
          _PermissionNotice(
            onOpenSettings: () async {
              await ref.read(installerProvider).openInstallPermissionSettings();
            },
            onRetry: () => controller.recheckInstallPermission(),
          ),
          const SizedBox(height: AppDimens.s16),
        ],
        if (update.error != null) ...[
          Container(
            padding: const EdgeInsets.all(AppDimens.s12),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(AppDimens.radiusMd),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Symbols.error_rounded,
                  size: 18,
                  color: scheme.onErrorContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    update.error!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onErrorContainer),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppDimens.s16),
        ],
        _ReleaseNotes(body: release?.body ?? ''),
        const SizedBox(height: AppDimens.s16),
        switch (update.phase) {
          UpdatePhase.downloading => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: update.downloadProgress),
                const SizedBox(height: AppDimens.s8),
                Text(
                  'Downloading… ${(update.downloadProgress * 100).toStringAsFixed(0)}%',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          UpdatePhase.verifying => const Center(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: CircularProgressIndicator(),
              ),
            ),
          UpdatePhase.ready ||
          UpdatePhase.installing =>
            FilledButton.icon(
              onPressed:
                  update.phase == UpdatePhase.installing ? null : controller.install,
              icon: const Icon(Symbols.install_mobile_rounded, size: 20),
              label: const Text('Install update'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(AppDimens.minTouchTarget),
              ),
            ),
          _ => FilledButton.icon(
              onPressed: installing ? null : controller.download,
              icon: const Icon(Symbols.download_rounded, size: 20),
              label: const Text('Update now'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(AppDimens.minTouchTarget),
              ),
            ),
        },
        const SizedBox(height: AppDimens.s8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Later'),
            ),
            TextButton(
              onPressed: controller.skipThisVersion,
              child: const Text('Skip this version'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ReleaseNotes extends StatelessWidget {
  const _ReleaseNotes({required this.body});

  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = body
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppDimens.s16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppDimens.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("What's new", style: theme.textTheme.titleSmall),
          const SizedBox(height: AppDimens.s8),
          if (lines.isEmpty)
            Text(
              'No release notes were provided for this version.',
              style: theme.textTheme.bodySmall,
            )
          else
            for (final line in lines.take(12))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  line.replaceFirst(RegExp(r'^[#*\-\s]+'), ''),
                  style: theme.textTheme.bodySmall,
                ),
              ),
        ],
      ),
    );
  }
}

class _PermissionNotice extends StatelessWidget {
  const _PermissionNotice({
    required this.onOpenSettings,
    required this.onRetry,
  });

  final VoidCallback onOpenSettings;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppTheme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.all(AppDimens.s12),
      decoration: BoxDecoration(
        color: tokens.warningContainer,
        borderRadius: BorderRadius.circular(AppDimens.radiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Symbols.install_mobile_rounded,
                size: 18,
                color: tokens.onWarningContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'To install updates, allow “Install unknown apps” for '
                  'Bulk Sender.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.onWarningContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppDimens.s8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: onOpenSettings,
                child: const Text('Open settings'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: onRetry,
                child: const Text("I've allowed it"),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
