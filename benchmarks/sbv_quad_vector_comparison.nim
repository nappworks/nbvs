## SuccinctBitVector と QuadVector の再現可能な性能比較です。
##
## 比較は2種類に分けます。
##
## * `primitive`: SBV 1個とQV 1個の単体primitive cost比較です。
##   SBVには4値symbolの下位1 bitだけを格納するため、意味的に同一のquery比較ではありません。
## * `wavelet4`: 4値alphabetを表現する Binary Wavelet Matrix 2 level相当の
##   2個のSBVと、Quad Wavelet Matrix 1 level相当の1個のQVを比較します。
##   access/rank/selectはいずれも同じ4値symbol列に対する同一意味のqueryです。
##
## buildは初回構築 (`build_cold`) と、構築済みmetadataを再利用する
## 再構築 (`build_rebuild`) を分離して測定します。

import std/[algorithm, monotimes, strformat, times]
import nbvs/[quad_vector, succinct_bit_vector]

type
  Distribution = enum
    uniform, sparse, dense, skewed

  BenchCase = object
    symbols: int64
    distribution: Distribution

  BinaryTwoLevel = object
    ## 4値alphabetを2個のSBVで表すBinary Wavelet Matrix 2 level相当のpayloadです。
    ## `high` は元列の上位bit、`low` はhigh bitでstable partitionした後の下位bitです。
    high: SuccinctBitVector
    low: SuccinctBitVector
    zerosHigh: int64
    zerosLow: int64
    counts: array[4, int64]
    finalStarts: array[4, int64]

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

func binaryRawBytes(binary: BinaryTwoLevel): int64 =
  binary.high.sbvRawBytes + binary.low.sbvRawBytes

func binaryRankOnlyBytes(binary: BinaryTwoLevel): int64 =
  binary.high.sbvRankOnlyBytes + binary.low.sbvRankOnlyBytes

func binarySharedBytes(binary: BinaryTwoLevel): int64 =
  binary.high.sbvSharedBytes + binary.low.sbvSharedBytes

proc emit(c: BenchCase, comparison, kind: string,
          rawBytes, rankOnlyBytes, selectOnlyBytes, sharedBytes,
          buildColdNs, buildRebuildNs,
          accessNs, rankNs, selectNs: int64) =
  let coldSeconds = float(buildColdNs) / 1_000_000_000.0
  let rebuildSeconds = float(buildRebuildNs) / 1_000_000_000.0
  let coldSymbolThroughput = float(c.symbols) / coldSeconds / 1_000_000.0
  let rebuildSymbolThroughput = float(c.symbols) / rebuildSeconds / 1_000_000.0
  let coldPayloadThroughput = float(rawBytes) / coldSeconds / 1024.0 / 1024.0
  let rebuildPayloadThroughput = float(rawBytes) / rebuildSeconds / 1024.0 / 1024.0
  let totalAuxBytes = rankOnlyBytes + selectOnlyBytes + sharedBytes
  echo &"{comparison},{kind},{c.symbols},{c.distribution},{rawBytes},{rankOnlyBytes}," &
    &"{selectOnlyBytes},{sharedBytes},{totalAuxBytes}," &
    &"{float(buildColdNs) / 1_000_000.0:.6f}," &
    &"{float(buildRebuildNs) / 1_000_000.0:.6f}," &
    &"{coldSymbolThroughput:.3f},{rebuildSymbolThroughput:.3f}," &
    &"{coldPayloadThroughput:.3f},{rebuildPayloadThroughput:.3f}," &
    &"{float(accessNs) / queryCount.float:.3f}," &
    &"{float(rankNs) / queryCount.float:.3f}," &
    &"{float(selectNs) / queryCount.float:.3f}"

