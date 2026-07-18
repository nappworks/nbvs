import std/bitops
import nbvs/succinct_bit_vector
import ./test_common

func naiveRank1(bits: seq[bool], pos: int64): int64 =
  for i in 0..<int(pos):
    if bits[i]: inc result

func naiveSelect(bits: seq[bool], value: bool, k: int64): int64 =
  var seen = 0'i64
  for i, b in bits:
    if b == value:
      if seen == k: return int64(i)
      inc seen
  -1

proc checkAgainstNaive(n: int64, ones: openArray[int64]) =
  var sbv = genSuccinctBitVector(n)
  var bits = newSeq[bool](int(n))
  for pos in ones:
    sbv[pos] = true
    bits[int(pos)] = true
  sbv.build()

  doAssert sbv.totalOnes == naiveRank1(bits, n)
  doAssert sbv.totalZeros == n - sbv.totalOnes
  doAssert sbv.rank1(0) == 0
  doAssert sbv.rank0(0) == 0
  doAssert sbv.rank1(n) == sbv.totalOnes
  doAssert sbv.rank0(n) == sbv.totalZeros

  let checkpoints = @[0'i64, 1, 2, 63, 64, 65, 511, 512, 513, 8191, 8192, 8193, n]
  for p in checkpoints:
    if p >= 0 and p <= n:
      doAssert sbv.rank1(p) == naiveRank1(bits, p)
      doAssert sbv.rank1Unchecked(p) == naiveRank1(bits, p)
      doAssert sbv.rank0(p) == p - naiveRank1(bits, p)
      if p < n:
        doAssert sbv[p] == bits[int(p)]
        doAssert sbv.access(p) == bits[int(p)]
        doAssert sbv.rank1Incl(p) == naiveRank1(bits, p + 1)
        doAssert sbv.rank0Incl(p) == (p + 1) - naiveRank1(bits, p + 1)

  for p in 0'i64..<n:
    if n <= 2048 or p mod 97 == 0:
      doAssert sbv.rank1(p) == naiveRank1(bits, p)
      doAssert sbv.rank1Unchecked(p) == naiveRank1(bits, p)
      doAssert sbv.rank0(p) == p - naiveRank1(bits, p)

  for k in -1'i64..(sbv.totalOnes + 1):
    doAssert sbv.select1(k) == naiveSelect(bits, true, k)
  for k in -1'i64..min(sbv.totalZeros + 1, 2048'i64):
    doAssert sbv.select0(k) == naiveSelect(bits, false, k)

