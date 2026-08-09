## rev3向けFM backend、BWT run、prefix materialization benchmark。

import std/[monotimes, os, parseutils, strformat, strutils, times]
import nbvs

const
  Seed = 0x666d_7265_7633_2026'u64
  QueryIterations = 100

type CorpusKind = enum
  ckRandom = "random"
  ckCommonPrefix = "common-prefix"
  ckUrlPath = "url-path"
  ckCodeSymbol = "code-symbol"
  ckNaturalName = "natural-name-like"
  ckHighlyRepetitive = "highly-repetitive"
  ckLowRepetitive = "low-repetitive"
  ckSortedNeighbor = "sorted-neighbor-like"
  ckUuid = "uuid-random-identifier"
  ckLogMessage = "log-message-like"

var sink {.volatile.}: uint64

func nextRandom(state: var uint64): uint64 =
  state += 0x9e37_79b9_7f4a_7c15'u64
  var value = state
  value = (value xor (value shr 30)) * 0xbf58_476d_1ce4_e5b9'u64
  value = (value xor (value shr 27)) * 0x94d0_49bb_1331_11eb'u64
  value xor (value shr 31)

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

func fit(value: string, targetLength: int, padding: char): string =
  result = value
  if result.len < targetLength:
    result.add repeat(padding, targetLength - result.len)

proc makeCorpus(kind: CorpusKind, count, averageLength: int): seq[string] =
  result = newSeq[string](count)
  var state = Seed xor uint64(ord(kind)) xor uint64(count) xor
    uint64(averageLength)
  for index in 0..<count:
    let id = toHex(index, 8)
    case kind
    of ckRandom, ckLowRepetitive:
      var prefix = newString(max(1, averageLength - id.len - 1))
      for character in prefix.mitems:
        character = char(ord('a') + int(nextRandom(state) mod
          (if kind == ckRandom: 26'u64 else: 6'u64)))
      result[index] = prefix & "-" & id
    of ckCommonPrefix:
      result[index] = fit("shared/catalog/", averageLength - id.len, 'x') & id
    of ckUrlPath:
      result[index] = fit("/api/v3/tenant/" & $(index mod 97) & "/item/",
        averageLength - id.len, '/') & id
    of ckCodeSymbol:
      result[index] = fit("Nbvs::Index::Node" & $(index mod 31) & "::",
        averageLength - id.len, '_') & id
    of ckNaturalName:
      result[index] = fit("東京データ" & $(index mod 53) & "-",
        averageLength - id.len, 'x') & id
    of ckHighlyRepetitive:
      result[index] = fit("aaaaaaaa", averageLength - id.len, 'a') & id
    of ckSortedNeighbor:
      result[index] = fit("neighbor-" & toHex(index div 100, 8) & "-",
        averageLength - id.len, 'n') & id
    of ckUuid:
      result[index] = toHex(nextRandom(state), 16) & "-" &
        toHex(nextRandom(state), 16) & "-" & id
    of ckLogMessage:
      result[index] = fit("INFO service=" & $(index mod 17) &
        " request=/v1/items/ status=200 id=", averageLength - id.len, ' ') & id

proc measure(kind: CorpusKind, values: seq[string], averageLength: int,
             preference: FmBackendPreference) =
  var started = getMonoTime()
  let dict = genFmDictionary(values, FmDictionaryBuildOptions(
    validateDistinct: true, fmBackend: preference))
  let buildNs = elapsedNs(started)
  let dictionaryStats = dict.stats
  let memory = dict.memoryUsage

  let sample = values[values.len div 2]
  # ID由来の末尾8 byteを使い、件数matrixでも概ね1-hitの選択性を維持する。
  let queryStart = max(0, sample.len - min(8, sample.len))
  let suffix = sample[queryStart..^1]
  let substring = suffix
  started = getMonoTime()
  for _ in 0..<QueryIterations:
    sink = sink xor uint64(dict.findSuffix(suffix).len)
  let suffixNs = elapsedNs(started)
  started = getMonoTime()
  for _ in 0..<QueryIterations:
    sink = sink xor uint64(dict.findSubstring(substring).len)
  let substringNs = elapsedNs(started)

  echo &"{kind},{values.len},{averageLength},{preference}," &
    &"{dictionaryStats.fmBackendKind},{dictionaryStats.bwtLength}," &
    &"{dictionaryStats.runCount},{dictionaryStats.runRatio:.6f}," &
    &"{dictionaryStats.averageRunLength:.3f}," &
    &"{dictionaryStats.maximumRunLength},{memory.fmTotalBytes}," &
    &"{float(buildNs) / 1e6:.3f}," &
    &"{float(suffixNs) / QueryIterations.float:.1f}," &
    &"{float(substringNs) / QueryIterations.float:.1f}"

proc run(count, averageLength: int, corpusFilter = -1,
         preferenceFilter = -1) =
  for kind in CorpusKind:
    if corpusFilter >= 0 and ord(kind) != corpusFilter:
      continue
    let values = makeCorpus(kind, count, averageLength)
    for preference in [fbpWavelet, fbpRunLength, fbpAuto]:
      if preferenceFilter >= 0 and ord(preference) != preferenceFilter:
        continue
      measure(kind, values, averageLength, preference)

when isMainModule:
  echo "corpus,count,avg_len,preference,selected,bwt_n,runs,run_ratio," &
    "average_run,max_run,fm_bytes,build_ms,suffix_ns,substring_ns"
  if paramCount() >= 2:
    var count, averageLength: int
    var corpusFilter = -1
    var preferenceFilter = -1
    discard parseInt(paramStr(1), count)
    discard parseInt(paramStr(2), averageLength)
    if paramCount() >= 3:
      discard parseInt(paramStr(3), corpusFilter)
    if paramCount() >= 4:
      discard parseInt(paramStr(4), preferenceFilter)
    if count <= 0 or averageLength <= 0:
      raise newException(ValueError, "count and averageLength must be positive")
    if corpusFilter >= ord(low(CorpusKind)) and
        corpusFilter <= ord(high(CorpusKind)) and
        preferenceFilter >= -1 and
        preferenceFilter <= ord(high(FmBackendPreference)):
      run(count, averageLength, corpusFilter, preferenceFilter)
    elif corpusFilter == -1 and preferenceFilter == -1:
      run(count, averageLength)
    else:
      raise newException(ValueError,
        "corpus filter must be -1..9 and preference filter -1..2")
  else:
    for count in [10_000, 100_000, 1_000_000]:
      for averageLength in [8, 16, 32, 64]:
        run(count, averageLength)
  stderr.writeLine("sink=", sink)