proc fillPrimitiveVectors(symbols: openArray[uint8],
                          sbv: var SuccinctBitVector,
                          qv: var QuadVector) =
  ## primitive比較ではSBVに下位1bit、QVに4値symbolをそのまま格納します。
  for index, symbol in symbols:
    if (symbol and 1'u8) != 0:
      sbv.setBit(int64(index))
    qv.setSymbol(int64(index), symbol)

proc makeBinaryTwoLevel(symbols: openArray[uint8]): BinaryTwoLevel =
  ## 4値alphabetに対するBinary Wavelet Matrix 2 level相当のpayloadを構築します。
  let n = int64(symbols.len)
  result.high = genSuccinctBitVector(n)
  result.low = genSuccinctBitVector(n)

  for symbol in symbols:
    inc result.counts[int(symbol)]

  result.zerosHigh = result.counts[0] + result.counts[1]
  result.zerosLow = result.counts[0] + result.counts[2]

  # 2 level目の入力は、1 level目(high bit)でstable partitionした順序です。
  var nextHighZero = 0'i64
  var nextHighOne = result.zerosHigh
  for index, symbol in symbols:
    let highBit = int((symbol shr 1) and 1'u8)
    let lowBit = symbol and 1'u8
    if highBit != 0:
      result.high.setBit(int64(index))

    let dest =
      if highBit == 0:
        let p = nextHighZero
        inc nextHighZero
        p
      else:
        let p = nextHighOne
        inc nextHighOne
        p
    if lowBit != 0:
      result.low.setBit(dest)

  # 2 level処理後はlow bitでstable partitionされるため、最終bucket順は0,2,1,3です。
  var cursor = 0'i64
  for symbol in [0, 2, 1, 3]:
    result.finalStarts[symbol] = cursor
    cursor += result.counts[symbol]

proc freshSbvPayload(prepared: SuccinctBitVector): SuccinctBitVector =
  ## payload seqだけ共有し、rank/select metadataはconstructor直後のcold状態にします。
  result = genSuccinctBitVector(prepared.lenOfBits)
  result.data = prepared.data

proc freshQvPayload(prepared: QuadVector): QuadVector =
  ## payload PackedArrayだけ共有し、rank/select metadataはconstructor直後のcold状態にします。
  result = genQuadVector(prepared.lenOfSymbols)
  result.data = prepared.data

proc freshBinaryPayload(prepared: BinaryTwoLevel): BinaryTwoLevel =
  result.high = freshSbvPayload(prepared.high)
  result.low = freshSbvPayload(prepared.low)
  result.zerosHigh = prepared.zerosHigh
  result.zerosLow = prepared.zerosLow
  result.counts = prepared.counts
  result.finalStarts = prepared.finalStarts

proc build(binary: var BinaryTwoLevel) =
  binary.high.build()
  binary.low.build()

proc measureColdBuild(prepared: SuccinctBitVector): int64 =
  var samples = newSeqOfCap[int64](measuredIters)
  for iteration in 0..<(warmupIters + measuredIters):
    var sbv = freshSbvPayload(prepared)
    let started = getMonoTime()
    sbv.build()
    let elapsed = (getMonoTime() - started).inNanoseconds
    sink = sink xor sbv.totalOnes
    if iteration >= warmupIters:
      samples.add elapsed
  median(samples)

proc measureColdBuild(prepared: QuadVector): int64 =
  var samples = newSeqOfCap[int64](measuredIters)
  for iteration in 0..<(warmupIters + measuredIters):
    var qv = freshQvPayload(prepared)
    let started = getMonoTime()
    qv.build()
    let elapsed = (getMonoTime() - started).inNanoseconds
    sink = sink xor qv.totalCounts[0]
    if iteration >= warmupIters:
      samples.add elapsed
  median(samples)

proc measureColdBuild(prepared: BinaryTwoLevel): int64 =
  var samples = newSeqOfCap[int64](measuredIters)
  for iteration in 0..<(warmupIters + measuredIters):
    var binary = freshBinaryPayload(prepared)
    let started = getMonoTime()
    binary.build()
    let elapsed = (getMonoTime() - started).inNanoseconds
    sink = sink xor binary.high.totalOnes xor binary.low.totalOnes
    if iteration >= warmupIters:
      samples.add elapsed
  median(samples)

func binaryAccess(binary: BinaryTwoLevel, pos: int64): int64 {.inline.} =
  ## Binary WM 2 levelを辿り、元の4値symbolを復元します。
  let highBit = if binary.high.access(pos): 1 else: 0
  let mapped =
    if highBit == 0:
      binary.high.rank0(pos)
    else:
      binary.zerosHigh + binary.high.rank1(pos)
  let lowBit = if binary.low.access(mapped): 1 else: 0
  int64((highBit shl 1) or lowBit)

func binaryRank(binary: BinaryTwoLevel, symbol: int, pos: int64): int64 {.inline.} =
  ## Binary WM 2 levelで`[0,pos)`に含まれる4値symbolの個数を返します。
  let highBit = (symbol shr 1) and 1
  let lowBit = symbol and 1
  let groupStart = if highBit == 0: 0'i64 else: binary.zerosHigh
  let mappedEnd =
    if highBit == 0:
      binary.high.rank0(pos)
    else:
      binary.zerosHigh + binary.high.rank1(pos)

  if lowBit == 0:
    binary.low.rank0(mappedEnd) - binary.low.rank0(groupStart)
  else:
    binary.low.rank1(mappedEnd) - binary.low.rank1(groupStart)

func binarySelect(binary: BinaryTwoLevel, symbol: int, k: int64): int64 {.inline.} =
  ## Binary WM 2 levelを逆に辿り、0-basedでk番目の4値symbol位置を返します。
  if k < 0 or k >= binary.counts[symbol]:
    return -1

  let highBit = (symbol shr 1) and 1
  let lowBit = symbol and 1
  let finalPos = binary.finalStarts[symbol] + k
  let level1Pos =
    if lowBit == 0:
      binary.low.select0(finalPos)
    else:
      binary.low.select1(finalPos - binary.zerosLow)

  if highBit == 0:
    binary.high.select0(level1Pos)
  else:
    binary.high.select1(level1Pos - binary.zerosHigh)

proc runCase(c: BenchCase) =
  let symbols = makeSymbols(c)
  let positions = makePositions(c.symbols)
  let querySymbols = makeQuerySymbols(c.symbols)

  var sbv = genSuccinctBitVector(c.symbols)
  var qv = genQuadVector(c.symbols)
  fillPrimitiveVectors(symbols, sbv, qv)
  var binary = makeBinaryTwoLevel(symbols)

  # cold buildは毎回fresh metadataから開始し、rebuildは構築済みstorageを再利用します。
  let sbvColdBuildNs = measureColdBuild(sbv)
  let qvColdBuildNs = measureColdBuild(qv)
  let binaryColdBuildNs = measureColdBuild(binary)

  sbv.build()
  qv.build()
  binary.build()

  let sbvRebuildNs = measureMedian:
    sbv.build()
    sink = sink xor sbv.totalOnes
  let qvRebuildNs = measureMedian:
    qv.build()
    sink = sink xor qv.totalCounts[0]
  let binaryRebuildNs = measureMedian:
    binary.build()
    sink = sink xor binary.high.totalOnes xor binary.low.totalOnes

  var sbvTargets = newSeq[int64](queryCount)
  var exactTargets = newSeq[int64](queryCount)
  var targetState = 0xa5a5_5a5a_c3c3_3c3c'u64 xor uint64(c.symbols)
  for index in 0..<queryCount:
    let symbol = int(querySymbols[index])
    let sbvTotal = if (symbol and 1) == 0: sbv.totalZeros else: sbv.totalOnes
    sbvTargets[index] = int64(nextRand(targetState) mod uint64(sbvTotal))
    # wavelet4比較ではBinary2/QVで完全に同じ4値symbolとoccurrenceを使用します。
    exactTargets[index] = int64(nextRand(targetState) mod uint64(qv.totalCounts[symbol]))

  # primitive: 1個のSBVと1個のQVの単体コスト比較です。
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
      sink = sink xor qv.select(int(querySymbols[index]), exactTargets[index])

  emit(c, "primitive", "SBV1", sbvRawBytes(sbv), sbvRankOnlyBytes(sbv), 0,
       sbvSharedBytes(sbv), sbvColdBuildNs, sbvRebuildNs,
       sbvAccessNs, sbvRankNs, sbvSelectNs)
  emit(c, "primitive", "QV1", qv.rawBytes, qv.rankAuxiliaryBytes,
       qv.selectAuxiliaryBytes, 0, qvColdBuildNs, qvRebuildNs,
       qvAccessNs, qvRankNs, qvSelectNs)

  # wavelet4: 同一4値queryをBinary WM 2 level相当とQuad WM 1 level相当で比較します。
  let binaryAccessNs = measureMedian:
    for position in positions:
      sink = sink xor binary.binaryAccess(position)
  let binaryRankNs = measureMedian:
    for index in 0..<queryCount:
      sink = sink xor binary.binaryRank(int(querySymbols[index]), positions[index])
  let binarySelectNs = measureMedian:
    for index in 0..<queryCount:
      sink = sink xor binary.binarySelect(int(querySymbols[index]), exactTargets[index])

  emit(c, "wavelet4", "BinaryWM2", binary.binaryRawBytes,
       binary.binaryRankOnlyBytes, 0, binary.binarySharedBytes,
       binaryColdBuildNs, binaryRebuildNs,
       binaryAccessNs, binaryRankNs, binarySelectNs)
  emit(c, "wavelet4", "QuadWM1", qv.rawBytes, qv.rankAuxiliaryBytes,
       qv.selectAuxiliaryBytes, 0, qvColdBuildNs, qvRebuildNs,
       qvAccessNs, qvRankNs, qvSelectNs)

when isMainModule:
  echo "comparison,structure,symbols,distribution,payload_bytes,rank_only_aux_bytes," &
    "select_only_aux_bytes,shared_aux_bytes,total_aux_bytes," &
    "build_cold_p50_ms,build_rebuild_p50_ms," &
    "build_cold_msymbols_s,build_rebuild_msymbols_s," &
    "build_cold_payload_mib_s,build_rebuild_payload_mib_s," &
    "access_p50_ns,rank_p50_ns,select_p50_ns"
  for c in cases:
    runCase(c)
  stderr.writeLine("sink=", sink)