block helpers:
  doAssert ceilDiv(-1, 64) == 0
  doAssert ceilDiv(0, 64) == 0
  doAssert ceilDiv(1, 64) == 1
  doAssert ceilDiv(64, 64) == 1
  doAssert ceilDiv(65, 64) == 2
  doAssert alignUp(-1, 8) == 0
  doAssert alignUp(0, 8) == 0
  doAssert alignUp(1, 8) == 8
  doAssert alignUp(8, 8) == 8
  doAssert alignUp(9, 8) == 16

  doAssert calcLevel(0) == 0
  doAssert calcLevel(512) == 0
  doAssert calcLevel(513) == 1
  doAssert calcLevel(8192) == 1
  doAssert calcLevel(8193) == 2
  doAssert calcLevel(65536) == 2
  doAssert calcLevel(65537) == 3
  doAssert calcLevel(524288) == 3
  doAssert calcLevel(524289) == 4
  doAssert calcLevel(4194304) == 4
  doAssert calcLevel(4194305) == 5
  doAssert calcLevel(33554432) == 5
  doAssert calcLevel(33554433) == 6
  doAssert calcLevel(268435456) == 6
  doAssert calcLevel(268435457) == 7
  doAssert calcLevel(2147483648'i64) == 7
  doAssert calcLevel(2147483649'i64) == 8
  doAssert calcLevel(8589934592'i64) == 8
  doAssert calcLevel(8589934593'i64) == -1

block constructorAndErrors:
  expectRaises(ValueError): discard genSuccinctBitVector(-1)
  expectRaises(ValueError): discard genSuccinctBitVector(8589934593'i64)

  var sbv = genSuccinctBitVector(10)
  doAssert sbv.maxOfBits == 10
  doAssert sbv.lenOfBits == 10
  doAssert sbv.level == 0
  doAssert sbv.dataWords == 1
  doAssert not sbv.isCalced
  doAssert $sbv == "0000000000"
  expectRaises(IndexDefect): discard sbv[-1]
  expectRaises(IndexDefect): discard sbv[10]
  expectRaises(IndexDefect): sbv[-1] = true
  expectRaises(IndexDefect): sbv.setBit(10)
  expectRaises(IndexDefect): sbv.clearBit(-1)
  expectRaises(ValueError): discard sbv.rank1(0)
  expectRaises(ValueError): discard sbv.select1(0)

block empty:
  var sbv = genSuccinctBitVector(0)
  sbv.build()
  doAssert sbv.totalOnes == 0
  doAssert sbv.totalZeros == 0
  doAssert sbv.rank1(0) == 0
  doAssert sbv.rank0(0) == 0
  doAssert sbv.select1(0) == -1
  doAssert sbv.select0(0) == -1
  expectRaises(IndexDefect): discard sbv.rank1(-1)
  expectRaises(IndexDefect): discard sbv.rank1(1)

block smallPatterns:
  checkAgainstNaive(1, newSeq[int64]())
  checkAgainstNaive(1, [0'i64])
  checkAgainstNaive(64, [0'i64, 1, 2, 63])
  checkAgainstNaive(513, [0'i64, 63, 64, 65, 511, 512])
  checkAgainstNaive(9000, [0'i64, 511, 512, 8191, 8192, 8999])

block periodic:
  var ones: seq[int64] = @[]
  for i in countup(0, 99_999, 997):
    ones.add int64(i)
  checkAgainstNaive(100_000, ones)

block denseAndSparse:
  var dense: seq[int64] = @[]
  for i in 0'i64..<2048:
    if i mod 5 != 0: dense.add i
  checkAgainstNaive(2048, dense)

  var sparse: seq[int64] = @[]
  for i in countup(13, 32767, 4093):
    sparse.add int64(i)
  checkAgainstNaive(32768, sparse)

block directRankAndSelectInternals:
  var sbv = genSuccinctBitVector(1024)
  for i in [0'i64, 1, 63, 64, 127, 255, 511, 512, 700, 1023]:
    sbv[i] = true
  sbv.build()

  doAssert sbv.popcount512At(0) == 7
  doAssert sbv.popcount512At(512) == 3
  doAssert sbv.rankIn512Block(0) == 0
  doAssert sbv.rankIn512Block(1) == 1
  doAssert sbv.rankIn512Block(512) == 0
  doAssert sbv.rankIn512Block(701) == 2
  expectRaises(IndexDefect): discard sbv.rankIn512Block(-1)
  expectRaises(IndexDefect): discard sbv.rankIn512Block(1025)

  let word = 0b10110100'u64
  for target in 1..countSetBits(word):
    doAssert selectInWord64Pdep(word, target) == selectInWord64ByClearing(word, target)

  doAssert sbv.selectWordIn512OnesAvx2(0, 1).wordOffset == 0
  doAssert sbv.selectWordIn512OnesAvx2(0, 4).wordOffset == 1
  doAssert sbv.selectIn512OnesAvx2(0, 1) == 0
  doAssert sbv.selectIn512OnesAvx2(0, 7) == 511
  doAssert sbv.selectIn512ZerosAvx2(0, 1) == 2
  doAssert sbv.selectIn512ZerosTail(512, 1) == 513

block childSelectionHelpers:
  var p16 = [0'i16, 3, 8, 20, 25, 30, 31, 40, 60, 70, 80, 90, 100, 120, 150, 170]
  doAssert selectChildOnesL1x16(addr p16[0], 1) == 0
  doAssert selectChildOnesL1x16(addr p16[0], 4) == 1
  doAssert selectChildOnesL1x16(addr p16[0], 171) == 15
  doAssert selectChildOnesL1x16(addr p16[0], 31, 6) == 5

  doAssert selectChildZerosL1x16(addr p16[0], 1) == 0
  doAssert selectChildZerosL1x16(addr p16[0], 510) == 1
  doAssert selectChildZerosL1x16(addr p16[0], 600) == 1

  var p32 = [0'i32, 5, 12, 20, 44, 80, 90, 100]
  doAssert selectChildOnesI32x8(addr p32[0], 1) == 0
  doAssert selectChildOnesI32x8(addr p32[0], 13) == 2
  doAssert selectChildOnesI32x8(addr p32[0], 101) == 7
  doAssert selectChildOnesI32x8(addr p32[0], 21, 4) == 3
  doAssert selectChildOnesL7x8(addr p32[0], int64(int32.high) + 1, 8) == 7

  doAssert selectChildZerosI32x8(addr p32[0], 1, 64, 8) == 0
  doAssert selectChildZerosI32x8(addr p32[0], 65, 64, 8) == 1
  doAssert selectChildZerosL7x8(addr p32[0], int64(int32.high) + 1, 8) == 7

  doAssert selectLevel8OnesX4(@[0'i64, 100, 200, 300], 1) == 0
  doAssert selectLevel8OnesX4(@[0'i64, 100, 200, 300], 250) == 2
  doAssert selectLevel8ZerosX4(@[0'i64, 100, 200, 300], 1) == 0

block aliasesAndLogicalLevels:
  var sbv = genSuccinctBitVector(9000)
  sbv[0] = true
  sbv[8192] = true
  sbv.build()
  doAssert sbv.logicalLevel1.len == sbv.level1Len
  doAssert sbv.logicalLevel2.len == sbv.level2Len
  doAssert sbv.logicalLevel3.len == 0
  doAssert sbv.logicalLevel4.len == 0
  doAssert sbv.logicalLevel5.len == 0
  doAssert sbv.logicalLevel6.len == 0
  doAssert sbv.logicalLevel7.len == 0
  doAssert sbv.logicalLevel8.len == 0
  doAssert sbv.select1Nth(1) == 0
  doAssert sbv.select1Nth(2) == 8192
  doAssert sbv.select1Nth(0) == -1
  doAssert sbv.select0Nth(1) == 1
  doAssert sbv.select0Nth(0) == -1

block selectStorageMemoryBudget:
  let n = 16_777_216'i64
  let sbv = genSuccinctBitVector(n)
  let rawBytes = n div 8
  let auxiliaryBytes = int64(sbv.selectStorage.len * sizeof(uint64) +
                             sbv.blockPairPrefix.len * sizeof(uint32) +
                             sbv.wordPairPrefix.len * sizeof(uint32))
  doAssert auxiliaryBytes * 1000 <= rawBytes * 135

echo "OK tsuccinct_bit_vector"
