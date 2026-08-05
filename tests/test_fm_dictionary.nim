import std/[algorithm, random, sets, strutils]
import nbvs/fm_dictionary
import nbvs/internal/suffix_array
import nbvs/wavelet_matrix
import ./test_common

func naiveOccurrenceCount(value, pattern: string): uint32 =
  if pattern.len == 0:
    return uint32(value.len + 1)
  if pattern.len > value.len:
    return 0
  for start in 0..value.len - pattern.len:
    if value.continuesWith(pattern, start):
      inc result

proc naiveSuffixArray(symbols: openArray[FmSymbol]): seq[uint32] =
  var values = newSeq[FmSymbol](symbols.len)
  for index, symbol in symbols:
    values[index] = symbol
  result = newSeq[uint32](symbols.len)
  for index in 0..<symbols.len:
    result[index] = uint32(index)
  result.sort(proc(leftValue, rightValue: uint32): int =
    var left = int(leftValue)
    var right = int(rightValue)
    while left < values.len and right < values.len:
      if values[left] != values[right]:
        return cmp(values[left], values[right])
      inc left
      inc right
    cmp(values.len - left, values.len - right)
  )

block suffixArrayKnownCases:
  let cases = [
    @[EndSymbol],
    @[encodeByte(byte('a')), EndSymbol],
    @[encodeByte(byte('b')), encodeByte(byte('a')), encodeByte(byte('n')),
      encodeByte(byte('a')), encodeByte(byte('n')), encodeByte(byte('a')),
      EndSymbol],
    @[SeparatorSymbol, encodeByte(0), SeparatorSymbol, encodeByte(255),
      SeparatorSymbol, EndSymbol]]
  for symbols in cases:
    doAssert buildSuffixArray(symbols) == naiveSuffixArray(symbols)

block suffixArrayRandomNaiveComparison:
  var rng = initRand(0x53414953)
  for trial in 0..<2_000:
    let length = 1 + rng.rand(128)
    var symbols = newSeq[FmSymbol](length)
    for index in 0..<length - 1:
      symbols[index] = FmSymbol(1 + rng.rand(256))
    symbols[^1] = EndSymbol
    doAssert buildSuffixArray(symbols) == naiveSuffixArray(symbols)

