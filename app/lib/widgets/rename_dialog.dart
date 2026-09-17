import 'package:flutter/material.dart';

/// Rename dialog that owns its text controller, so the controller is disposed
/// only when the dialog's element is (after the dismiss animation finishes) —
/// disposing it in the caller's async gap would crash the still-animating
/// TextField ("controller used after being disposed").
class RenameDialog extends StatefulWidget {
  final String initial;
  final String hint;
  final String title;
  const RenameDialog({
    super.key,
    required this.initial,
    required this.hint,
    this.title = "Rename throw",
  });

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // `autofocus` alone is unreliable at raising the Android keyboard when a
    // dialog opens (especially from a popup menu). Request focus once the
    // dialog is actually on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        focusNode: _focusNode,
        autofocus: true,
        textInputAction: TextInputAction.done,
        // Gboard can close/crash the instant a Flutter TextField gains focus when
        // its suggestion / autocorrect / personalized-learning features engage
        // (flutter/flutter#80709). Disabling them is the standard workaround and
        // is harmless for short throw names.
        keyboardType: TextInputType.text,
        enableSuggestions: false,
        autocorrect: false,
        enableIMEPersonalizedLearning: false,
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: TextStyle(color: Colors.grey.shade400),
          labelText: "Name (blank to clear)",
        ),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Cancel"),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text("Save"),
        ),
      ],
    );
  }
}
