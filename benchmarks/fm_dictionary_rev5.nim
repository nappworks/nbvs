## rev5向けFM query phase、tail latency、perf workload benchmark。

import std/[algorithm, os, osproc, parseutils, strformat, strutils]
import nbvs

const Seed = 0x666d_7265_7635_2026'u64

type
  CorpusKind = enum
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

  QueryKind = enum
    qkSuffix = "suffix"
    qkSubstring = "substring"

  TimingGroup = object
    backwardSearchNs: int64
    lfTraversalNs: int64
    materializationNs: int64
    orderingNs: int64
    intervalWidth: int64
    lfSteps: int64
    occurrences: int64
    uniqueIds: int64
    latencies: seq[int64]

var sink {.volatile.}: uint64

func nextRandom(state: var uint64): uint64 =
  state += 0x9e37_79b9_7f4a_7c15'u64
  var value = state
  value = (value xor (value shr 30)) * 0xbf58_476d_1ce4_e5b9'u64
  value = (value xor (value shr 27)) * 0x94d0_49bb_1331_11eb'u64
  value xor (value shr 31)

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
        let alphabet = if kind == ckRandom: 26'u64 else: 6'u64
        character = char(ord('a') + int(nextRandom(state) mod alphabet))
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

func percentile(sortedValues: seq[int64], numerator: int): int64 =
  if sortedValues.len == 0:
    return 0
  sortedValues[min(sortedValues.high,
    (sortedValues.len * numerator + 99) div 100 - 1)]

func hitBucket(hitCount: int): int =
  if hitCount <= 1: 0
  elif hitCount <= 10: 1
  elif hitCount <= 100: 2
  elif hitCount <= 1_000: 3
  else: 4

proc add(group: var TimingGroup, timing: FmQueryTiming) =
  group.backwardSearchNs += timing.backwardSearchNs
  group.lfTraversalNs += timing.lfTraversalNs
  group.materializationNs += timing.materializationNs
  group.orderingNs += timing.orderingNs
  group.intervalWidth += timing.intervalWidth
  group.lfSteps += timing.lfSteps
  group.occurrences += timing.totalOccurrences
  group.uniqueIds += timing.uniqueIds
  group.latencies.add timing.totalNs

proc makeQueries(values: seq[string], patternLength, queryCount: int,
                 kind: QueryKind): seq[string] =
  result = newSeq[string](queryCount)
  var state = Seed xor uint64(patternLength) xor uint64(ord(kind))
  for queryIndex in 0..<queryCount:
    if queryIndex mod 8 == 0:
      result[queryIndex] = repeat(char(1), patternLength)
      continue
    let value = values[int(nextRandom(state) mod uint64(values.len))]
    let length = min(patternLength, value.len)
    if kind == qkSuffix:
      result[queryIndex] = value[value.len - length..<value.len]
    else:
      let start = if value.len == length: 0 else:
        int(nextRandom(state) mod uint64(value.len - length + 1))
      result[queryIndex] = value[start..<start + length]

proc emit(kind: CorpusKind, count, averageLength, patternLength: int,
          backend: FmBackendKind, queryKind: QueryKind, bucket: int,
          group: var TimingGroup) =
  if group.latencies.len == 0:
    return
  group.latencies.sort()
  let queries = int64(group.latencies.len)
  echo &"{kind},{count},{averageLength},{patternLength},{backend},{queryKind}," &
    &"{bucket},{queries},{group.intervalWidth div queries}," &
    &"{group.occurrences div queries},{group.uniqueIds div queries}," &
    &"{group.lfSteps div queries},{group.backwardSearchNs div queries}," &
    &"{group.lfTraversalNs div queries},{group.materializationNs div queries}," &
    &"{group.orderingNs div queries},{percentile(group.latencies, 50)}," &
    &"{percentile(group.latencies, 90)},{percentile(group.latencies, 95)}," &
    &"{percentile(group.latencies, 99)},{group.latencies[^1]}"

proc measure(kind: CorpusKind, count, averageLength, queryCount: int,
             preference: FmBackendPreference) =
  let values = makeCorpus(kind, count, averageLength)
  let dict = genFmDictionary(values, FmDictionaryBuildOptions(
    validateDistinct: true, fmBackend: preference))
  var workspace = initFmQueryWorkspace(dict)
  var output: seq[DictionaryId]
  for patternLength in [1, 2, 4, 8, 16, 32, 64]:
    for queryKind in QueryKind:
      let queries = makeQueries(values, patternLength, queryCount, queryKind)
      # page faultとallocator初期化の影響を除くため、同じquery setを1周する。
      for query in queries:
        if queryKind == qkSuffix:
          sink = sink xor uint64(dict.findSuffix(query).len)
        else:
          dict.findSubstringInto(query, workspace, output)
          sink = sink xor uint64(output.len)

      var groups: array[5, TimingGroup]
      for query in queries:
        let timing = if queryKind == qkSuffix:
          dict.benchmarkSuffixQuery(query, output)
        else:
          dict.benchmarkSubstringQuery(query, workspace, output)
        groups[hitBucket(output.len)].add timing
        sink = sink xor uint64(output.len)
      for bucket in 0..<groups.len:
        emit(kind, count, averageLength, patternLength, dict.backendKind,
          queryKind, bucket, groups[bucket])

