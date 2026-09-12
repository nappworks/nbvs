## Binary WaveletMatrix と QuadWaveletMatrix の end-to-end 比較です。
##
## 同じ入力、固定bit幅、同じrandom position/value/occurrenceを使い、
## access / accessRank / rank / select を比較します。query測定前に意味等価性を
## doAssertで検証します。
##
## PR #18 の全再測定では長時間実行を避けるため、queryは warmup 1回 + 測定3回、
## 20,000件、buildは測定1回とします。8-bitでは WM=8 levels / QWM=4 levels の
## 比較を65K / 1M / 16Mで行い、cacheに収まりやすいケースからlarge working setまで
## level半減の効果を確認します。
##
## 結果は以下へ保存してください。
##
##   nimble benchWmQwm > benchmarks/results/wm_quad_wavelet_matrix_scalar.csv
##   nimble benchWmQwmSimd > benchmarks/results/wm_quad_wavelet_matrix_simd.csv

import std/[algorithm, monotimes, strformat, times]
import nbvs/[wavelet_matrix, quad_wavelet_matrix]

type
  Distribution = enum
    uniform, skewed

  BenchCase = object
    symbols: int
    bitWidth: int
    distribution: Distribution

const
  cases = [
    BenchCase(symbols: 65_536, bitWidth: 8, distribution: uniform),
    BenchCase(symbols: 65_536, bitWidth: 8, distribution: skewed),
    BenchCase(symbols: 65_536, bitWidth: 64, distribution: uniform),
    BenchCase(symbols: 65_536, bitWidth: 64, distribution: skewed),
    BenchCase(symbols: 1_048_576, bitWidth: 8, distribution: uniform),
    BenchCase(symbols: 1_048_576, bitWidth: 8, distribution: skewed),
    BenchCase(symbols: 1_048_576, bitWidth: 16, distribution: uniform),
    BenchCase(symbols: 1_048_576, bitWidth: 32, distribution: uniform),
    BenchCase(symbols: 1_048_576, bitWidth: 64, distribution: uniform),
    BenchCase(symbols: 1_048_576, bitWidth: 64, distribution: skewed),
    BenchCase(symbols: 16_777_216, bitWidth: 8, distribution: uniform),
    BenchCase(symbols: 16_777_216, bitWidth: 8, distribution: skewed),
    BenchCase(symbols: 16_777_216, bitWidth: 64, distribution: uniform),
    BenchCase(symbols: 16_777_216, bitWidth: 64, distribution: skewed)
  ]
  warmupIters = 1
  queryMeasuredIters = 3
  buildMeasuredIters = 1
  queryCount = 20_000
  validationCount = 512

var sink {.volatile.}: uint64

func nextRand(state: var uint64): uint64 {.inline.} =
  state = state * 6364136223846793005'u64 + 1442695040888963407'u64
  state

