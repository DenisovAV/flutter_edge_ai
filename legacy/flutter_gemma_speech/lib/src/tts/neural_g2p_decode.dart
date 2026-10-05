library;

import 'dart:typed_data';

Float32List encodeG2pInput(
  String word,
  Map<String, int> char2idx, {
  int charRepeats = 3,
  int start = 1,
  int end = 2,
  int maxT = 96,
}) {
  final ids = <int>[start];
  for (final ch in word.split('')) {
    final id = char2idx[ch];
    if (id == null) {
      throw StateError('neural G2P: char "$ch" not in char2idx (word "$word")');
    }
    for (var r = 0; r < charRepeats; r++) {
      ids.add(id);
    }
  }
  ids.add(end);
  if (ids.length > maxT) {
    throw StateError(
      'neural G2P encode: word "$word" frames to ${ids.length} ids '
      '> maxT $maxT',
    );
  }
  final out = Float32List(maxT);
  for (var i = 0; i < ids.length; i++) {
    out[i] = ids[i].toDouble();
  }
  return out;
}

String decodeG2pOutput(
  List<int> argmax,
  Map<int, String> idx2ph, {
  int end = 2,
  Set<String> specials = const {'_', '<en_us>', '<end>', '<start>'},
  Set<String> lossy = const {'̃', '̍', '̥', '̯', '͡'},
}) {
  var stop = argmax.indexOf(end);
  if (stop < 0) stop = argmax.length;
  final sb = StringBuffer();
  int? prev;
  for (var i = 0; i < stop; i++) {
    final id = argmax[i];
    if (id != prev) {
      final ph = idx2ph[id];
      if (ph == null) {
        throw StateError(
          'neural G2P decode: argmax id $id has no idx2ph entry '
          '(n_phonemes/idx2ph mismatch in g2p_meta.json)',
        );
      }
      if (!specials.contains(ph) && ph != '_' && !lossy.contains(ph)) {
        sb.write(ph);
      }
    }
    prev = id;
  }
  return sb.toString();
}
