## WM value enumerationのlegacy traversalとcurrent production traversalを
## 同一入力・同一processで比較します。
##
## speedup = legacy_ns / fixed_depth_ns。1.0超ならcurrent側が高速です。

import std/[algorithm, monotimes, strformat, times]
import nbvs/[succinct_bit_vector, wavelet_matrix]

type
  BenchCase = object
    rows: int
    cardinality: int

  TraversalNode = tuple[level: int, left, right: int64, value: uint64]

const
  cases = [
    BenchCase(rows: 65_536, cardinality: 256),
    BenchCase(rows: 65_536, cardinality: 65_536),
    BenchCase(rows: 1_048_576, cardinality: 256),
    BenchCase(rows: 1_048_576, cardinality: 65_536)
  ]
  warmupIters = 1
  measuredIters = 7
  rangeProbeCount = 64
  rangeWidth = 4_096

var sink {.volatile.}: uint64

func nextRand(state: var uint64): uint64 {.inline.} =
  state = state * 6364136223846793005'u64 + 1442695040888963407'u64
  state

proc makeValues(c: BenchCase): seq[uint64] =
  result = newSeq[uint64](c.rows)
  var state = 0x9e37_79b9_7f4a_7c15'u64 xor uint64(c.rows) xor
    uint64(c.cardinality)
  for value in result.mitems:
    value = nextRand(state) mod uint64(c.cardinality)
  if result.len > 0:
    result[^1] = uint64(c.cardinality - 1)

proc legacyChecksum(wm: WaveletMatrix, left, right: int64,
    includeIntervals: bool): uint64 =
  var stack: seq[TraversalNode] =
    @[(level: 0, left: left, right: right, value: 0'u64)]
  while stack.len > 0:
    let node = stack.pop()
    if node.left >= node.right:
      continue
    if node.level == wm.bitWidth:
      result = result xor node.value xor uint64(node.right - node.left)
      if includeIntervals:
        result = result xor uint64(node.left) xor (uint64(node.right) shl 1)
      continue

    let shift = wm.bitWidth - node.level - 1
    let leftOnes = wm.levels[node.level].rank1Unchecked(node.left)
    let rightOnes = wm.levels[node.level].rank1Unchecked(node.right)
    let oneLeft = wm.zeroCounts[node.level] + leftOnes
    let oneRight = wm.zeroCounts[node.level] + rightOnes
    stack.add (level: node.level + 1, left: oneLeft, right: oneRight,
      value: node.value or (1'u64 shl shift))
    stack.add (level: node.level + 1, left: node.left - leftOnes,
      right: node.right - rightOnes, value: node.value)

proc currentCountsChecksum(wm: WaveletMatrix, left, right: int64): uint64 =
  for item in wm.collectValueCountsItems(left, right):
    result = result xor item.value xor uint64(item.frequency)

proc currentIntervalsChecksum(wm: WaveletMatrix, left, right: int64): uint64 =
  for item in wm.collectValueCountFinalIntervalsItems(left, right):
    result = result xor item.value xor uint64(item.frequency) xor
      uint64(item.left) xor (uint64(item.right) shl 1)

proc legacyRangeChecksum(wm: WaveletMatrix): uint64 =
  for probe in 0..<rangeProbeCount:
    let left = int64((probe * 977) mod max(1, int(wm.n) - rangeWidth))
    let right = min(wm.n, left + rangeWidth)
    result = result xor wm.legacyChecksum(left, right, true)

proc currentRangeChecksum(wm: WaveletMatrix): uint64 =
  for probe in 0..<rangeProbeCount:
    let left = int64((probe * 977) mod max(1, int(wm.n) - rangeWidth))
    let right = min(wm.n, left + rangeWidth)
    result = result xor wm.currentIntervalsChecksum(left, right)

func median(samples: var seq[int64]): int64 =
  samples.sort()
  samples[samples.len div 2]

template elapsedNs(body: untyped): int64 =
  block:
    let started = getMonoTime()
    body
    (getMonoTime() - started).inNanoseconds

template measurePair(legacyBody, currentBody: untyped):
    tuple[legacyNs, currentNs: int64] =
  block:
    var legacySamples = newSeqOfCap[int64](measuredIters)
    var currentSamples = newSeqOfCap[int64](measuredIters)
    for iteration in 0..<(warmupIters + measuredIters):
      var legacyElapsed, currentElapsed: int64
      if (iteration and 1) == 0:
        legacyElapsed = elapsedNs:
          legacyBody
        currentElapsed = elapsedNs:
          currentBody
      else:
        currentElapsed = elapsedNs:
          currentBody
        legacyElapsed = elapsedNs:
          legacyBody
      if iteration >= warmupIters:
        legacySamples.add legacyElapsed
        currentSamples.add currentElapsed
    (legacySamples.median(), currentSamples.median())

proc emit(c: BenchCase, query: string,
    measured: tuple[legacyNs, currentNs: int64]) =
  let speedup = float(measured.legacyNs) / float(measured.currentNs)
  echo &"{c.rows},{c.cardinality},{query},{measured.legacyNs}," &
    &"{measured.currentNs},{speedup:.4f}"

proc runCase(c: BenchCase) =
  let wm = genWaveletMatrix(makeValues(c))
  let legacyCounts = wm.legacyChecksum(0, wm.n, false)
  let currentCounts = wm.currentCountsChecksum(0, wm.n)
  let legacyIntervals = wm.legacyChecksum(0, wm.n, true)
  let currentIntervals = wm.currentIntervalsChecksum(0, wm.n)
  let legacyRanges = wm.legacyRangeChecksum()
  let currentRanges = wm.currentRangeChecksum()
  doAssert legacyCounts == currentCounts
  doAssert legacyIntervals == currentIntervals
  doAssert legacyRanges == currentRanges

  emit(c, "full_counts", measurePair(
    (block: sink = sink xor wm.legacyChecksum(0, wm.n, false)),
    (block: sink = sink xor wm.currentCountsChecksum(0, wm.n))))
  emit(c, "full_intervals", measurePair(
    (block: sink = sink xor wm.legacyChecksum(0, wm.n, true)),
    (block: sink = sink xor wm.currentIntervalsChecksum(0, wm.n))))
  emit(c, "range_intervals", measurePair(
    (block: sink = sink xor wm.legacyRangeChecksum()),
    (block: sink = sink xor wm.currentRangeChecksum())))

when isMainModule:
  echo "rows,cardinality,query,legacy_ns,fixed_depth_ns,speedup"
  for c in cases:
    runCase(c)
  stderr.writeLine("sink=", sink)
