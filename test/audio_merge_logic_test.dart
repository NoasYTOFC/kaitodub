import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaitodub/audio_merge_logic.dart';

MergeAudioFile _audio(String name) =>
    MergeAudioFile.fromName(name: name, bytes: Uint8List.fromList([1, 2, 3]));

void main() {
  group('buildMergeAudioPlan', () {
    test('keeps base files and orders parts by their suffix', () {
      final plan = buildMergeAudioPlan(
        [
          _audio('same_dubbed.wav'),
          _audio('line_dubbed_p2.wav'),
          _audio('other_dubbed.wav'),
        ],
        [
          _audio('same_dubbed.wav'),
          _audio('extra_dubbed.wav'),
          _audio('line_dubbed_p1.wav'),
        ],
      );

      expect(plan.actions, hasLength(3));
      expect(plan.actions.first.type, MergeActionType.keepBase);
      expect(plan.actions.first.outputName, 'same_dubbed.wav');
      expect(
        plan.actions.map((action) => action.outputName),
        isNot(contains('extra_dubbed.wav')),
      );
      final sequence = plan.actions.last;
      expect(sequence.type, MergeActionType.sequential);
      expect(sequence.outputName, 'line_dubbed.wav');
      expect(sequence.first.part, DubPart.part1);
      expect(sequence.second?.part, DubPart.part2);
    });

    test('mixes matching both files from both archives', () {
      final plan = buildMergeAudioPlan(
        [_audio('line_dubbed_both.wav')],
        [_audio('line_dubbed_both.wav')],
      );

      expect(plan.actions, hasLength(1));
      expect(plan.actions.single.type, MergeActionType.overlap);
      expect(plan.actions.single.outputName, 'line_dubbed.wav');
    });

    test('ignores additions without a matching part and reports them', () {
      final plan = buildMergeAudioPlan([
        _audio('base.wav'),
        _audio('line_dubbed_p1.wav'),
      ], []);

      expect(plan.actions, hasLength(1));
      expect(plan.actions.single.outputName, 'base.wav');
      expect(plan.skippedGroups, 1);
    });

    test('rejects additions ZIPs with more audio files than the base', () {
      expect(
        () => buildMergeAudioPlan(
          [_audio('base.wav')],
          [_audio('one.wav'), _audio('two.wav')],
        ),
        throwsFormatException,
      );
    });
  });
}
