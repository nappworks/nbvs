## WaveletMatrix fixed-depth rank dispatch の同一プロセスA/B benchmarkです。
##
## current public WM path (fixed-depth dispatch) と、固定depth化前と同じ
## rank1Unchecked generic dispatchを各levelで呼ぶreference pathを、同一入力・
## 同一queryで交互に測定します。production codeは変更しません。
##
##   nimble benchWmDepthAb
##   nimble benchWmDepthAbSimd
##
## CSV columnsの speedup は generic_ns / fixed_ns です。1.0超ならfixed-depth側が高速です。

import std/[algorithm, monotimes, strformat]
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

func valueFits8(value: uint64): bool {.inline.} =
  (value shr bitWidth) == 0

func genericAccess(wm: WaveletMatrix, i: int64): uint64 =
  if i < 0 or i >= wm.n:
    raise newException(IndexDefect, "index out of bounds")
  var pos = i
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let ones = wm.levels[level].rank1Unchecked(pos)
    if wm.levels[level].bitAtRaw(pos):
      result = result or (1'u64 shl shift)
      pos = wm.zeroCounts[level] + ones
    else:
      pos -= ones

func genericAccessRank(wm: WaveletMatrix, pos: int64):
    tuple[value: uint64, rankBefore: int64] =
  var current = pos
  var intervalLeft = 0'i64
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let currentOnes = wm.levels[level].rank1Unchecked(current)
    let leftOnes = wm.levels[level].rank1Unchecked(intervalLeft)
    if wm.levels[level].bitAtRaw(current):
      result.value = result.value or (1'u64 shl shift)
      current = wm.zeroCounts[level] + currentOnes
      intervalLeft = wm.zeroCounts[level] + leftOnes
    else:
      current -= currentOnes
      intervalLeft -= leftOnes
  result.rankBefore = current - intervalLeft

func genericRank(wm: WaveletMatrix, value: uint64, pos: int64): int64 =
  if pos < 0 or pos > wm.n:
    raise newException(IndexDefect, "position out of bounds")
  if wm.n == 0 or not valueFits8(value):
    return 0
  var left = 0'i64
  var right = pos
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    if ((value shr shift) and 1'u64) == 0:
      left -= wm.levels[level].rank1Unchecked(left)
      right -= wm.levels[level].rank1Unchecked(right)
    else:
      left = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(left)
      right = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(right)
  result = right - left

func genericSelect(wm: WaveletMatrix, value: uint64, k: int64): int64 =
  if k < 0 or wm.n == 0 or not valueFits8(value):
    return -1

  var left = 0'i64
  var right = wm.n
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    if ((value shr shift) and 1'u64) == 0:
      left -= wm.levels[level].rank1Unchecked(left)
      right -= wm.levels[level].rank1Unchecked(right)
    else:
      left = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(left)
      right = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(right)

  if k >= right - left:
    return -1

  var pos = left + k
  for level in countdown(wm.bitWidth - 1, 0):
    let shift = wm.bitWidth - level - 1
    if ((value shr shift) and 1'u64) == 0:
      pos = wm.levels[level].select0(pos)
    else:
      pos = wm.levels[level].select1(pos - wm.zeroCounts[level])
  result = pos

func median(samples: var seq[int64]): int64 =
  samples.sort()
  samples[samples.len div 2]

template elapsedNs(body: untyped): int64 =
  block:
    let started = getMonoTime()
    body
    (getMonoTime() - started).inNanoseconds

template measurePair(genericBody, fixedBody: untyped):
    tuple[genericNs, fixedNs: int64] =
  block:
    var genericSamples = newSeqOfCap[int64](measuredIters)
    var fixedSamples = newSeqOfCap[int64](measuredIters)
    for iteration in 0..<(warmupIters + measuredIters):
      var genericElapsed, fixedElapsed: int64
      if (iteration and 1) == 0:
        genericElapsed = elapsedNs:
          genericBody
        fixedElapsed = elapsedNs:
          fixedBody
      else:
        fixedElapsed = elapsedNs:
          fixedBody
        genericElapsed = elapsedNs:
          genericBody
      if iteration >= warmupIters:
        genericSamples.add genericElapsed
        fixedSamples.add fixedElapsed
    (genericSamples.median(), fixedSamples.median())

proc emit(c: BenchCase, query: string, measured:
    tuple[genericNs, fixedNs: int64]) =
  let genericNs = float(measured.genericNs) / queryCount.float
  let fixedNs = float(measured.fixedNs) / queryCount.float
  let speedup = genericNs / fixedNs
  echo &"{c.symbols},{c.distribution},{query},{genericNs:.3f},{fixedNs:.3f},{speedup:.4f}"

proc runCase(c: BenchCase) =
  let values = makeValues(c)
  let positions = makePositions(queryCount, c.symbols)
  let wm = genWaveletMatrix(values, bitWidth)

  var queryValues = newSeq[uint64](queryCount)
  var targets = newSeq[int64](queryCount)
  for i in 0..<queryCount:
    let pos = positions[i]
    queryValues[i] = values[int(pos)]
    targets[i] = genericRank(wm, queryValues[i], pos)

  for i in 0..<min(validationCount, queryCount):
    let pos = positions[i]
    let value = queryValues[i]
    doAssert genericAccess(wm, pos) == wm.access(pos)
    doAssert genericAccessRank(wm, pos) == wm.accessRankUnchecked(pos)
    doAssert genericRank(wm, value, pos) == wm.rank(value, pos)
    doAssert genericSelect(wm, value, targets[i]) == wm.select(value, targets[i])

  let access = measurePair:
    for pos in positions:
      sink = sink xor genericAccess(wm, pos)
  do:
    for pos in positions:
      sink = sink xor wm.access(pos)

  let accessRank = measurePair:
    for pos in positions:
      let item = genericAccessRank(wm, pos)
      sink = sink xor item.value xor uint64(item.rankBefore)
  do:
    for pos in positions:
      let item = wm.accessRankUnchecked(pos)
      sink = sink xor item.value xor uint64(item.rankBefore)

  let rank = measurePair:
    for i in 0..<queryCount:
      sink = sink xor uint64(genericRank(wm, queryValues[i], positions[i]))
  do:
    for i in 0..<queryCount:
      sink = sink xor uint64(wm.rank(queryValues[i], positions[i]))

  let select = measurePair:
    for i in 0..<queryCount:
      sink = sink xor uint64(genericSelect(wm, queryValues[i], targets[i]))
  do:
    for i in 0..<queryCount:
      sink = sink xor uint64(wm.select(queryValues[i], targets[i]))

  emit(c, "access", access)
  emit(c, "accessRank", accessRank)
  emit(c, "rank", rank)
  emit(c, "select", select)

when isMainModule:
  echo "symbols,distribution,query,generic_ns,fixed_depth_ns,speedup"
  for c in cases:
    runCase(c)
  stderr.writeLine("sink=", sink)
