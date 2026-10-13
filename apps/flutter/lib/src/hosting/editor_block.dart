import 'package:flutter/material.dart';

/// One padded block inside a hosting editor [GroupCard] section, inset like
/// the card's own header.
class EditorBlock extends StatelessWidget {
  /// Creates a block around [child].
  const EditorBlock({super.key, required this.child});

  /// The block's content.
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(18, 14, 18, 16), child: child);
}

/// A quiet note under the control it explains.
class EditorNote extends StatelessWidget {
  /// Creates a note.
  const EditorNote(this.text, {super.key, this.color});

  /// The note.
  final String text;

  /// Its colour; muted by default.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: color ?? theme.colorScheme.onSurfaceVariant,
        height: 1.4,
      ),
    );
  }
}
