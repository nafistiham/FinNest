import 'package:bhorosha/app/theme/theme.dart';
import 'package:bhorosha/app/widgets/feature_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../theme_harness.dart';

Widget _grid(List<String> labels) => Padding(
  padding: const EdgeInsets.all(16),
  child: FeatureGrid(
    children: [
      for (final (i, l) in labels.indexed)
        FeatureTile(
          key: ValueKey('tile_$i'),
          icon: Icons.send,
          label: l,
          onTap: () {},
        ),
    ],
  ),
);

void main() {
  for (final width in [360.0, 412.0]) {
    for (final (locale, labels) in [
      ('bn', ['টাকা পাঠান', 'মোবাইল রিচার্জ', 'বিল']),
      ('en', ['Send money', 'Mobile recharge', 'Bill']),
    ]) {
      testWidgets('icon and label centred as one block in the tile, for '
          '1- and 2-line labels ($locale, ${width.toInt()} dp)', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width * 3, 800 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          themedApp(_grid(labels), locale: Locale(locale)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final lines = <int>{};
        final widths = <double>{};
        for (var i = 0; i < labels.length; i++) {
          final tile = tester.getRect(find.byKey(ValueKey('tile_$i')));
          final well = tester.getRect(
            find.descendant(
              of: find.byKey(ValueKey('tile_$i')),
              matching: find.byKey(FeatureTile.wellKey),
            ),
          );
          final label = tester.getRect(
            find.descendant(
              of: find.byKey(ValueKey('tile_$i')),
              matching: find.text(labels[i]),
            ),
          );
          expect(
            well.center.dx,
            moreOrLessEquals(tile.center.dx, epsilon: 0.5),
          );
          expect(
            label.center.dx,
            moreOrLessEquals(tile.center.dx, epsilon: 0.5),
          );
          expect(tile.height, FeatureTile.heightFor(1));
          expect(tile.height, BhSize.tile);
          final above = well.top - tile.top;
          final below = tile.bottom - label.bottom;
          expect(above, greaterThan(0));
          expect(
            (above - below).abs(),
            lessThanOrEqualTo(1),
            reason: '"${labels[i]}": $above dp above, $below dp below',
          );
          lines.add(
            (label.height / (FeatureTile.labelSize * FeatureTile.labelHeight))
                .round(),
          );
          widths.add(tile.width.roundToDouble());
        }
        // The row holds a one-line and a two-line label; every tile has the
        // same width.
        expect(lines, containsAll(<int>[1, 2]));
        expect(widths, hasLength(1));
      });
    }
  }

  testWidgets('a two-line label is centred under its icon', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(_grid(['মোবাইল রিচার্জ'])));
    await tester.pumpAndSettle();
    final text = tester.widget<Text>(find.text('মোবাইল রিচার্জ'));
    expect(text.textAlign, TextAlign.center);
    expect(text.maxLines, 2);
  });

  testWidgets('the tile stays 100 dp at scale 1 with a 44 dp well and a '
      '14 sp label; a one-line label is centred, not top-aligned', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(_grid(['বিল', 'মোবাইল রিচার্জ'])));
    await tester.pumpAndSettle();
    expect(FeatureTile.heightFor(1), BhSize.tile);
    final tile = tester.getRect(find.byKey(const ValueKey('tile_0')));
    final well = tester.getRect(find.byKey(FeatureTile.wellKey).first);
    final labelRect = tester.getRect(find.text('বিল'));
    expect(well.width, FeatureTile.wellSize);
    expect(labelRect.top - well.bottom, closeTo(FeatureTile.gap, 0.01));
    // One line leaves more slack than two, so the well sits lower than the
    // fixed top padding.
    expect(well.top - tile.top, greaterThan(FeatureTile.padding));
    final above = well.top - tile.top;
    final below = tile.bottom - labelRect.bottom;
    expect((above - below).abs(), lessThanOrEqualTo(1));
    final label = tester.widget<Text>(find.text('বিল'));
    expect(label.style?.fontSize, FeatureTile.labelSize);
    // Close to square: 100 tall for a 110-121 dp wide column.
    expect(tile.height, BhSize.tile);
    expect(tile.width / tile.height, closeTo(1.15, 0.1));
  });

  testWidgets('large text: the label scales up to 1.15x and the tile grows '
      'with it instead of clipping', (tester) async {
    tester.view.physicalSize = const Size(412 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      themedApp(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: _grid(['টাকা পাঠান', 'মোবাইল রিচার্জ']),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final tile = tester.getSize(find.byKey(const ValueKey('tile_0')));
    expect(tile.height, closeTo(FeatureTile.heightFor(1.15), 0.01));
    expect(tile.height, greaterThan(BhSize.tile));
    final label = tester.widget<Text>(find.text('টাকা পাঠান'));
    expect(label.textScaler, const TextScaler.linear(1.15));
  });

  for (final b in Brightness.values) {
    testWidgets('the grid keeps each tile\'s tone: cash-in (success) and send '
        '(primary) wells differ (${b.name})', (tester) async {
      await tester.pumpWidget(
        themedApp(
          Padding(
            padding: const EdgeInsets.all(16),
            child: FeatureGrid(
              children: [
                FeatureTile(
                  key: const ValueKey('send'),
                  icon: Icons.send,
                  label: 'Send',
                  onTap: () {},
                ),
                FeatureTile(
                  key: const ValueKey('cashin'),
                  icon: Icons.add,
                  label: 'Cash in',
                  tone: FeatureTone.success,
                  onTap: () {},
                ),
              ],
            ),
          ),
          brightness: b,
        ),
      );
      await tester.pumpAndSettle();
      Color well(String k) => tester
          .widget<Container>(
            find.descendant(
              of: find.byKey(ValueKey(k)),
              matching: find.byKey(FeatureTile.wellKey),
            ),
          )
          .color!;
      Color icon(String k) => tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(ValueKey(k)),
              matching: find.byType(Icon),
            ),
          )
          .color!;
      expect(well('cashin'), isNot(well('send')));
      expect(icon('cashin'), isNot(icon('send')));
    });
  }
}
