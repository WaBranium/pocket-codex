/// One-line text measurement for layout decisions made before layout.
library;

import 'package:flutter/widgets.dart';

/// The natural one-line size of [text] in [style] merged over the ambient
/// [DefaultTextStyle], in the ambient direction and text scale.
Size measureTextLine(BuildContext context, String text, [TextStyle? style]) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final size = painter.size;
  painter.dispose();
  return size;
}
