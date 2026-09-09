## SuccinctBitVector と QuadVector の再現可能な性能比較です。

import std/[algorithm, monotimes, strformat, times]
import nbvs/[quad_vector, succinct_bit_vector]

type
  Distribution = enum
    uniform, sparse, dense, skewed

  BenchCase = object
    symbols: int64
    distribution: Distribution

const
  cases = [
    BenchCase(symbols: 65_536'i64, distribution: uniform),
    BenchCase(symbols: 65_536'i64, distribution: sparse),
    BenchCase(symbols: 65_536'i64, distribution: dense),
    BenchCase(symbols: 65_536'i64, distribution: skewed),
    BenchCase(symbols: 1_048_576'i64, distribution: uniform),
    BenchCase(symbols: 1_048_576'i64, distribution: sparse),
    BenchCase(symbols: 1_048_576'i64, distribution: dense),
    BenchCase(symbols: 1_048_576'i64, distribution: skewed),
    BenchCase(symbols: 16_777_216'i64, distribution: uniform),
    BenchCase(symbols: 16_777_216'i64, distribution: sparse),
    BenchCase(symbols: 16_777_216'i64, distribution: dense),
    BenchCase(symbols: 16_777_216'i64, distribution: skewed)
  ]
  warmupIters = 1
  measuredIters = 7
  queryCount = 100_000

var sink {.volatile.}: int64

func nextRand(state: var uint64): uint64 {.inline.} =
  state = state * 6364136223846793005'u64 + 1442695040888963407'u64
  state

func chooseSymbol(random: uint64, distribution: Distribution): uint8 {.inline.} =
  let percentile = random mod 100'u64
  case distribution
  of uniform:
    uint8(random and 3'u64)
  of sparse:
    if percentile < 97: 0'u8 else: uint8(1'u64 + random mod 3'u64)
  of dense:
    if percentile < 1: 0'u8 else: uint8(1'u64 + random mod 3'u64)
  of skewed:
    if percentile < 70: 0'u8
    elif percentile < 90: 1'u8
    elif percentile < 98: 2'u8
    else: 3'u8

proc makeSymbols(c: BenchCase): seq[uint8] =
  result = newSeq[uint8](int(c.symbols))
  var state = 0x1234_5678_9abc_def0'u64 xor uint64(c.symbols) xor
    (uint64(ord(c.distribution)) shl 48)
  for symbol in result.mitems:
    symbol = chooseSymbol(nextRand(state), c.distribution)

proc makePositions(symbolCount: int64): seq[int64] =
  result = newSeq[int64](queryCount)
  var state = 0x0ddc_0ffe_e15e_beef'u64 xor uint64(symbolCount)
  for position in result.mitems:
    position = int64(nextRand(state) mod uint64(symbolCount))

proc makeQuerySymbols(symbolCount: int64): seq[uint8] =
  result = newSeq[uint8](queryCount)
  var state = 0xfedc_ba98_7654_3210'u64 xor uint64(symbolCount)
  for symbol in result.mitems:
    symbol = uint8(nextRand(state) and 3'u64)

func median(samples: var seq[int64]): int64 =
  samples.sort()
  samples[samples.len div 2]

template measureMedian(body: untyped): int64 =
  block:
    var samples = newSeqOfCap[int64](measuredIters)
    for iteration in 0..<(warmupIters + measuredIters):
      let started = getMonoTime()
      body
      let elapsed = (getMonoTime() - started).inNanoseconds
      if iteration >= warmupIters:
        samples.add elapsed
    median(samples)

func sbvRawBytes(sbv: SuccinctBitVector): int64 =
  int64(sbv.data.len * sizeof(uint64))

func sbvRankOnlyBytes(sbv: SuccinctBitVector): int64 =
  ## 後方互換fieldを含むrank専用補助領域です。現仕様ではscalar/SIMDとも0です。
  int64((sbv.wordPairPrefix.len + sbv.blockPairPrefix.len) * sizeof(uint32))

func sbvSharedBytes(sbv: SuccinctBitVector): int64 =
  ## rank/selectの双方で利用する階層prefix treeです。
  int64(sbv.selectStorage.len * sizeof(uint64))

proc emit(c: BenchCase, kind: string,
          rawBytes, rankOnlyBytes, selectOnlyBytes, sharedBytes,
          buildNs, accessNs, rankNs, selectNs: int64) =
  let buildSeconds = float(buildNs) / 1_000_000_000.0
  let symbolThroughput = float(c.symbols) / buildSeconds / 1_000_000.0
  let payloadThroughput = float(rawBytes) / buildSeconds / 1024.0 / 1024.0
  let totalAuxBytes = rankOnlyBytes + selectOnlyBytes + sharedBytes
  echo &"{kind},{c.symbols},{c.distribution},{rawBytes},{rankOnlyBytes}," &
    &"{selectOnlyBytes},{sharedBytes},{totalAuxBytes}," &
    &"{float(buildNs) / 1_000_000.0:.6f},{symbolThroughput:.3f}," &
    &"{payloadThroughput:.3f},{float(accessNs) / queryCount.float:.3f}," &
    &"{float(rankNs) / queryCount.float:.3f}," &
    &"{float(selectNs) / queryCount.float:.3f}"

proc fillVectors(symbols: openArray[uint8], sbv: var SuccinctBitVector,
                 qv: var QuadVector) =
  # 同じsymbol列を使用し、SBVには下位bitを格納します。
  for index, symbol in symbols:
    if (symbol and 1'u8) != 0:
      sbv.setBit(int64(index))
    qv.setSymbol(int64(index), symbol)

proc runCase(c: BenchCase) =
  let symbols = makeSymbols(c)
  let positions = makePositions(c.symbols)
  let querySymbols = makeQuerySymbols(c.symbols)
  var sbv = genSuccinctBitVector(c.symbols)
  var qv = genQuadVector(c.symbols)
  fillVectors(symbols, sbv, qv)

  let sbvBuildNs = measureMedian:
    sbv.build()
    sink = sink xor sbv.totalOnes
  let qvBuildNs = measureMedian:
    qv.build()
    sink = sink xor qv.totalCounts[0]

  var sbvTargets = newSeq[int64](queryCount)
  var qvTargets = newSeq[int64](queryCount)
  var targetState = 0xa5a5_5a5a_c3c3_3c3c'u64 xor uint64(c.symbols)
  for index in 0..<queryCount:
    let symbol = int(querySymbols[index])
    let sbvTotal = if (symbol and 1) == 0: sbv.totalZeros else: sbv.totalOnes
    sbvTargets[index] = int64(nextRand(targetState) mod uint64(sbvTotal))
    qvTargets[index] = int64(nextRand(targetState) mod uint64(qv.totalCounts[symbol]))

  let sbvAccessNs = measureMedian:
    for position in positions:
      sink = sink xor int64(sbv.access(position))
  let qvAccessNs = measureMedian:
    for position in positions:
      sink = sink xor int64(qv.access(position))

  let sbvRankNs = measureMedian:
    for index in 0..<queryCount:
      let symbol = int(querySymbols[index])
      sink = sink xor (if (symbol and 1) == 0:
        sbv.rank0(positions[index]) else: sbv.rank1(positions[index]))
  let qvRankNs = measureMedian:
    for index in 0..<queryCount:
      sink = sink xor qv.rank(int(querySymbols[index]), positions[index])

  let sbvSelectNs = measureMedian:
    for index in 0..<queryCount:
      let symbol = int(querySymbols[index])
      sink = sink xor (if (symbol and 1) == 0:
        sbv.select0(sbvTargets[index]) else: sbv.select1(sbvTargets[index]))
  let qvSelectNs = measureMedian:
    for index in 0..<queryCount:
      sink = sink xor qv.select(int(querySymbols[index]), qvTargets[index])

  emit(c, "SBV", sbvRawBytes(sbv), sbvRankOnlyBytes(sbv), 0,
       sbvSharedBytes(sbv), sbvBuildNs, sbvAccessNs, sbvRankNs, sbvSelectNs)
  emit(c, "QV", qv.rawBytes, qv.rankAuxiliaryBytes, qv.selectAuxiliaryBytes, 0,
       qvBuildNs, qvAccessNs, qvRankNs, qvSelectNs)

when isMainModule:
  echo "structure,symbols,distribution,payload_bytes,rank_only_aux_bytes," &
    "select_only_aux_bytes,shared_aux_bytes,total_aux_bytes,build_p50_ms," &
    "build_msymbols_s,build_payload_mib_s,access_p50_ns,rank_p50_ns,select_p50_ns"
  for c in cases:
    runCase(c)
  stderr.writeLine("sink=", sink)
