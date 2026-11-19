import 'package:flutter/material.dart';

import '../../services/localization_service.dart';

/// Asks for a reason (3-500 characters). Returns the trimmed text, or null
/// when cancelled. The dialog owns its text controller, so it stays valid
/// while the route animates closed.
Future<String?> askReason(
  BuildContext context, {
  required String title,
  required String label,
  required String confirmLabel,
  String? message,
}) => showDialog<String>(
  context: context,
  builder: (_) => ReasonDialog(
    title: title,
    label: label,
    confirmLabel: confirmLabel,
    message: message,
  ),
);

class ReasonDialog extends StatefulWidget {
  const ReasonDialog({
    super.key,
    required this.title,
    required this.label,
    required this.confirmLabel,
    this.message,
  });
  final String title;
  final String label;
  final String confirmLabel;
  final String? message;

  @override
  State<ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<ReasonDialog> {
  final _controller = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final text = _controller.text.trim();
    if (text.length < 3 || text.length > 500) {
      setState(() => _problem = AppStrings.of(context).text('reason_required'));
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.message != null) ...[
              Text(widget.message!),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _controller,
              autofocus: true,
              maxLength: 500,
              maxLines: 3,
              minLines: 1,
              decoration: InputDecoration(
                labelText: widget.label,
                errorText: _problem,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.text('cancel')),
        ),
        FilledButton(onPressed: _confirm, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