func maskForWidth(bitWidth: int): uint64 {.inline.} =
  if bitWidth >= 64: uint64.high
  elif bitWidth <= 0: 0'u64
  else: (1'u64 shl bitWidth) - 1'u64

proc makeValues(c: BenchCase): seq[uint64] =
  result = newSeq[uint64](c.symbols)
  var state = 0x9e37_79b9_7f4a_7c15'u64 xor uint64(c.symbols) xor
    (uint64(c.bitWidth) shl 48)
  let mask = maskForWidth(c.bitWidth)
  for value in result.mitems:
    let random = nextRand(state)
    case c.distribution
    of uniform:
      value = random and mask
    of skewed:
      # 8-bitでもskewを残せるようhot setは下位4 bitへ寄せます。
      # wider caseでは残り5%をfull-width randomにして上位levelも通します。
      if random mod 100'u64 < 95'u64:
        value = (random and 15'u64) and mask
      else:
        value = nextRand(state) and mask

  # fixed bitWidthの上位levelも実データで通るよう、表現可能ならhigh bitを最低1件立てます。
  if result.len > 0 and c.bitWidth > 0:
    let highBit = min(c.bitWidth - 1, 63)
    result[^1] = result[^1] or (1'u64 shl highBit)

proc makePositions(count, symbols: int): seq[int64] =
  result = newSeq[int64](count)
  var state = 0x243f_6a88_85a3_08d3'u64 xor uint64(symbols)
  for pos in result.mitems:
    pos = int64(nextRand(state) mod uint64(symbols))

func median(samples: var seq[int64]): int64 =
  samples.sort()
  samples[samples.len div 2]

template measureMedian(iters: static[int], body: untyped): int64 =
  block:
    var samples = newSeqOfCap[int64](iters)
    for iteration in 0..<(warmupIters + iters):
      let started = getMonoTime()
      body
      let elapsed = (getMonoTime() - started).inNanoseconds
      if iteration >= warmupIters:
        samples.add elapsed
    median(samples)

template measureBuild(body: untyped): int64 =
  block:
    var samples = newSeqOfCap[int64](buildMeasuredIters)
    for iteration in 0..<buildMeasuredIters:
      let started = getMonoTime()
      body
      samples.add (getMonoTime() - started).inNanoseconds
    median(samples)

func wmRawBytes(wm: WaveletMatrix): int64 =
  for level in 0..<wm.bitWidth:
    result += int64(wm.levels[level].data.len * sizeof(uint64))

func wmAuxBytes(wm: WaveletMatrix): int64 =
  for level in 0..<wm.bitWidth:
    result += int64(wm.levels[level].selectStorage.len * sizeof(uint64))

proc validateEquivalent(wm: WaveletMatrix, qwm: QuadWaveletMatrix,
                        values: openArray[uint64], positions: openArray[int64]) =
  doAssert wm.n == qwm.n
  doAssert wm.bitWidth == qwm.bitWidth
  let checks = min(validationCount, positions.len)
  for i in 0..<checks:
    let pos = positions[i]
    let value = values[int(pos)]
    doAssert wm.access(pos) == qwm.access(pos)
    doAssert wm.accessRank(pos) == qwm.accessRank(pos)
    doAssert wm.rank(value, pos) == qwm.rank(value, pos)
    doAssert wm.rank(value, wm.n) == qwm.rank(value, qwm.n)
    let ordinal = wm.rank(value, pos)
    doAssert wm.select(value, ordinal) == pos
    doAssert qwm.select(value, ordinal) == pos

proc emit(c: BenchCase, structure: string, levels: int,
          payloadBytes, auxBytes, buildNs, accessNs, accessRankNs,
          rankNs, selectNs: int64) =
  let totalBytes = payloadBytes + auxBytes
  echo &"{c.symbols},{c.bitWidth},{c.distribution},{structure},{levels}," &
    &"{payloadBytes},{auxBytes},{totalBytes}," &
    &"{float(buildNs) / 1_000_000.0:.6f}," &
    &"{float(accessNs) / queryCount.float:.3f}," &
    &"{float(accessRankNs) / queryCount.float:.3f}," &
    &"{float(rankNs) / queryCount.float:.3f}," &
    &"{float(selectNs) / queryCount.float:.3f}"

proc runCase(c: BenchCase) =
  let values = makeValues(c)
  let positions = makePositions(queryCount, c.symbols)

  let wmBuildNs = measureBuild:
    let built = genWaveletMatrix(values, c.bitWidth)
    sink = sink xor uint64(built.levels[0].totalOnes)
  let qwmBuildNs = measureBuild:
    let built = genQuadWaveletMatrix(values, c.bitWidth)
    sink = sink xor uint64(built.levels[0].totalCounts[3])

  let wm = genWaveletMatrix(values, c.bitWidth)
  let qwm = genQuadWaveletMatrix(values, c.bitWidth)
  validateEquivalent(wm, qwm, values, positions)

  var queryValues = newSeq[uint64](queryCount)
  var targets = newSeq[int64](queryCount)
  for i in 0..<queryCount:
    let pos = positions[i]
    queryValues[i] = values[int(pos)]
    # position自身のvalueなので、rankBeforeは必ずvalidなselect occurrenceです。
    targets[i] = wm.rank(queryValues[i], pos)

  let wmAccessNs = measureMedian(queryMeasuredIters):
    for pos in positions:
      sink = sink xor wm.access(pos)
  let qwmAccessNs = measureMedian(queryMeasuredIters):
    for pos in positions:
      sink = sink xor qwm.access(pos)

  let wmAccessRankNs = measureMedian(queryMeasuredIters):
    for pos in positions:
      let item = wm.accessRankUnchecked(pos)
      sink = sink xor item.value xor uint64(item.rankBefore)
  let qwmAccessRankNs = measureMedian(queryMeasuredIters):
    for pos in positions:
      let item = qwm.accessRankUnchecked(pos)
      sink = sink xor item.value xor uint64(item.rankBefore)

  let wmRankNs = measureMedian(queryMeasuredIters):
    for i in 0..<queryCount:
      sink = sink xor uint64(wm.rank(queryValues[i], positions[i]))
  let qwmRankNs = measureMedian(queryMeasuredIters):
    for i in 0..<queryCount:
      sink = sink xor uint64(qwm.rank(queryValues[i], positions[i]))

  let wmSelectNs = measureMedian(queryMeasuredIters):
    for i in 0..<queryCount:
      sink = sink xor uint64(wm.select(queryValues[i], targets[i]))
  let qwmSelectNs = measureMedian(queryMeasuredIters):
    for i in 0..<queryCount:
      sink = sink xor uint64(qwm.select(queryValues[i], targets[i]))

  emit(c, "WM", wm.bitWidth, wm.wmRawBytes, wm.wmAuxBytes,
       wmBuildNs, wmAccessNs, wmAccessRankNs, wmRankNs, wmSelectNs)
  emit(c, "QWM", qwm.levelCount, qwm.rawBytes, qwm.auxiliaryBytes,
       qwmBuildNs, qwmAccessNs, qwmAccessRankNs, qwmRankNs, qwmSelectNs)

when isMainModule:
  echo "symbols,bit_width,distribution,structure,levels,payload_bytes,aux_bytes," &
    "total_bytes,build_p50_ms,access_p50_ns,access_rank_p50_ns,rank_p50_ns," &
    "select_p50_ns"
  for c in cases:
    runCase(c)
  stderr.writeLine("sink=", sink)
