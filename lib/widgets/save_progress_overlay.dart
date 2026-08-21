import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../services/safe_xlsx_write.dart';

/// Section 12а: the one shared progress/error surface for all three
/// Excel-write paths (receipt, driving detail, timesheet day). Drives a
/// [SaveProgressOverlay] via [addListener]/[ChangeNotifier] rather than
/// each screen hand-rolling its own busy/phase bookkeeping.
class SaveProgressController extends ChangeNotifier {
  bool _busy = false;
  bool _showOverlay = false;
  SaveXlsxPhase? _phase;
  ({String? title, String message})? _error;
  Completer<void>? _errorDismissed;

  bool get busy => _busy;
  bool get showOverlay => _showOverlay;
  SaveXlsxPhase? get phase => _phase;
  ({String? title, String message})? get error => _error;

  /// Runs [action], showing phase-labeled progress after the section-12а
  /// 400ms delay (skipped for an error, which must always be visible) and
  /// blocking back-navigation for the duration (see [SaveProgressOverlay]'s
  /// `PopScope`). [action] is handed the same `onPhase` callback the
  /// underlying safe_xlsx_write.dart functions already take.
  ///
  /// On success, shows [successMessage] as a brief SnackBar and returns
  /// true. On failure, turns the overlay into a non-auto-dismissing error
  /// (built from [messageFor], the same per-exception-type text each screen
  /// already had -- this packet only moves *where* it's shown, not the text
  /// itself, which is section 12а's job for now) and returns false once the
  /// user taps OK -- deliberately no cancel/retry mid-write (section 12а:
  /// interrupting a write partway through is worse than waiting it out).
  Future<bool> run(
    BuildContext context,
    Future<void> Function(void Function(SaveXlsxPhase)) action, {
    required ({String? title, String message}) Function(Object error) messageFor,
    required String successMessage,
  }) async {
    _busy = true;
    _phase = SaveXlsxPhase.reading;
    _showOverlay = false;
    _error = null;
    notifyListeners();

    final delayTimer = Timer(const Duration(milliseconds: 400), () {
      _showOverlay = true;
      notifyListeners();
    });

    try {
      await action((phase) {
        _phase = phase;
        notifyListeners();
      });
      delayTimer.cancel();
      _busy = false;
      _showOverlay = false;
      notifyListeners();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(successMessage)));
      }
      return true;
    } catch (e) {
      delayTimer.cancel();
      _error = messageFor(e);
      _showOverlay = true;
      notifyListeners();
      _errorDismissed = Completer<void>();
      await _errorDismissed!.future;
      _busy = false;
      _showOverlay = false;
      _error = null;
      notifyListeners();
      return false;
    }
  }

  void dismissError() {
    _errorDismissed?.complete();
  }
}

/// Wraps [child] with the section-12а modal write-progress/error surface,
/// driven by [controller]. [child] stays visible but input-absorbing while
/// busy, matching the pre-existing Timesheet pattern (dim + block, not
/// replace) rather than swapping the whole body out.
class SaveProgressOverlay extends StatefulWidget {
  final SaveProgressController controller;
  final Widget child;

  const SaveProgressOverlay({super.key, required this.controller, required this.child});

  @override
  State<SaveProgressOverlay> createState() => _SaveProgressOverlayState();
}

class _SaveProgressOverlayState extends State<SaveProgressOverlay> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return PopScope(
      canPop: !controller.busy,
      child: Stack(
        children: [
          AbsorbPointer(absorbing: controller.busy, child: widget.child),
          if (controller.showOverlay) _buildOverlay(context, controller),
        ],
      ),
    );
  }

  Widget _buildOverlay(BuildContext context, SaveProgressController controller) {
    final error = controller.error;
    return Positioned.fill(
      child: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.85),
        child: Center(
          child: error != null ? _buildError(context, error) : _buildProgress(context, controller),
        ),
      ),
    );
  }

  Widget _buildProgress(BuildContext context, SaveProgressController controller) {
    final label = saveXlsxPhaseLabel(context, controller.phase);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        if (label != null) ...[
          const SizedBox(height: 16),
          Text(label),
        ],
      ],
    );
  }

  Widget _buildError(BuildContext context, ({String? title, String message}) error) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (error.title != null) ...[
            Text(error.title!, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(height: 8),
          ],
          Text(error.message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: widget.controller.dismissError,
            child: Text(t(context, 'common.ok')),
          ),
        ],
      ),
    );
  }
}
