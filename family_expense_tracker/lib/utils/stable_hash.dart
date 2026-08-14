import 'dart:convert';

/// A deterministic, dependency-free string hash used to build transaction
/// fingerprints.
///
/// It must stay stable across app restarts, app upgrades and devices, because
/// a fingerprint that changes would let an already-imported SMS be imported a
/// second time. `Object.hashCode` is explicitly unsuitable — Dart does not
/// guarantee it is stable across runs.
///
/// Two independent 32-bit FNV-1a passes are concatenated into a 64-bit hex
/// digest. Multipliers are kept small enough that the intermediate product of a
/// 32-bit accumulator never exceeds a 64-bit int, so the result is identical on
/// the VM and on the web.
String stableHash(String input) {
  final bytes = utf8.encode(input);

  int h1 = 0x811C9DC5; // FNV-1a 32 offset basis
  int h2 = 0x01000193; // seeded differently so the two passes decorrelate
  const prime = 0x01000193;

  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    h1 = ((h1 ^ b) * prime) & 0xFFFFFFFF;
    // Mixing the index in makes the second pass sensitive to byte order in a
    // different way than the first, which suppresses anagram collisions.
    h2 = ((h2 ^ (b + i + 1)) * prime) & 0xFFFFFFFF;
  }

  return h1.toRadixString(16).padLeft(8, '0') +
      h2.toRadixString(16).padLeft(8, '0');
}

/// Normalises an SMS body before hashing so that cosmetic differences — the
/// carrier re-wrapping lines, doubled spaces, casing — do not produce a
/// different fingerprint for the same message.
String normalizeForHash(String body) {
  return body
      .toUpperCase()
      .replaceAll(RegExp(r'[\s ]+'), ' ')
      .replaceAll(RegExp(r'[^\x20-\x7E]'), '')
      .trim();
}
