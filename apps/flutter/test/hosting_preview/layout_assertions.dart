part of '../hosting_agent_preview_test.dart';

/// [finder] is entirely within `top..bottom` and receives a tap at its
/// centre.
void _operable(WidgetTester t, Finder finder, {double? bottom}) {
  final rect = t.getRect(finder);
  final limit = bottom ?? t.view.physicalSize.height;
  expect(rect.top, greaterThanOrEqualTo(-0.5), reason: '$finder top');
  expect(rect.bottom, lessThanOrEqualTo(limit + 0.5), reason: '$finder');
  expect(finder.hitTestable(), findsOneWidget, reason: '$finder is hit');
}

/// Whether [finder] lies entirely on the [size] screen (and inside the
/// clipping viewport [within], if given) and receives a tap at its centre.
bool _shown(WidgetTester t, Finder finder, Size size, {Rect? within}) {
  return _inside(t.getRect(finder), size, within) &&
      finder.hitTestable().evaluate().isNotEmpty;
}

bool _inside(Rect rect, Size size, Rect? within) {
  var area = Offset.zero & size;
  if (within != null) area = area.intersect(within);
  return rect.left >= area.left - 0.5 &&
      rect.top >= area.top - 0.5 &&
      rect.right <= area.right + 0.5 &&
      rect.bottom <= area.bottom + 0.5;
}

/// Where [finder] is painted on screen, including a transform such as a
/// floating label's scale.
Rect _painted(WidgetTester t, Finder finder) {
  final box = t.renderObject<RenderBox>(finder);
  return MatrixUtils.transformRect(
    box.getTransformTo(null),
    Offset.zero & box.size,
  );
}

