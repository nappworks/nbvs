## FmDictionary Binary WM vs 9-bit Hybrid (4 QuadVector + 1 SBV) A/B.
##
## 同じcorpus/query列を同一プロセスで交互に測定します。
## speedup = binary_ns / hybrid_ns。1.0超ならHybridが高速です。

import std/[algorithm, monotimes, os, parseutils, strformat, strutils, times]
import nbvs

const
  WarmupIters = 1
  MeasuredIters = 5

var sink {.volatile.}: uint64

func nextRandom(state: var uint64): uint64 {.inline.} =
  state += 0x9e37_79b9_7f4a_7c15'u64
  var value = state
  value = (value xor (value shr 30)) * 0xbf58_476d_1ce4_e5b9'u64
  value = (value xor (value shr 27)) * 0x94d0_49bb_1331_11eb'u64
  value xor (value shr 31)

proc makeCorpus(count, averageLength: int): seq[string] =
  result = newSeq[string](count)
  var state = 0x464d_4859_4239_2026'u64 xor uint64(count) xor
    uint64(averageLength)
  for i in 0..<count:
    let id = toHex(i, 8)
    var value = newString(max(0, averageLength - id.len - 1))
    for ch in value.mitems:
      ch = char(ord('a') + int(nextRandom(state) mod 26'u64))
    result[i] = value & "-" & id

func median(samples: var seq[int64]): int64 =
  samples.sort()
  samples[samples.len div 2]

template elapsedNs(body: untyped): int64 =
  block:
    let started = getMonoTime()
    body
    (getMonoTime() - started).inNanoseconds

template measurePair(binaryBody, hybridBody: untyped):
    tuple[binaryNs, hybridNs: int64] =
  block:
    var binarySamples = newSeqOfCap[int64](MeasuredIters)
    var hybridSamples = newSeqOfCap[int64](MeasuredIters)
    for iteration in 0..<(WarmupIters + MeasuredIters):
      var binaryElapsed, hybridElapsed: int64
      if (iteration and 1) == 0:
        binaryElapsed = elapsedNs:
          binaryBody
        hybridElapsed = elapsedNs:
          hybridBody
      else:
        hybridElapsed = elapsedNs:
          hybridBody
        binaryElapsed = elapsedNs:
          binaryBody
      if iteration >= WarmupIters:
        binarySamples.add binaryElapsed
        hybridSamples.add hybridElapsed
    (binarySamples.median(), hybridSamples.median())

proc emit(query: string, queryCount: int,
          measured: tuple[binaryNs, hybridNs: int64]) =
  let binaryNs = float(measured.binaryNs) / queryCount.float
  let hybridNs = float(measured.hybridNs) / queryCount.float
  echo &"{query},{binaryNs:.3f},{hybridNs:.3f},{binaryNs / hybridNs:.4f}"

proc main() =
  var count = 100_000
  var averageLength = 16
  var queryCount = 10_000
  if paramCount() >= 1: discard parseInt(paramStr(1), count)
  if paramCount() >= 2: discard parseInt(paramStr(2), averageLength)
  if paramCount() >= 3: discard parseInt(paramStr(3), queryCount)
  if count <= 0 or averageLength <= 0 or queryCount <= 0:
    raise newException(ValueError, "count, averageLength and queryCount must be positive")

  let values = makeCorpus(count, averageLength)

  var started = getMonoTime()
  let binary = genFmDictionary(values, FmDictionaryBuildOptions(
    validateDistinct: true, fmBackend: fbpWavelet))
  let binaryBuildNs = (getMonoTime() - started).inNanoseconds

  started = getMonoTime()
  let hybrid = genFmDictionary(values, FmDictionaryBuildOptions(
    validateDistinct: true, fmBackend: fbpHybridWavelet))
  let hybridBuildNs = (getMonoTime() - started).inNanoseconds

  doAssert binary.backendKind == fbWavelet
  doAssert hybrid.backendKind == fbHybridWavelet
  doAssert binary.stats.bwtLength == hybrid.stats.bwtLength

  var state = 0x243f_6a88_85a3_08d3'u64 xor uint64(count)
  var ids = newSeq[int](queryCount)
  var positions = newSeq[int64](queryCount)
  var querySymbols = newSeq[uint64](queryCount)
  var lefts = newSeq[int64](queryCount)
  var rights = newSeq[int64](queryCount)
  let bwtLength = binary.stats.bwtLength
  for i in 0..<queryCount:
    ids[i] = int(nextRandom(state) mod uint64(count))
    positions[i] = int64(nextRandom(state) mod uint64(bwtLength))
    querySymbols[i] = uint64(nextRandom(state) mod uint64(AlphabetSize))
    lefts[i] = int64(nextRandom(state) mod uint64(bwtLength))
    rights[i] = min(bwtLength, lefts[i] + 64)

  for i in 0..<min(queryCount, 512):
    let id = ids[i]
    let value = values[id]
    let suffixStart = max(0, value.len - min(8, value.len))
    let query = value[suffixStart..^1]
    doAssert binary.findExactFm(value) == hybrid.findExactFm(value)
    doAssert binary.findSuffix(query) == hybrid.findSuffix(query)
    doAssert binary.findSubstring(query) == hybrid.findSubstring(query)
    doAssert binary.getString(DictionaryId(id)) == hybrid.getString(DictionaryId(id))
    doAssert binary.bwt.accessRank(positions[i]) ==
      hybrid.hybridBwt.accessRank(positions[i])
    doAssert binary.bwt.rankPair(querySymbols[i], lefts[i], rights[i]) ==
      hybrid.hybridBwt.rankPair(querySymbols[i], lefts[i], rights[i])

  let accessRank = measurePair(
    (block:
      for pos in positions:
        let item = binary.bwt.accessRank(pos)
        sink = sink xor item.value xor uint64(item.rankBefore)),
    (block:
      for pos in positions:
        let item = hybrid.hybridBwt.accessRank(pos)
        sink = sink xor item.value xor uint64(item.rankBefore)))

  let rankPair = measurePair(
    (block:
      for i in 0..<queryCount:
        let item = binary.bwt.rankPair(querySymbols[i], lefts[i], rights[i])
        sink = sink xor uint64(item.leftRank) xor uint64(item.rightRank)),
    (block:
      for i in 0..<queryCount:
        let item = hybrid.hybridBwt.rankPair(querySymbols[i], lefts[i], rights[i])
        sink = sink xor uint64(item.leftRank) xor uint64(item.rightRank)))

  var suffixOutput, substringOutput: seq[DictionaryId]
  var binaryWorkspace = initFmQueryWorkspace(binary)
  var hybridWorkspace = initFmQueryWorkspace(hybrid)

  let suffixQuery = measurePair(
    (block:
      for id in ids:
        let value = values[id]
        let start = max(0, value.len - min(8, value.len))
        binary.findSuffixInto(value[start..^1], suffixOutput)
        sink = sink xor uint64(suffixOutput.len)),
    (block:
      for id in ids:
        let value = values[id]
        let start = max(0, value.len - min(8, value.len))
        hybrid.findSuffixInto(value[start..^1], suffixOutput)
        sink = sink xor uint64(suffixOutput.len)))

  let substringQuery = measurePair(
    (block:
      for id in ids:
        let value = values[id]
        let start = max(0, value.len - min(8, value.len))
        binary.findSubstringInto(value[start..^1], binaryWorkspace, substringOutput)
        sink = sink xor uint64(substringOutput.len)),
    (block:
      for id in ids:
        let value = values[id]
        let start = max(0, value.len - min(8, value.len))
        hybrid.findSubstringInto(value[start..^1], hybridWorkspace, substringOutput)
        sink = sink xor uint64(substringOutput.len)))

  var restored = ""
  let restore = measurePair(
    (block:
      for id in ids:
        binary.getStringIntoFm(DictionaryId(id), restored)
        sink = sink xor uint64(restored.len)),
    (block:
      for id in ids:
        hybrid.getStringIntoFm(DictionaryId(id), restored)
        sink = sink xor uint64(restored.len)))

  let binaryMemory = binary.memoryUsage
  let hybridMemory = hybrid.memoryUsage
  echo "metric,binary,hybrid,speedup_or_ratio"
  echo &"build_ms,{float(binaryBuildNs) / 1e6:.3f}," &
    &"{float(hybridBuildNs) / 1e6:.3f}," &
    &"{float(binaryBuildNs) / float(hybridBuildNs):.4f}"
  echo &"bwt_bytes,{binaryMemory.bwtBytes},{hybridMemory.bwtBytes}," &
    &"{float(hybridMemory.bwtBytes) / float(binaryMemory.bwtBytes):.4f}"
  emit("accessRank_ns", queryCount, accessRank)
  emit("rankPair_ns", queryCount, rankPair)
  emit("suffix_ns", queryCount, suffixQuery)
  emit("substring_ns", queryCount, substringQuery)
  emit("restore_ns", queryCount, restore)
  stderr.writeLine("sink=", sink)

when isMainModule:
  main()
