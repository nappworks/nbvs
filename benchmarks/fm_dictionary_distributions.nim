## FmDictionaryを複数の文字列分布で反復測定します。

import std/[monotimes, os, parseutils, strformat, strutils, times]
import nbvs

const
  QueryIterations = 10_000
  Seed = 0x7261_6469_785f_6265'u64

type CorpusKind = enum
  randomBytes = "random"
  commonPrefix = "common-prefix"
  urlPath = "url-path"
  codeSymbol = "code-symbol"
  naturalName = "natural-name"

var sink {.volatile.}: uint64

func nextRandom(state: var uint64): uint64 =
  state += 0x9e37_79b9_7f4a_7c15'u64
  var value = state
  value = (value xor (value shr 30)) * 0xbf58_476d_1ce4_e5b9'u64
  value = (value xor (value shr 27)) * 0x94d0_49bb_1331_11eb'u64
  value xor (value shr 31)

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

func padTo(value: string, targetLength: int, padding: char): string =
  result = value
  if result.len < targetLength:
    result.add repeat(padding, targetLength - result.len)

proc makeCorpus(kind: CorpusKind, count, averageLength: int): seq[string] =
  result = newSeq[string](count)
  var state = Seed xor uint64(ord(kind)) xor uint64(count)
  for index in 0..<count:
    let identifier = toHex(index, 8)
    case kind
    of randomBytes:
      var value = newString(max(0, averageLength - identifier.len - 1))
      for character in value.mitems:
        character = char(ord('a') + int(nextRandom(state) mod 26))
      result[index] = value & "-" & identifier
    of commonPrefix:
      result[index] = padTo("shared/catalog/", max(0,
        averageLength - identifier.len), 'x') & identifier
    of urlPath:
      result[index] = padTo("/api/v1/tenant/" & $(index mod 97) & "/item/",
        max(0, averageLength - identifier.len), '/') & identifier
    of codeSymbol:
      result[index] = padTo("Nbvs::Radix::Node" & $(index mod 31) & "::",
        max(0, averageLength - identifier.len), '_') & identifier
    of naturalName:
      result[index] = padTo("東京データ" & $(index mod 53) & "-",
        max(0, averageLength - identifier.len), 'x') & identifier

proc nodeString(trie: SuccinctRadixTrie, initialNode: int): string =
  var node = initialNode
  var length = 0
  while node != 0:
    let suffix = trie.edgeSuffixRange(node)
    length += 1 + suffix.last - suffix.first
    node = trie.parentAt(node)
  result.setLen(length)
  var writePosition = length
  node = initialNode
  while node != 0:
    let suffix = trie.edgeSuffixRange(node)
    let edgeLength = 1 + suffix.last - suffix.first
    writePosition -= edgeLength
    result[writePosition] = char(trie.edgeFirstBytes[node])
    for offset in 0..<suffix.last - suffix.first:
      result[writePosition + offset + 1] =
        char(trie.edgeSuffixBytes[suffix.first + offset])
    node = trie.parentAt(node)

proc prefixNear(trie: SuccinctRadixTrie, targetCount: int): string =
  var bestNode = 0
  var bestDistance = int.high
  for node in 0..<trie.edgeFirstBytes.len:
    if not trie.internalBits.access(int64(node)):
      continue
    let internal = int(trie.internalBits.rank1Unchecked(int64(node)))
    let terminalCount = int(trie.internalTerminalCount.getUnchecked(internal))
    let distance = abs(terminalCount - targetCount)
    if distance < bestDistance:
      bestNode = node
      bestDistance = distance
  trie.nodeString(bestNode)