/// The viewport of the scroll view that holds [finder], which clips it.
Rect _viewportOf(WidgetTester t, Finder finder) {
  final box =
      Scrollable.of(t.element(finder)).context.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Scroll [field] into view together with its floating [label], which is
/// painted above the field's top edge: revealing the field alone, flush
/// with the viewport's top, would cut the label off.
Future<void> _revealField(WidgetTester t, Finder field, Finder label) async {
  await _reveal(t, field);
  final viewport = _viewportOf(t, field);
  final top = math.min(_painted(t, label).top, t.getRect(field).top);
  if (top < viewport.top) {
    final position = Scrollable.of(t.element(field)).position;
    position.jumpTo(
      math.max(
        position.minScrollExtent,
        position.pixels - (viewport.top - top),
      ),
    );
    await t.pumpAndSettle();
  }
}

/// [field] and its whole [label] are painted inside their scroll viewport.
void _fieldShown(WidgetTester t, Finder field, Finder label, Size size) {
  final viewport = _viewportOf(t, field);
  for (final (what, rect) in [
    ('$field', t.getRect(field)),
    ('$label', _painted(t, label)),
  ]) {
    expect(
      _inside(rect, size, viewport),
      isTrue,
      reason: '$what $rect inside the viewport $viewport',
    );
  }
}

/// [finder]'s text is on one line and not cut short.
void _oneLine(WidgetTester t, Finder finder) {
  final paragraph = t.renderObject<RenderParagraph>(finder);
  expect(paragraph.didExceedMaxLines, isFalse, reason: '$finder is cut');
  final single = TextPainter(
    text: paragraph.text,
    textDirection: paragraph.textDirection,
    textScaler: paragraph.textScaler,
    maxLines: 1,
  )..layout();
  expect(
    paragraph.size.height,
    lessThanOrEqualTo(single.height + 0.5),
    reason: '$finder wraps',
  );
  expect(
    paragraph.size.width,
    greaterThanOrEqualTo(single.width - 0.5),
    reason: '$finder is narrower than its text',
  );
  single.dispose();
}

/// [finder] fits the screen width and is operable.
void _usable(WidgetTester t, Finder finder, Size size) {
  _withinWidth(t, finder, size);
  _operable(t, finder);
}

/// Scroll to [finder] and let the scroll settle.
Future<void> _reveal(WidgetTester t, Finder finder) async {
  await t.ensureVisible(finder);
  await t.pumpAndSettle();
}

/// The program and argument fields of the open ACP form, with [program] and
/// [firstArg], beside the Start action: one frame [name] when they fit
/// together, otherwise [name] for the program and `$name-args` for the
/// arguments.
Future<void> _captureProgram(
  WidgetTester t,
  Size size,
  String name, {
  required String program,
  required String firstArg,
  required AppLocalizations l10n,
  bool short = false,
}) async {
  final field = find.byKey(const Key('acp-program-field'));
  final browse = find.byKey(const Key('acp-program-browse'));
  final arg = find.byKey(const Key('acp-arg-field-0'));
  final start = find.byKey(const Key('start-hosting-btn'));
  expect(t.widget<TextField>(field).controller!.text, program);
  expect(t.widget<TextField>(arg).controller!.text, firstArg);
  final programLabel = find.descendant(
    of: field,
    matching: find.text(l10n.acpProgram),
  );
  final argLabel = find.descendant(
    of: arg,
    matching: find.text(l10n.acpArgumentLabel(1)),
  );
  await _revealField(t, arg, argLabel);
  await _revealField(t, field, programLabel);
  expect(t.takeException(), isNull, reason: 'no overflow');
  // Field labels are whole; a short program is entirely visible (a long
  // path scrolls inside its field as usual).
  _oneLine(t, programLabel);
  _oneLine(t, argLabel);
  _fieldShown(t, field, programLabel, size);
  expect(
    _inside(t.getRect(browse), size, _viewportOf(t, browse)),
    isTrue,
    reason: 'Browse inside the form viewport',
  );
  _oneLine(
    t,
    find.descendant(of: browse, matching: find.text(l10n.acpProgramBrowse)),
  );
  if (short) {
    final editable = t.widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );
    final value = TextPainter(
      text: TextSpan(text: program, style: editable.style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(t.element(field)),
      maxLines: 1,
    )..layout();
    expect(
      t
          .getSize(
            find.descendant(of: field, matching: find.byType(EditableText)),
          )
          .width,
      greaterThanOrEqualTo(value.width),
      reason: '"$program" fits its field',
    );
    value.dispose();
  }
  for (final control in [field, browse, start]) {
    _usable(t, control, size);
  }
  final viewport = _viewportOf(t, arg);
  if (_shown(t, arg, size, within: viewport) &&
      _inside(_painted(t, argLabel), size, viewport)) {
    _usable(t, arg, size);
    await capturePreview(t, name);
    return;
  }
  await capturePreview(t, name);
  await _revealField(t, arg, argLabel);
  _fieldShown(t, arg, argLabel, size);
  _usable(t, arg, size);
  _usable(t, start, size);
  await capturePreview(t, '$name-args');
}

/// The chip of [option] fits, is operable and announces `title: full`, with
/// the same text first in its tooltip.
void _chipShown(
  WidgetTester t,
  String option,
  String title,
  String full,
  Size size,
) {
  final chip = find.byKey(Key('agent-config-$option'));
  _usable(t, chip, size);
  // Entirely inside the options' own scroll viewport, which clips it.
  final viewport = t.getRect(find.byKey(const Key('agent-session-options')));
  final rect = t.getRect(chip);
  expect(
    rect.left >= viewport.left - 0.5 && rect.right <= viewport.right + 0.5,
    isTrue,
    reason: '$option chip $rect inside the options viewport $viewport',
  );
  expect(find.bySemanticsLabel('$title: $full'), findsOneWidget);
  final tooltip = t.widget<Tooltip>(
    find.descendant(of: chip, matching: find.byType(Tooltip)),
  );
  expect(tooltip.message, startsWith('$title: $full'));
}