proc measureSingle(kind: CorpusKind, count, averageLength, queryCount,
                   patternLength: int, preference: FmBackendPreference,
                   queryKind: QueryKind) =
  let values = makeCorpus(kind, count, averageLength)
  let dict = genFmDictionary(values, FmDictionaryBuildOptions(
    validateDistinct: true, fmBackend: preference))
  let queries = makeQueries(values, patternLength, queryCount, queryKind)
  var workspace = initFmQueryWorkspace(dict)
  var output: seq[DictionaryId]
  for query in queries:
    if queryKind == qkSuffix:
      sink = sink xor uint64(dict.findSuffix(query).len)
    else:
      dict.findSubstringInto(query, workspace, output)
      sink = sink xor uint64(output.len)
  var groups: array[5, TimingGroup]
  for query in queries:
    let timing = if queryKind == qkSuffix:
      dict.benchmarkSuffixQuery(query, output)
    else:
      dict.benchmarkSubstringQuery(query, workspace, output)
    groups[hitBucket(output.len)].add timing
    sink = sink xor uint64(output.len)
  for bucket in 0..<groups.len:
    emit(kind, count, averageLength, patternLength, dict.backendKind,
      queryKind, bucket, groups[bucket])

proc perfWorkload(kind: CorpusKind, count, averageLength, patternLength,
                  queryCount: int, preference: FmBackendPreference,
                  queryKind: QueryKind) =
  let values = makeCorpus(kind, count, averageLength)
  let dict = genFmDictionary(values, FmDictionaryBuildOptions(
    validateDistinct: true, fmBackend: preference))
  let queries = makeQueries(values, patternLength, queryCount, queryKind)
  var workspace = initFmQueryWorkspace(dict)
  var output: seq[DictionaryId]
  for query in queries:
    if queryKind == qkSuffix:
      sink = sink xor uint64(dict.findSuffix(query).len)
    else:
      dict.findSubstringInto(query, workspace, output)
      sink = sink xor uint64(output.len)
  echo &"perf,{dict.backendKind},{queryKind},{queryCount},{sink}"

when isMainModule:
  let kernel = execProcess("uname", args = ["-r"], options = {poUsePath,
    poStdErrToStdOut}).strip()
  let commit = execProcess("git", args = ["rev-parse", "--short", "HEAD"],
    options = {poUsePath, poStdErrToStdOut}).strip()
  stderr.writeLine(&"metadata,nim={NimVersion},os={hostOS},cpu={hostCPU}," &
    &"kernel={kernel},commit={commit},release=true,mm=arc," &
    &"simd={defined(nbvsSimd)}")
  echo "corpus,count,avg_len,pattern_len,backend,query_kind,hit_bucket," &
    "queries,interval_width,occurrences,unique_ids,lf_steps," &
    "backward_search_ns,lf_traversal_ns,materialization_ns,ordering_ns," &
    "p50_ns,p90_ns,p95_ns,p99_ns,max_ns"
  if paramCount() < 5:
    raise newException(ValueError,
      "usage: count avgLen corpus preference queries [patternLen queryKind]")
  var count, averageLength, corpusOrdinal, preferenceOrdinal, queryCount: int
  discard parseInt(paramStr(1), count)
  discard parseInt(paramStr(2), averageLength)
  discard parseInt(paramStr(3), corpusOrdinal)
  discard parseInt(paramStr(4), preferenceOrdinal)
  discard parseInt(paramStr(5), queryCount)
  if count <= 0 or averageLength <= 0 or queryCount <= 0 or
      corpusOrdinal notin ord(low(CorpusKind))..ord(high(CorpusKind)) or
      preferenceOrdinal notin ord(low(FmBackendPreference))..
        ord(high(FmBackendPreference)):
    raise newException(ValueError, "invalid benchmark argument")
  if paramCount() >= 7:
    var patternLength, queryKindOrdinal: int
    discard parseInt(paramStr(6), patternLength)
    discard parseInt(paramStr(7), queryKindOrdinal)
    if paramCount() >= 8 and paramStr(8) == "tail":
      measureSingle(CorpusKind(corpusOrdinal), count, averageLength,
        queryCount, patternLength, FmBackendPreference(preferenceOrdinal),
        QueryKind(queryKindOrdinal))
    else:
      perfWorkload(CorpusKind(corpusOrdinal), count, averageLength,
        patternLength, queryCount, FmBackendPreference(preferenceOrdinal),
        QueryKind(queryKindOrdinal))
  else:
    measure(CorpusKind(corpusOrdinal), count, averageLength, queryCount,
      FmBackendPreference(preferenceOrdinal))
