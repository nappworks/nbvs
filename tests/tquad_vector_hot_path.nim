import nbvs/quad_vector

func naiveRank(values: openArray[uint8], symbol: uint8, pos: int64): int64 =
  for i in 0..<int(pos):
    if values[i] == symbol:
      inc result

block fusedAccessRankAndRankPair:
  var values = newSeq[uint8](9001)
  var qv = genQuadVector(int64(values.len))
  for i in 0..<values.len:
    let value = uint8(((i * 13) xor (i shr 2)) and 3)
    values[i] = value
    qv[int64(i)] = value
  qv.build()

  for pos in [0'i64, 1, 31, 32, 511, 512, 513, 4095, 4096, 4097, 8191, 9000]:
    let fused = qv.accessRankUnchecked(pos)
    doAssert fused.symbol == values[int(pos)]
    doAssert fused.rankBefore ==
      naiveRank(values, fused.symbol, pos)
    doAssert qv.accessRank(pos) == fused

  for symbol in 0..3:
    for bounds in [(0'i64, 0'i64), (0'i64, 31'i64), (17'i64, 31'i64),
                   (31'i64, 32'i64), (32'i64, 511'i64),
                   (100'i64, 500'i64), (500'i64, 513'i64),
                   (512'i64, 900'i64), (4000'i64, 4096'i64),
                   (4090'i64, 4100'i64), (8192'i64, 9001'i64)]:
      let pair = qv.rankPairUnchecked(symbol, bounds[0], bounds[1])
      doAssert pair.leftRank == qv.rankUnchecked(symbol, bounds[0])
      doAssert pair.rightRank == qv.rankUnchecked(symbol, bounds[1])

block uncheckedSelectMatchesPublicApi:
  const N = 262_144
  var qv = genQuadVector(N)
  for i in 0..<N:
    qv[int64(i)] = uint8((i xor (i shr 5)) and 3)
  qv.build()

  for symbol in 0..3:
    let total = qv.totalCounts[symbol]
    if total > 0:
      for k in [0'i64, min(1'i64, total - 1), total div 3,
                total div 2, total - 1]:
        doAssert qv.selectUnchecked(symbol, k) == qv.select(symbol, k)

block selectStorageUsesExact32BitsPerSample:
  const N = 4096 * 64
  var qv = genQuadVector(N)
  for i in 0..<N:
    qv[int64(i)] = uint8(i and 3)
  qv.build()

  var sampleCount = 0'i64
  for symbol in 0..3:
    sampleCount += int64(qv.selectSamples[symbol].len)
  doAssert qv.selectAuxiliaryBytes == sampleCount * int64(sizeof(uint32))
  doAssert qv.selectAuxiliaryBytes == qv.rawBytes div 64
