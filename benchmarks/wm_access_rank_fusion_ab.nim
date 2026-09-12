## WaveletMatrixのSBV access+rank融合を単独で測る同一プロセスA/B benchmarkです。
##
## unfused_fixed: fixed-depth rank + separate payload bit access（融合前）
## fused: current WM path using SBV accessRank1UncheckedDepthN
##
##   nimble benchWmAccessRankFusionAb
##   nimble benchWmAccessRankFusionAbSimd
##
## speedup = unfused_fixed_ns / fused_ns。1.0超なら融合側が高速です。

import std/[algorithm, monotimes, strformat, times]
import nbvs/[succinct_bit_vector, wavelet_matrix]

type
  Distribution = enum
    uniform, skewed

  BenchCase = object
    symbols: int
    distribution: Distribution

const
  cases = [
    BenchCase(symbols: 65_536, distribution: uniform),
    BenchCase(symbols: 65_536, distribution: skewed),
    BenchCase(symbols: 1_048_576, distribution: uniform),
    BenchCase(symbols: 1_048_576, distribution: skewed),
    BenchCase(symbols: 16_777_216, distribution: uniform),
    BenchCase(symbols: 16_777_216, distribution: skewed)
  ]
  bitWidth = 8
  queryCount = 20_000
  validationCount = 512
  warmupIters = 1
  measuredIters = 5

var sink {.volatile.}: uint64

func nextRand(state: var uint64): uint64 {.inline.} =
  state = state * 6364136223846793005'u64 + 1442695040888963407'u64
  state

proc makeValues(c: BenchCase): seq[uint64] =
  result = newSeq[uint64](c.symbols)
  var state = 0x9e37_79b9_7f4a_7c15'u64 xor uint64(c.symbols)
  for value in result.mitems:
    let random = nextRand(state)
    case c.distribution
    of uniform:
      value = random and 255'u64
    of skewed:
      if random mod 100'u64 < 95'u64:
        value = random and 15'u64
      else:
        value = nextRand(state) and 255'u64
  if result.len > 0:
    result[^1] = result[^1] or 128'u64

proc makePositions(count, symbols: int): seq[int64] =
  result = newSeq[int64](count)
  var state = 0x243f_6a88_85a3_08d3'u64 xor uint64(symbols)
  for pos in result.mitems:
    pos = int64(nextRand(state) mod uint64(symbols))

