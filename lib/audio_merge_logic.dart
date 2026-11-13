import 'dart:typed_data';

import 'package:path/path.dart' as p;

enum DubPart {
  part1('p1', 'Parte 1'),
  part2('p2', 'Parte 2'),
  both('both', 'Ambas');

  const DubPart(this.suffix, this.label);

  final String suffix;
  final String label;
}

DubPart? dubPartFromName(String? value) => switch (value) {
  'part1' => DubPart.part1,
  'part2' => DubPart.part2,
  'both' => DubPart.both,
  _ => null,
};

class MergeAudioFile {
  factory MergeAudioFile.fromName({
    required String name,
    required Uint8List bytes,
  }) {
    final fileName = p.basename(name);
    final stem = p.basenameWithoutExtension(fileName);
    final match = RegExp(
      r'_(p1|p2|both)$',
      caseSensitive: false,
    ).firstMatch(stem);
    if (match == null) {
      return MergeAudioFile._(
        name: fileName,
        outputName: fileName,
        bytes: bytes,
      );
    }

    final part = switch (match.group(1)!.toLowerCase()) {
      'p1' => DubPart.part1,
      'p2' => DubPart.part2,
      'both' => DubPart.both,
      _ => throw StateError('Marcador de parte não reconhecido.'),
    };
    final outputStem = stem.substring(0, match.start);
    return MergeAudioFile._(
      name: fileName,
      outputName: '$outputStem.wav',
      bytes: bytes,
      part: part,
    );
  }

  const MergeAudioFile._({
    required this.name,
    required this.outputName,
    required this.bytes,
    this.part,
  });

  final String name;
  final String outputName;
  final Uint8List bytes;
  final DubPart? part;
}

enum MergeActionType { keepBase, sequential, overlap }

class MergeAudioAction {
  const MergeAudioAction({
    required this.type,
    required this.outputName,
    required this.first,
    this.second,
  });

  final MergeActionType type;
  final String outputName;
  final MergeAudioFile first;
  final MergeAudioFile? second;
}

class MergeAudioPlan {
  const MergeAudioPlan({
    required this.actions,
    required this.skippedGroups,
    required this.duplicateParts,
  });

  final List<MergeAudioAction> actions;
  final int skippedGroups;
  final int duplicateParts;
}

class _MergeAudioGroup {
  _MergeAudioGroup(this.outputName);

  final String outputName;
  final Map<DubPart, MergeAudioFile> base = {};
  final Map<DubPart, MergeAudioFile> additions = {};
}

MergeAudioPlan buildMergeAudioPlan(
  List<MergeAudioFile> base,
  List<MergeAudioFile> additions,
) {
  if (base.isEmpty) {
    throw const FormatException('O ZIP base não contém arquivos de áudio.');
  }
  if (additions.length > base.length) {
    throw const FormatException(
      'O ZIP de adições não pode ter mais áudios que o ZIP base.',
    );
  }

  final actions = <MergeAudioAction>[];
  final outputNames = <String>{};
  final groups = <String, _MergeAudioGroup>{};
  var duplicateParts = 0;
  var skippedGroups = 0;

  for (final entry in base.where((entry) => entry.part == null)) {
    final key = entry.name.toLowerCase();
    if (!outputNames.add(key)) continue;
    actions.add(
      MergeAudioAction(
        type: MergeActionType.keepBase,
        outputName: entry.name,
        first: entry,
      ),
    );
  }

  void addTaggedEntries(
    Iterable<MergeAudioFile> entries, {
    required bool fromBase,
  }) {
    for (final entry in entries.where((entry) => entry.part != null)) {
      final key = entry.outputName.toLowerCase();
      final group = groups.putIfAbsent(
        key,
        () => _MergeAudioGroup(entry.outputName),
      );
      final target = fromBase ? group.base : group.additions;
      if (target.containsKey(entry.part)) {
        duplicateParts++;
      } else {
        target[entry.part!] = entry;
      }
    }
  }

  addTaggedEntries(base, fromBase: true);
  addTaggedEntries(additions, fromBase: false);

  for (final group in groups.values) {
    final key = group.outputName.toLowerCase();
    if (outputNames.contains(key)) {
      skippedGroups++;
      continue;
    }

    final hasBoth =
        group.base.containsKey(DubPart.both) ||
        group.additions.containsKey(DubPart.both);
    final hasParts =
        group.base.containsKey(DubPart.part1) ||
        group.base.containsKey(DubPart.part2) ||
        group.additions.containsKey(DubPart.part1) ||
        group.additions.containsKey(DubPart.part2);
    if (hasBoth && hasParts) {
      skippedGroups++;
      continue;
    }

    if (hasBoth) {
      final baseBoth = group.base[DubPart.both];
      final additionsBoth = group.additions[DubPart.both];
      if (baseBoth == null || additionsBoth == null) {
        skippedGroups++;
        continue;
      }
      actions.add(
        MergeAudioAction(
          type: MergeActionType.overlap,
          outputName: group.outputName,
          first: baseBoth,
          second: additionsBoth,
        ),
      );
      outputNames.add(key);
      continue;
    }

    final part1 = group.base[DubPart.part1] ?? group.additions[DubPart.part1];
    final part2 = group.base[DubPart.part2] ?? group.additions[DubPart.part2];
    if (part1 == null || part2 == null) {
      skippedGroups++;
      continue;
    }
    actions.add(
      MergeAudioAction(
        type: MergeActionType.sequential,
        outputName: group.outputName,
        first: part1,
        second: part2,
      ),
    );
    outputNames.add(key);
  }

  if (actions.isEmpty) {
    throw const FormatException(
      'Nenhum áudio válido foi encontrado para exportar.',
    );
  }
  return MergeAudioPlan(
    actions: actions,
    skippedGroups: skippedGroups,
    duplicateParts: duplicateParts,
  );
}
