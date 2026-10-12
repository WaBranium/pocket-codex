import 'package:flutter/material.dart';

/// A titled card whose rows are separated by hairlines — the app's standard way
/// to group related settings or capabilities.
///
/// Settings, the services hub and the Codex wizard each grew their own copy of
/// this, which is how they came to disagree on header height and inset for what
/// reads as one component. [hint] adds a line under the title for a group that
/// needs framing; [trailing] puts a count or status pill on the header row,
/// or under the title when the two do not fit on one line.
class GroupCard extends StatelessWidget {
  /// Creates a titled group of [children].
  const GroupCard({
    super.key,
    required this.title,
    required this.children,
    this.hint,
    this.trailing,
  });

  /// The group's name.
  final String title;

  /// A sentence of framing under the title, when the name alone is not enough.
  final String? hint;

  /// Header-row trailing widget — a count pill, a status chip.
  final Widget? trailing;

  /// The rows, each preceded by a hairline so the header reads as their parent.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        if (hint != null) ...[
          const SizedBox(height: 2),
          Text(
            hint!,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            // A minimum rather than a fixed height, so a wrapped hint grows the
            // header instead of being clipped by it.
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
            child: trailing == null
                ? Row(children: [Expanded(child: heading)])
                // The trailing pill sits at the end of the title's line while
                // both fit there; otherwise (large text, a long translation)
                // it moves under the title rather than squeezing it.
                : Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: SizedBox(
                      width: double.infinity,
                      child: Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 6,
                        children: [heading, trailing!],
                      ),
                    ),
                  ),
          ),
          for (final child in children) ...[
            Divider(height: 1, color: scheme.outlineVariant),
            child,
          ],
        ],
      ),
    );
  }
}
