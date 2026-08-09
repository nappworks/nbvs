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
    &"{float(restoreNs) / QueryIterations.float:.1f}," &
    &"{memory.totalBytes},{trieStats.nodeCount}," &
    &"{trieStats.averageEdgeLabelLength:.3f}," &
    &"{trieStats.averageTerminalDepth:.3f}"

proc run(count, averageLength, trials: int) =
  echo "distribution,count,sample_bytes,trial,build_ms,exact_hit_ns," &
    "exact_miss_ns,prefix_one_ns,restore_ns,trie_bytes,node_count," &
    "average_edge_label_bytes,average_terminal_depth"
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