block basic:
  let values = @["apple", "application", "banana", "hana"]
  let dict = genFmDictionary(values)
  doAssert dict.len == 4
  doAssert dict.bwt.bitWidth == SymbolBitWidth
  var bwtDisplay = ""
  for value in dict.bwt.items:
    let symbol = FmSymbol(value)
    case symbol
    of EndSymbol: bwtDisplay.add '$'
    of SeparatorSymbol: bwtDisplay.add '%'
    else: bwtDisplay.add char(decodeByte(symbol))
  # symbol仕様の `End < byte < Separator` 順で構築したBWTを検証する。
  doAssert bwtDisplay == "%bhn%%cnn%il%ltppaaaoippaaaa$ena"
  doAssert dict.findExact("apple") == 0
  doAssert dict.findExact("application") == 1
  doAssert dict.findExact("banana") == 2
  doAssert dict.findExact("hana") == 3
  doAssert dict.findExact("app") == -1
  doAssert dict.findExact("missing") == -1
  doAssert dict.contains("banana")
  doAssert not dict.contains("ban")
  doAssert dict.findPrefix("app") == @[0'u32, 1'u32]
  doAssert dict.findPrefix("") == @[0'u32, 1, 2, 3]
  doAssert dict.findSuffix("ana") == @[2'u32, 3'u32]
  doAssert dict.findSuffix("") == @[0'u32, 1, 2, 3]
  doAssert dict.findSubstring("ana") == @[2'u32, 3'u32]
  doAssert dict.findSubstringOccurrences("ana") == @[
    (id: 2'u32, occurrences: 2'u32),
    (id: 3'u32, occurrences: 1'u32)]
  for id, value in values:
    doAssert dict.getString(DictionaryId(id)) == value
  var decoded: seq[string]
  for value in dict.items:
    decoded.add value
  doAssert decoded == values
  expectRaises(IndexDefect): discard dict.getString(4)

block emptyDictionary:
  let dict = genFmDictionary(newSeq[string]())
  doAssert dict.len == 0
  doAssert dict.findExact("a") == -1
  doAssert dict.findPrefix("").len == 0
  doAssert dict.findSuffix("").len == 0
  doAssert dict.findSubstring("a").len == 0
  doAssert dict.findSubstringOccurrences("").len == 0

block emptyString:
  let dict = genFmDictionary(@["", "a"])
  doAssert dict.findExact("") == 0
  doAssert dict.findExact("a") == 1
  doAssert dict.getString(0) == ""
  doAssert dict.getString(1) == "a"
  doAssert dict.findSubstring("") == @[0'u32, 1]
  doAssert dict.findSubstringOccurrences("") == @[
    (id: 0'u32, occurrences: 1'u32),
    (id: 1'u32, occurrences: 2'u32)]

block duplicate:
  expectRaises(ValueError): discard genFmDictionary(@["a", "a"])

block utf8:
  let dict = genFmDictionary(@["東京", "東京都", "京都", "大阪"])
  doAssert dict.findExact("東京") == 0
  doAssert dict.findPrefix("東京") == @[0'u32, 1'u32]
  doAssert dict.findSubstring("京都") == @[1'u32, 2'u32]
  doAssert dict.getString(3) == "大阪"

block allBytes:
  var everyByte = newString(256)
  for index in 0..<256:
    everyByte[index] = char(index)
  let binaryNeedle = "\0\1"
  let dict = genFmDictionary(@[everyByte, binaryNeedle])
  doAssert dict.getString(0) == everyByte
  doAssert dict.getString(1) == binaryNeedle
  doAssert dict.findExact(everyByte) == 0
  doAssert dict.findSubstring(binaryNeedle) == @[0'u32, 1'u32]

block repeatedPattern:
  let dict = genFmDictionary(@["aaaaa", "aaa", "baaaab"])
  doAssert dict.findSubstring("aaa") == @[0'u32, 1, 2]
  doAssert dict.findSubstringOccurrences("aaa") == @[
    (id: 0'u32, occurrences: 3'u32),
    (id: 1'u32, occurrences: 1'u32),
    (id: 2'u32, occurrences: 2'u32)]

block packedBoundaries:
  var values: seq[string]
  for index in 0..<130:
    values.add "entry-" & $index
  let dict = genFmDictionary(values)
  for index, value in values:
    doAssert dict.findExact(value) == index
    doAssert dict.getString(DictionaryId(index)) == value

block lengthBoundaries:
  let values = @[repeat('a', 255), repeat('b', 256), repeat('c', 257)]
  let dict = genFmDictionary(values)
  for index, value in values:
    doAssert dict.findExact(value) == index
    doAssert dict.getString(DictionaryId(index)) == value

block randomNaiveComparison:
  var rng = initRand(0x464d4449)
  for trial in 0..<80:
    var values: seq[string]
    var used = initHashSet[string]()
    let valueCount = 1 + rng.rand(24)
    while values.len < valueCount:
      var value = newString(rng.rand(20))
      for character in value.mitems:
        character = char(rng.rand(7) + ord('a'))
      if value notin used:
        used.incl value
        values.add value
    let dict = genFmDictionary(values)
    for id, value in values:
      doAssert dict.findExact(value) == id
      doAssert dict.getString(DictionaryId(id)) == value
    for sample in 0..<40:
      var pattern = newString(rng.rand(6))
      for character in pattern.mitems:
        character = char(rng.rand(7) + ord('a'))
      var expectedPrefix, expectedSuffix, expectedSubstring: seq[DictionaryId]
      var expectedOccurrences: seq[tuple[id: DictionaryId, occurrences: uint32]]
      for id, value in values:
        if value.startsWith(pattern):
          expectedPrefix.add DictionaryId(id)
        if value.endsWith(pattern):
          expectedSuffix.add DictionaryId(id)
        let count = naiveOccurrenceCount(value, pattern)
        if count > 0:
          expectedSubstring.add DictionaryId(id)
          expectedOccurrences.add (id: DictionaryId(id), occurrences: count)
      doAssert dict.findPrefix(pattern) == expectedPrefix
      doAssert dict.findSuffix(pattern) == expectedSuffix
      doAssert dict.findSubstring(pattern) == expectedSubstring
      doAssert dict.findSubstringOccurrences(pattern) == expectedOccurrences

echo "OK test_fm_dictionary"