proc runTrial(kind: CorpusKind, values: openArray[string], trial: int) =
  var started = getMonoTime()
  let dict = genFmDictionary(values)
  let buildNs = elapsedNs(started)

  var state = Seed xor uint64(trial) xor uint64(ord(kind))
  var ids = newSeq[int](QueryIterations)
  for id in ids.mitems:
    id = int(nextRandom(state) mod uint64(values.len))

  # 最初の走査をwarm-upとして測定対象外にする。
  for id in ids:
    sink = sink xor uint64(dict.findExact(values[id]))

  started = getMonoTime()
  for id in ids:
    sink = sink xor uint64(dict.findExact(values[id]))
  let exactHitNs = elapsedNs(started)

  started = getMonoTime()
  for id in ids:
    sink = sink xor uint64(dict.findExact(values[id] & "\xFF"))
  let exactMissNs = elapsedNs(started)

  var prefixOutput: seq[DictionaryId]
  started = getMonoTime()
  for id in ids:
    dict.findPrefixInto(values[id], prefixOutput)
    sink = sink xor uint64(prefixOutput.len)
  let prefixNs = elapsedNs(started)

  var prefixGroupNs: array[8, float]
  var prefixWorkspace = initPrefixQueryWorkspace(dict)
  let prefixTargets = [1, 10, 100, 1_000, 10_000, 100_000, 500_000,
    values.len]
  for index, targetCount in prefixTargets:
    let prefix = dict.radixTrie.prefixNear(targetCount)
    let iterations = max(1, min(QueryIterations,
      10_000_000 div max(1, min(targetCount, values.len))))
    started = getMonoTime()
    for _ in 0..<iterations:
      dict.findPrefixInto(prefix, prefixWorkspace, prefixOutput)
      sink = sink xor uint64(prefixOutput.len)
    prefixGroupNs[index] = float(elapsedNs(started)) / iterations.float

  var restored: string
  started = getMonoTime()
  for id in ids:
    dict.getStringInto(DictionaryId(id), restored)
    sink = sink xor uint64(restored.len)
  let restoreNs = elapsedNs(started)

  let memory = dict.radixTrie.memoryUsage
  let trieStats = dict.radixTrie.stats
  echo &"{kind},{values.len},{values[0].len},{trial}," &
    &"{float(buildNs) / 1e6:.3f}," &
    &"{float(exactHitNs) / QueryIterations.float:.1f}," &
    &"{float(exactMissNs) / QueryIterations.float:.1f}," &
    &"{float(prefixNs) / QueryIterations.float:.1f}," &
    &"{prefixGroupNs[0]:.1f},{prefixGroupNs[1]:.1f}," &
    &"{prefixGroupNs[2]:.1f},{prefixGroupNs[3]:.1f}," &
    &"{prefixGroupNs[4]:.1f},{prefixGroupNs[5]:.1f}," &
    &"{prefixGroupNs[6]:.1f},{prefixGroupNs[7]:.1f}," &
    &"{float(restoreNs) / QueryIterations.float:.1f}," &
    &"{memory.totalBytes},{trieStats.nodeCount}," &
    &"{trieStats.averageEdgeLabelLength:.3f}," &
    &"{trieStats.averageTerminalDepth:.3f}," &
    &"{trieStats.internalNodeCount},{trieStats.leafRatio:.6f}," &
    &"{trieStats.suffixBearingEdgeRatio:.6f}," &
    &"{trieStats.parentDeltaMedian:.3f},{trieStats.parentDeltaP99}," &
    &"{trieStats.terminalIdCorrelation:.6f}"

proc run(count, averageLength, trials: int) =
  echo "distribution,count,sample_bytes,trial,build_ms,exact_hit_ns," &
    "exact_miss_ns,prefix_one_ns,prefix_near_1_ns,prefix_near_10_ns," &
    "prefix_near_100_ns,prefix_near_1000_ns,prefix_near_10000_ns," &
    "prefix_near_100000_ns,prefix_near_500000_ns,prefix_all_ns," &
    "restore_ns,trie_bytes,node_count," &
    "average_edge_label_bytes,average_terminal_depth,internal_node_count," &
    "leaf_ratio,suffix_edge_ratio,parent_delta_median,parent_delta_p99," &
    "terminal_id_correlation"
  for kind in CorpusKind:
    let values = makeCorpus(kind, count, averageLength)
    for trial in 1..trials:
      runTrial(kind, values, trial)

when isMainModule:
  var count = 10_000
  var averageLength = 16
  var trials = 5
  if paramCount() >= 1:
    discard parseInt(paramStr(1), count)
  if paramCount() >= 2:
    discard parseInt(paramStr(2), averageLength)
  if paramCount() >= 3:
    discard parseInt(paramStr(3), trials)
  if count <= 0 or averageLength <= 0 or trials <= 0:
    raise newException(ValueError,
      "count, averageLength and trials must be positive")
  run(count, averageLength, trials)
  stderr.writeLine("sink=", sink)