func bitAtRaw(bits: SuccinctBitVector, pos: int64): bool {.inline.} =
  ((bits.data[int(pos shr 6)] shr int(pos and 63)) and 1'u64) != 0

func unfusedAccess(wm: WaveletMatrix, i: int64): uint64 =
  if i < 0 or i >= wm.n:
    raise newException(IndexDefect, "index out of bounds")
  if wm.bitWidth == 0:
    return 0

  template run(rankFn: untyped) =
    block:
      var pos = i
      for level in 0..<wm.bitWidth:
        let shift = wm.bitWidth - level - 1
        let ones = rankFn(wm.levels[level], pos)
        if wm.levels[level].bitAtRaw(pos):
          result = result or (1'u64 shl shift)
          pos = wm.zeroCounts[level] + ones
        else:
          pos -= ones

  case int(wm.levels[0].level)
  of 0: run(rank1UncheckedDepth0)
  of 1: run(rank1UncheckedDepth1)
  of 2: run(rank1UncheckedDepth2)
  of 3: run(rank1UncheckedDepth3)
  of 4: run(rank1UncheckedDepth4)
  of 5: run(rank1UncheckedDepth5)
  of 6: run(rank1UncheckedDepth6)
  of 7: run(rank1UncheckedDepth7)
  else: run(rank1UncheckedDepth8)

func unfusedAccessRank(wm: WaveletMatrix, pos: int64):
    tuple[value: uint64, rankBefore: int64] =
  if wm.bitWidth == 0:
    result.rankBefore = pos
    return

  template run(rankFn: untyped) =
    block:
      var current = pos
      var intervalLeft = 0'i64
      for level in 0..<wm.bitWidth:
        let shift = wm.bitWidth - level - 1
        let currentOnes = rankFn(wm.levels[level], current)
        let leftOnes = rankFn(wm.levels[level], intervalLeft)
        if wm.levels[level].bitAtRaw(current):
          result.value = result.value or (1'u64 shl shift)
          current = wm.zeroCounts[level] + currentOnes
          intervalLeft = wm.zeroCounts[level] + leftOnes
        else:
          current -= currentOnes
          intervalLeft -= leftOnes
      result.rankBefore = current - intervalLeft

  case int(wm.levels[0].level)
  of 0: run(rank1UncheckedDepth0)
  of 1: run(rank1UncheckedDepth1)
  of 2: run(rank1UncheckedDepth2)
  of 3: run(rank1UncheckedDepth3)
  of 4: run(rank1UncheckedDepth4)
  of 5: run(rank1UncheckedDepth5)
  of 6: run(rank1UncheckedDepth6)
  of 7: run(rank1UncheckedDepth7)
  else: run(rank1UncheckedDepth8)

func median(samples: var seq[int64]): int64 =
  samples.sort()
  samples[samples.len div 2]

template elapsedNs(body: untyped): int64 =
  block:
    let started = getMonoTime()
    body
    (getMonoTime() - started).inNanoseconds

template measurePair(unfusedBody, fusedBody: untyped):
    tuple[unfusedNs, fusedNs: int64] =
  block:
    var unfusedSamples = newSeqOfCap[int64](measuredIters)
    var fusedSamples = newSeqOfCap[int64](measuredIters)
    for iteration in 0..<(warmupIters + measuredIters):
      var unfusedElapsed, fusedElapsed: int64
      if (iteration and 1) == 0:
        unfusedElapsed = elapsedNs:
          unfusedBody
        fusedElapsed = elapsedNs:
          fusedBody
      else:
        fusedElapsed = elapsedNs:
          fusedBody
        unfusedElapsed = elapsedNs:
          unfusedBody
      if iteration >= warmupIters:
        unfusedSamples.add unfusedElapsed
        fusedSamples.add fusedElapsed
    (unfusedSamples.median(), fusedSamples.median())

proc emit(c: BenchCase, query: string, measured:
    tuple[unfusedNs, fusedNs: int64]) =
  let unfusedNs = float(measured.unfusedNs) / queryCount.float
  let fusedNs = float(measured.fusedNs) / queryCount.float
  let speedup = unfusedNs / fusedNs
  echo &"{c.symbols},{c.distribution},{query},{unfusedNs:.3f},{fusedNs:.3f},{speedup:.4f}"

proc runCase(c: BenchCase) =
  let values = makeValues(c)
  let positions = makePositions(queryCount, c.symbols)
  let wm = genWaveletMatrix(values, bitWidth)

  for i in 0..<min(validationCount, queryCount):
    let pos = positions[i]
    doAssert unfusedAccess(wm, pos) == wm.access(pos)
    doAssert unfusedAccessRank(wm, pos) == wm.accessRankUnchecked(pos)

  let access = measurePair(
    (block:
      for pos in positions:
        sink = sink xor unfusedAccess(wm, pos)),
    (block:
      for pos in positions:
        sink = sink xor wm.access(pos)))

  let accessRank = measurePair(
    (block:
      for pos in positions:
        let item = unfusedAccessRank(wm, pos)
        sink = sink xor item.value xor uint64(item.rankBefore)),
    (block:
      for pos in positions:
        let item = wm.accessRankUnchecked(pos)
        sink = sink xor item.value xor uint64(item.rankBefore)))

  emit(c, "access", access)
  emit(c, "accessRank", accessRank)

when isMainModule:
  echo "symbols,distribution,query,unfused_fixed_ns,fused_ns,speedup"
  for c in cases:
    runCase(c)
  stderr.writeLine("sink=", sink)
