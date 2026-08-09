import std/[algorithm, monotimes, os, parseutils, strformat, strutils, times]
import nbvs
import nbvs/internal/[fm_symbols, suffix_array]

when defined(linux):
  import std/posix

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

proc peakRssKiB(): int64 =
  ## Linuxの `ru_maxrss` はKiB単位。非対応platformでは `-1` を返す。
  when defined(linux):
    var usage: Rusage
    if getrusage(RUSAGE_SELF, addr usage) == 0:
      return int64(usage.ru_maxrss)
  -1

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

proc dictionaryBytes(dict: FmDictionary): int64 =
  dict.memoryUsage.totalBytes

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
  let buildPeakRssKiB = peakRssKiB()

  var state = seed xor uint64(count) xor uint64(averageLength)
  var ids = newSeq[int](queryIterations)
  for id in ids.mitems:
    id = int(nextRandom(state) mod uint64(count))

  started = getMonoTime()
  for id in ids:
    sink = sink xor uint64(dict.findExact(values[id]))
  let radixExactNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    sink = sink xor uint64(dict.findExactFm(values[id]))
  let fmExactNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    sink = sink xor uint64(binaryFind(sortedValues, values[id]))
  let binaryNs = elapsedNs(started)

  started = getMonoTime()
  var prefixOutput: seq[DictionaryId]
  for id in ids:
    dict.findPrefixInto(values[id], prefixOutput)
    sink = sink xor uint64(prefixOutput.len)
  let radixPrefixNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    dict.findPrefixIntoFm(values[id], prefixOutput)
    sink = sink xor uint64(prefixOutput.len)
  let fmPrefixNs = elapsedNs(started)

  var workspace = initFmQueryWorkspace(dict)
  var substringOutput: seq[DictionaryId]
  started = getMonoTime()
  for id in ids:
    dict.findSubstringInto(values[id], workspace, substringOutput)
    sink = sink xor uint64(substringOutput.len)
  let substringNs = elapsedNs(started)

  var restored: string
  started = getMonoTime()
  for id in ids:
    dict.getStringInto(DictionaryId(id), restored)
    sink = sink xor uint64(restored.len)
  let radixRestoreNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    dict.getStringIntoFm(DictionaryId(id), restored)
    sink = sink xor uint64(restored.len)
  let fmRestoreNs = elapsedNs(started)

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
    let left = int64(id mod int(dict.bwt.n))
    let right = min(dict.bwt.n, left + 17)
    let value = uint64(id mod AlphabetSize)
    sink = sink xor uint64(dict.bwt.rank(value, left)) xor
      uint64(dict.bwt.rank(value, right))
  let rankTwiceNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    let left = int64(id mod int(dict.bwt.n))
    let right = min(dict.bwt.n, left + 17)
    let value = uint64(id mod AlphabetSize)
    let ranks = dict.bwt.rankPair(value, left, right)
    sink = sink xor uint64(ranks.leftRank) xor uint64(ranks.rightRank)
  let rankPairNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    sink = sink xor dict.cTable[int64(id mod AlphabetSize)]
  let checkedPackedNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    sink = sink xor dict.cTable.getUnchecked(id mod AlphabetSize)
  let uncheckedPackedNs = elapsedNs(started)

  let storage = dictionaryBytes(dict)
  let radixMemory = dict.radixTrie.memoryUsage
  let trieStats = dict.radixTrie.stats
  echo &"{count},{averageLength},{japanese},{symbols.len}," &
    &"{float(suffixArrayNs) / 1e6:.3f},{float(bwtNs) / 1e6:.3f}," &
    &"{float(waveletNs) / 1e6:.3f},{float(dictionaryNs) / 1e6:.3f}," &
    &"{float(radixExactNs) / queryIterations.float:.1f}," &
    &"{float(fmExactNs) / queryIterations.float:.1f}," &
    &"{float(binaryNs) / queryIterations.float:.1f}," &
    &"{float(radixPrefixNs) / queryIterations.float:.1f}," &
    &"{float(fmPrefixNs) / queryIterations.float:.1f}," &
    &"{float(substringNs) / queryIterations.float:.1f}," &
    &"{float(radixRestoreNs) / queryIterations.float:.1f}," &
    &"{float(fmRestoreNs) / queryIterations.float:.1f}," &
    &"{float(separateNs) / queryIterations.float:.1f}," &
    &"{float(fusedNs) / queryIterations.float:.1f}," &
    &"{float(rankTwiceNs) / queryIterations.float:.1f}," &
    &"{float(rankPairNs) / queryIterations.float:.1f}," &
    &"{float(checkedPackedNs) / queryIterations.float:.1f}," &
    &"{float(uncheckedPackedNs) / queryIterations.float:.1f}," &
    &"{float(storage) / 1024.0 / 1024.0:.3f}," &
    &"{float(storage) / float(totalCharacters):.3f},{buildPeakRssKiB}," &
    &"{radixMemory.totalBytes},{radixMemory.topologyBytes}," &
    &"{radixMemory.childNavigationBytes},{radixMemory.edgeFirstBytes}," &
    &"{radixMemory.edgeSuffixBytes},{radixMemory.edgeBoundaryBytes}," &
    &"{radixMemory.terminalBitsBytes},{radixMemory.terminalIdsBytes}," &
    &"{radixMemory.idToTerminalBytes},{radixMemory.terminalRangeBytes}," &
    &"{trieStats.nodeCount}," &
    &"{trieStats.edgeCount},{trieStats.terminalCount}," &
    &"{trieStats.internalNodeCount},{trieStats.leafRatio:.6f}," &
    &"{trieStats.suffixBearingEdgeCount}," &
    &"{trieStats.suffixBearingEdgeRatio:.6f}," &
    &"{trieStats.parentDeltaAverage:.3f}," &
    &"{trieStats.parentDeltaMedian:.3f},{trieStats.parentDeltaP90}," &
    &"{trieStats.parentDeltaP99},{trieStats.parentDeltaMaximum}," &
    &"{trieStats.terminalIdCorrelation:.6f}," &
    &"{trieStats.parentDeltaBitWidthHistogram[0]}," &
    &"{trieStats.parentDeltaBitWidthHistogram[1]}," &
    &"{trieStats.parentDeltaBitWidthHistogram[2]}," &
    &"{trieStats.parentDeltaBitWidthHistogram[3]}," &
    &"{trieStats.parentDeltaBitWidthHistogram[4]}," &
    &"{trieStats.suffixLengthHistogram[0]}," &
    &"{trieStats.suffixLengthHistogram[1]}," &
    &"{trieStats.suffixLengthHistogram[2]}," &
    &"{trieStats.suffixLengthHistogram[3]}," &
    &"{trieStats.suffixLengthHistogram[4]}," &
    &"{trieStats.averageEdgeLabelLength:.3f}," &
    &"{trieStats.maximumEdgeLabelLength}," &
    &"{trieStats.averageTerminalDepth:.3f},{trieStats.maximumDepth}," &
    &"{trieStats.degreeZeroCount},{trieStats.degreeOneCount}," &
    &"{trieStats.degreeTwoToFourCount},{trieStats.degreeFiveToSixteenCount}," &
    &"{trieStats.degreeSeventeenOrMoreCount}"

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
    "radix_exact_ns,fm_exact_ns,sorted_binary_exact_ns,radix_prefix_ns," &
    "fm_prefix_ns,substring_ns,radix_restore_ns,fm_restore_ns," &
    "access_plus_rank_ns,access_rank_ns,rank_twice_ns,rank_pair_ns," &
    "packed_checked_ns,packed_unchecked_ns," &
    "storage_mib,bytes_per_character,build_peak_rss_kib,radix_bytes,topology_bytes," &
    "child_navigation_bytes,edge_first_bytes,edge_suffix_bytes," &
    "edge_boundary_bytes,terminal_bits_bytes,terminal_ids_bytes," &
    "id_to_terminal_bytes,terminal_range_bytes,node_count,edge_count," &
    "terminal_count,internal_node_count,leaf_ratio,suffix_edge_count," &
    "suffix_edge_ratio,parent_delta_average,parent_delta_median," &
    "parent_delta_p90,parent_delta_p99,parent_delta_max," &
    "terminal_id_correlation," &
    "parent_delta_bits_1_4,parent_delta_bits_5_8," &
    "parent_delta_bits_9_12,parent_delta_bits_13_16," &
    "parent_delta_bits_17_plus,suffix_length_0,suffix_length_1_4," &
    "suffix_length_5_8,suffix_length_9_16,suffix_length_17_plus," &
    "average_edge_label_length,maximum_edge_label_length," &
    "average_terminal_depth,maximum_depth,degree_0,degree_1,degree_2_4," &
    "degree_5_16,degree_17_plus"
  run(count, averageLength, japanese)
  stderr.writeLine("sink=", sink)
