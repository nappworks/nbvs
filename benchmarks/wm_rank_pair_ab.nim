## WM fixed-depth rank-pair optimization A/B benchmark.
##
## separate_fixed: each bound calls rank1UncheckedDepthN separately.
## pair: current WM path using rank1PairUncheckedDepthN.
##
## speedup = separate_fixed_ns / pair_ns.

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

proc makeRanges(count, symbols: int):
    tuple[lefts, rights: seq[int64]] =
  result.lefts = newSeq[int64](count)
  result.rights = newSeq[int64](count)
  var state = 0x243f_6a88_85a3_08d3'u64 xor uint64(symbols)
  for i in 0..<count:
    let left = int64(nextRand(state) mod uint64(symbols))
    var right: int64
    if (i and 1) == 0:
      let width = int64((nextRand(state) mod 256'u64) + 1)
      right = min(int64(symbols), left + width)
    else:
      right = left + int64(nextRand(state) mod uint64(symbols - int(left) + 1))
    result.lefts[i] = left
    result.rights[i] = right

template runSeparateRankPair(bits, left, right, depth: untyped):
    tuple[leftRank, rightRank: int64] =
  block:
    var item: tuple[leftRank, rightRank: int64]
    when depth == 0:
      item.leftRank = bits.rank1UncheckedDepth0(left)
      item.rightRank = bits.rank1UncheckedDepth0(right)
    elif depth == 1:
      item.leftRank = bits.rank1UncheckedDepth1(left)
      item.rightRank = bits.rank1UncheckedDepth1(right)
    elif depth == 2:
      item.leftRank = bits.rank1UncheckedDepth2(left)
      item.rightRank = bits.rank1UncheckedDepth2(right)
    elif depth == 3:
      item.leftRank = bits.rank1UncheckedDepth3(left)
      item.rightRank = bits.rank1UncheckedDepth3(right)
    elif depth == 4:
      item.leftRank = bits.rank1UncheckedDepth4(left)
      item.rightRank = bits.rank1UncheckedDepth4(right)
    elif depth == 5:
      item.leftRank = bits.rank1UncheckedDepth5(left)
      item.rightRank = bits.rank1UncheckedDepth5(right)
    elif depth == 6:
      item.leftRank = bits.rank1UncheckedDepth6(left)
      item.rightRank = bits.rank1UncheckedDepth6(right)
    elif depth == 7:
      item.leftRank = bits.rank1UncheckedDepth7(left)
      item.rightRank = bits.rank1UncheckedDepth7(right)
    else:
      item.leftRank = bits.rank1UncheckedDepth8(left)
      item.rightRank = bits.rank1UncheckedDepth8(right)
    item

func separateRangeRank(wm: WaveletMatrix, value: uint64,
                       left, right: int64): int64 =
  template run(depth: static[int]) =
    block:
      var lo = left
      var hi = right
      for level in 0..<wm.bitWidth:
        let shift = wm.bitWidth - level - 1
        let ranks = runSeparateRankPair(wm.levels[level], lo, hi, depth)
        if ((value shr shift) and 1'u64) == 0:
          lo -= ranks.leftRank
          hi -= ranks.rightRank
        else:
          lo = wm.zeroCounts[level] + ranks.leftRank
          hi = wm.zeroCounts[level] + ranks.rightRank
      result = hi - lo
  case int(wm.levels[0].level)
  of 0: run(0)
  of 1: run(1)
  of 2: run(2)
  of 3: run(3)
  of 4: run(4)
  of 5: run(5)
  of 6: run(6)
  of 7: run(7)
  else: run(8)

func separateCountLessThan(wm: WaveletMatrix, left, right: int64,
                           value: uint64): int64 =
  template run(depth: static[int]) =
    block:
      var lo = left
      var hi = right
      for level in 0..<wm.bitWidth:
        let shift = wm.bitWidth - level - 1
        let ranks = runSeparateRankPair(wm.levels[level], lo, hi, depth)
        let loZeros = lo - ranks.leftRank
        let hiZeros = hi - ranks.rightRank
        if ((value shr shift) and 1'u64) == 0:
          lo = loZeros
          hi = hiZeros
        else:
          result += hiZeros - loZeros
          lo = wm.zeroCounts[level] + ranks.leftRank
          hi = wm.zeroCounts[level] + ranks.rightRank
  case int(wm.levels[0].level)
  of 0: run(0)
  of 1: run(1)
  of 2: run(2)
  of 3: run(3)
  of 4: run(4)
  of 5: run(5)
  of 6: run(6)
  of 7: run(7)
  else: run(8)

func separateQuantile(wm: WaveletMatrix, left, right, k: int64): uint64 =
  template run(depth: static[int]) =
    block:
      var lo = left
      var hi = right
      var rest = k
      for level in 0..<wm.bitWidth:
        let shift = wm.bitWidth - level - 1
        let ranks = runSeparateRankPair(wm.levels[level], lo, hi, depth)
        let loZeros = lo - ranks.leftRank
        let hiZeros = hi - ranks.rightRank
        let zeros = hiZeros - loZeros
        if rest < zeros:
          lo = loZeros
          hi = hiZeros
        else:
          result = result or (1'u64 shl shift)
          rest -= zeros
          lo = wm.zeroCounts[level] + ranks.leftRank
          hi = wm.zeroCounts[level] + ranks.rightRank
  case int(wm.levels[0].level)
  of 0: run(0)
  of 1: run(1)
  of 2: run(2)
  of 3: run(3)
  of 4: run(4)
  of 5: run(5)
  of 6: run(6)
  of 7: run(7)
  else: run(8)

func median(samples: var seq[int64]): int64 =
  samples.sort()
  samples[samples.len div 2]

template elapsedNs(body: untyped): int64 =
  block:
    let started = getMonoTime()
    body
    (getMonoTime() - started).inNanoseconds

template measurePair(separateBody, pairBody: untyped):
    tuple[separateNs, pairNs: int64] =
  block:
    var separateSamples = newSeqOfCap[int64](measuredIters)
    var pairSamples = newSeqOfCap[int64](measuredIters)
    for iteration in 0..<(warmupIters + measuredIters):
      var separateElapsed, pairElapsed: int64
      if (iteration and 1) == 0:
        separateElapsed = elapsedNs:
          separateBody
        pairElapsed = elapsedNs:
          pairBody
      else:
        pairElapsed = elapsedNs:
          pairBody
        separateElapsed = elapsedNs:
          separateBody
      if iteration >= warmupIters:
        separateSamples.add separateElapsed
        pairSamples.add pairElapsed
    (separateSamples.median(), pairSamples.median())

proc emit(c: BenchCase, query: string, measured:
    tuple[separateNs, pairNs: int64]) =
  let separateNs = float(measured.separateNs) / queryCount.float
  let pairNs = float(measured.pairNs) / queryCount.float
  echo &"{c.symbols},{c.distribution},{query},{separateNs:.3f},{pairNs:.3f},{separateNs / pairNs:.4f}"

proc runCase(c: BenchCase) =
  let values = makeValues(c)
  let ranges = makeRanges(queryCount, c.symbols)
  let wm = genWaveletMatrix(values, bitWidth)

  var queryValues = newSeq[uint64](queryCount)
  var ks = newSeq[int64](queryCount)
  for i in 0..<queryCount:
    let left = ranges.lefts[i]
    let right = ranges.rights[i]
    let pos = if left < right: left else: max(0'i64, left - 1)
    queryValues[i] = values[int(pos)]
    ks[i] = 0

  var state = 0x1319_8a2e_0370_7344'u64 xor uint64(c.symbols)
  for i in 0..<queryCount:
    let width = ranges.rights[i] - ranges.lefts[i]
    if width > 0:
      ks[i] = int64(nextRand(state) mod uint64(width))

  for i in 0..<min(validationCount, queryCount):
    let left = ranges.lefts[i]
    let right = ranges.rights[i]
    let value = queryValues[i]
    doAssert separateRangeRank(wm, value, left, right) ==
      wm.rank(value, left, right)
    doAssert separateCountLessThan(wm, left, right, value) ==
      wm.countLessThan(left, right, value)
    if right > left:
      doAssert separateQuantile(wm, left, right, ks[i]) ==
        wm.quantile(left, right, ks[i])

  let rangeRank = measurePair(
    (block:
      for i in 0..<queryCount:
        sink = sink xor uint64(separateRangeRank(
          wm, queryValues[i], ranges.lefts[i], ranges.rights[i]))),
    (block:
      for i in 0..<queryCount:
        sink = sink xor uint64(wm.rank(
          queryValues[i], ranges.lefts[i], ranges.rights[i]))))

  let lessThan = measurePair(
    (block:
      for i in 0..<queryCount:
        sink = sink xor uint64(separateCountLessThan(
          wm, ranges.lefts[i], ranges.rights[i], queryValues[i]))),
    (block:
      for i in 0..<queryCount:
        sink = sink xor uint64(wm.countLessThan(
          ranges.lefts[i], ranges.rights[i], queryValues[i]))))

  let quantile = measurePair(
    (block:
      for i in 0..<queryCount:
        if ranges.rights[i] > ranges.lefts[i]:
          sink = sink xor separateQuantile(
            wm, ranges.lefts[i], ranges.rights[i], ks[i])),
    (block:
      for i in 0..<queryCount:
        if ranges.rights[i] > ranges.lefts[i]:
          sink = sink xor wm.quantile(
            ranges.lefts[i], ranges.rights[i], ks[i])))

  emit(c, "rangeRank", rangeRank)
  emit(c, "countLessThan", lessThan)
  emit(c, "quantile", quantile)

when isMainModule:
  echo "symbols,distribution,query,separate_fixed_ns,pair_ns,speedup"
  for c in cases:
    runCase(c)
  stderr.writeLine("sink=", sink)
