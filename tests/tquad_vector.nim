import nbvs/quad_vector
import ./test_common

func naiveRank(values: seq[uint8], symbol: uint8, pos: int64): int64 =
  for i in 0..<int(pos):
    if values[i] == symbol:
      inc result

func naiveSelect(values: seq[uint8], symbol: uint8, k: int64): int64 =
  if k < 0:
    return -1
  var seen = 0'i64
  for i, value in values:
    if value == symbol:
      if seen == k:
        return int64(i)
      inc seen
  -1

proc checkAgainstNaive(values: seq[uint8]) =
  var qv = genQuadVector(int64(values.len))
  for i, value in values:
    qv[int64(i)] = value
  qv.build()

  doAssert qv.lenOfSymbols == int64(values.len)
  for i, value in values:
    doAssert qv[int64(i)] == value
    doAssert qv.access(int64(i)) == value

  for symbol in 0'u8..3'u8:
    doAssert qv.rank(int(symbol), 0) == 0
    doAssert qv.rank(int(symbol), int64(values.len)) ==
      naiveRank(values, symbol, int64(values.len))

    for pos in 0..values.len:
      if values.len <= 4096 or pos mod 97 == 0 or pos == values.len:
        doAssert qv.rank(int(symbol), int64(pos)) ==
          naiveRank(values, symbol, int64(pos))

    let total = naiveRank(values, symbol, int64(values.len))
    for k in -1'i64..total:
      doAssert qv.select(int(symbol), k) == naiveSelect(values, symbol, k)

  for pos in 0..<values.len:
    if values.len <= 4096 or pos mod 113 == 0:
      for symbol in 0'u8..3'u8:
        doAssert qv.rankIncl(int(symbol), int64(pos)) ==
          naiveRank(values, symbol, int64(pos + 1))

block constructorAndErrors:
  expectRaises(ValueError): discard genQuadVector(-1)
  expectRaises(ValueError): discard genQuadVector(MaxQuadVectorSymbols + 1)

  var qv = genQuadVector(10)
  doAssert qv.maxOfSymbols == 10
  doAssert qv.lenOfSymbols == 10
  doAssert qv.data.bitWidth == 2
  doAssert not qv.isCalced
  doAssert $qv == "0000000000"

  expectRaises(IndexDefect): discard qv[-1]
  expectRaises(IndexDefect): discard qv[10]
  expectRaises(IndexDefect): qv[-1] = 1'u8
  expectRaises(ValueError): qv[0] = 4'u8
  expectRaises(ValueError): discard qv.rank(4, 0)
  expectRaises(ValueError): discard qv.rank(0, 0)
  expectRaises(ValueError): discard qv.select(0, 0)

block empty:
  var qv = genQuadVector(0)
  qv.build()
  for symbol in 0..3:
    doAssert qv.totalCounts[symbol] == 0
    doAssert qv.rank(symbol, 0) == 0
    doAssert qv.select(symbol, 0) == -1
  doAssert qv.rawBytes == 0
  doAssert qv.selectAuxiliaryBytes == 0

block smallPatterns:
  checkAgainstNaive(@[0'u8])
  checkAgainstNaive(@[0'u8, 1, 2, 3, 3, 2, 1, 0])

  var values = newSeq[uint8](513)
  for i in 0..<values.len:
    values[i] = uint8((i * 3 + i div 7) mod 4)
  checkAgainstNaive(values)

block blockAndSuperBlockBoundaries:
  var values = newSeq[uint8](9000)
  for i in 0..<values.len:
    values[i] = uint8((i xor (i shr 3)) and 3)
  for pos in [0, 511, 512, 513, 4095, 4096, 4097, 8191, 8192, 8999]:
    values[pos] = uint8(pos mod 4)
  checkAgainstNaive(values)

block selectSamplingBoundaries:
  var values = newSeq[uint8](20_000)
  for i in 0..<values.len:
    if i mod 5 == 0:
      values[i] = 3
    elif i mod 3 == 0:
      values[i] = 2
    else:
      values[i] = uint8(i and 1)
  checkAgainstNaive(values)

block rebuildAfterMutation:
  var qv = genQuadVector(9000)
  for i in 0'i64..<qv.lenOfSymbols:
    qv[i] = uint8(i mod 4)
  qv.build()
  doAssert qv.rank3(9000) == 2250

  for i in 0'i64..<qv.lenOfSymbols:
    if i mod 17 == 0:
      qv[i] = 3'u8
  doAssert not qv.isCalced
  expectRaises(ValueError): discard qv.rank3(9000)
  qv.build()

  var values = newSeq[uint8](9000)
  for i in 0..<values.len:
    values[i] = uint8(i mod 4)
    if i mod 17 == 0:
      values[i] = 3'u8
  for symbol in 0..3:
    doAssert qv.rank(symbol, 9000) == naiveRank(values, uint8(symbol), 9000)
    let total = qv.totalCounts[symbol]
    if total > 0:
      doAssert qv.select(symbol, total - 1) ==
        naiveSelect(values, uint8(symbol), total - 1)

block wrapperApis:
  var qv = genQuadVector(8)
  for i, value in [0'u8, 1, 2, 3, 0, 1, 2, 3]:
    qv[int64(i)] = value
  qv.build()
  doAssert qv.rank0(8) == 2
  doAssert qv.rank1(8) == 2
  doAssert qv.rank2(8) == 2
  doAssert qv.rank3(8) == 2
  doAssert qv.rank0Incl(0) == 1
  doAssert qv.rank3Incl(3) == 1
  doAssert qv.select0(1) == 4
  doAssert qv.select1(1) == 5
  doAssert qv.select2(1) == 6
  doAssert qv.select3(1) == 7

block exactAuxiliaryBudgetAtAlignedSize:
  # 64 個の完全な superblock と均等な 4 値分布を使い、末尾の丸め誤差をなくします。
  # rank 補助構造は payload のちょうど 6.25%、select sample はちょうど 1.5625% です。
  const N = 4096 * 64
  var qv = genQuadVector(N)
  for i in 0..<N:
    qv[int64(i)] = uint8(i and 3)
  qv.build()

  doAssert qv.rawBytes == 65_536
  doAssert qv.rankAuxiliaryBytes == qv.rawBytes div 16
  doAssert qv.selectAuxiliaryBytes == qv.rawBytes div 64
  doAssert qv.auxiliaryBytes * 10_000 div qv.rawBytes == 781
