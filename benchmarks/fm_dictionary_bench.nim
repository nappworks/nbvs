import std/[algorithm, monotimes, os, parseutils, strformat, strutils, times]
import nbvs
import nbvs/internal/[fm_symbols, suffix_array]

const
  queryIterations = 10_000
  seed = 0x9e37_79b9_7f4a_7c15'u64

var sink {.volatile.}: uint64

func nextRandom(state: var uint64): uint64 =
  state += 0x9e37_79b9_7f4a_7c15'u64
  var value = state
  value = (value xor (value shr 30)) * 0xbf58_476d_1ce4_e5b9'u64
  value = (value xor (value shr 27)) * 0x94d0_49bb_1331_11eb'u64
  value xor (value shr 31)

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

proc makeValues(count, averageLength: int, japanese: bool): seq[string] =
  result = newSeq[string](count)
  for index in 0..<count:
    let identifier = $index
    let targetLength = max(identifier.len + 1, averageLength)
    if japanese:
      result[index] = "語" & identifier
      while result[index].len < targetLength:
        result[index].add "文"
    else:
      result[index] = "v"
      result[index].add repeat('a', targetLength - identifier.len - 1)
      result[index].add identifier

proc encodeCorpus(values: openArray[string]): seq[FmSymbol] =
  result.add SeparatorSymbol
  for value in values:
    result.add encodeString(value)
    result.add SeparatorSymbol
  result.add EndSymbol

proc buildBwtValues(symbols: openArray[FmSymbol],
                    suffixArray: openArray[uint32]): seq[uint64] =
  result = newSeq[uint64](symbols.len)
  for row, suffixStartValue in suffixArray:
    let suffixStart = int(suffixStartValue)
    let previous = if suffixStart == 0: symbols.high else: suffixStart - 1
    result[row] = uint64(symbols[previous])

proc sbvBytes(values: SuccinctBitVector): int64 =
  result += int64(values.data.len) * 8
  result += int64(values.blockPairPrefix.len) * 4
  result += int64(values.wordPairPrefix.len) * 4
  result += int64(values.selectStorage.len) * 8

proc dictionaryBytes(dict: FmDictionary): int64 =
  for level in dict.bwt.levels:
    result += sbvBytes(level)
  result += int64(dict.bwt.zeroCounts.len) * 8
  result += int64(dict.cTable.data.len) * 8
  result += int64(dict.startAnchorToEncodedId.data.len) * 8
  result += int64(dict.dictionaryIdToEndAnchor.data.len) * 8

proc binaryFind(values: openArray[string], value: string): int =
  var left = 0
  var right = values.len
  while left < right:
    let middle = (left + right) shr 1
    if values[middle] < value:
      left = middle + 1
    else:
      right = middle
  if left < values.len and values[left] == value: left else: -1

proc run(count, averageLength: int, japanese: bool) =
  let values = makeValues(count, averageLength, japanese)
  var sortedValues = values
  sortedValues.sort()
  var totalCharacters = 0
  for value in values:
    totalCharacters += value.len

  let symbols = encodeCorpus(values)
  var started = getMonoTime()
  let suffixArray = buildSuffixArray(symbols)
  let suffixArrayNs = elapsedNs(started)

  started = getMonoTime()
  let bwtValues = buildBwtValues(symbols, suffixArray)
  let bwtNs = elapsedNs(started)

  started = getMonoTime()
  let standaloneWm = genWaveletMatrix(bwtValues, SymbolBitWidth)
  let waveletNs = elapsedNs(started)
  sink = sink xor uint64(standaloneWm.n)

  started = getMonoTime()
  let dict = genFmDictionary(values)
  let dictionaryNs = elapsedNs(started)

  var state = seed xor uint64(count) xor uint64(averageLength)
  var ids = newSeq[int](queryIterations)
  for id in ids.mitems:
    id = int(nextRandom(state) mod uint64(count))

  started = getMonoTime()
  for id in ids:
    sink = sink xor uint64(dict.findExact(values[id]))
  let exactNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    sink = sink xor uint64(binaryFind(sortedValues, values[id]))
  let binaryNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    sink = sink xor uint64(dict.findPrefix(values[id]).len)
  let prefixNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    sink = sink xor uint64(dict.findSubstring(values[id]).len)
  let substringNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    sink = sink xor uint64(dict.getString(DictionaryId(id)).len)
  let restoreNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    let row = int64(id mod int(dict.bwt.n))
    let value = dict.bwt.access(row)
    sink = sink xor value xor uint64(dict.bwt.rank(value, row))
  let separateNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    let item = dict.bwt.accessRank(int64(id mod int(dict.bwt.n)))
    sink = sink xor item.value xor uint64(item.rankBefore)
  let fusedNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    sink = sink xor dict.cTable[int64(id mod AlphabetSize)]
  let checkedPackedNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    sink = sink xor dict.cTable.getUnchecked(id mod AlphabetSize)
  let uncheckedPackedNs = elapsedNs(started)

  let storage = dictionaryBytes(dict)
  echo &"{count},{averageLength},{japanese},{symbols.len}," &
    &"{float(suffixArrayNs) / 1e6:.3f},{float(bwtNs) / 1e6:.3f}," &
    &"{float(waveletNs) / 1e6:.3f},{float(dictionaryNs) / 1e6:.3f}," &
    &"{float(exactNs) / queryIterations.float:.1f}," &
    &"{float(binaryNs) / queryIterations.float:.1f}," &
    &"{float(prefixNs) / queryIterations.float:.1f}," &
    &"{float(substringNs) / queryIterations.float:.1f}," &
    &"{float(restoreNs) / queryIterations.float:.1f}," &
    &"{float(separateNs) / queryIterations.float:.1f}," &
    &"{float(fusedNs) / queryIterations.float:.1f}," &
    &"{float(checkedPackedNs) / queryIterations.float:.1f}," &
    &"{float(uncheckedPackedNs) / queryIterations.float:.1f}," &
    &"{float(storage) / 1024.0 / 1024.0:.3f}," &
    &"{float(storage) / float(totalCharacters):.3f}"

when isMainModule:
  var count = 10_000
  var averageLength = 16
  var japanese = false
  if paramCount() >= 1:
    discard parseInt(paramStr(1), count)
  if paramCount() >= 2:
    discard parseInt(paramStr(2), averageLength)
  if paramCount() >= 3:
    japanese = paramStr(3) == "ja"
  if count <= 0 or averageLength <= 0:
    raise newException(ValueError, "count and averageLength must be positive")
  echo "count,avg_bytes,japanese,symbols,sa_ms,bwt_ms,wm_ms,fm_build_ms," &
    "fm_exact_ns,sorted_binary_exact_ns,prefix_ns,substring_ns,restore_ns," &
    "access_plus_rank_ns,access_rank_ns,packed_checked_ns,packed_unchecked_ns," &
    "storage_mib,bytes_per_character"
  run(count, averageLength, japanese)
  stderr.writeLine("sink=", sink)
