import nbvs/elias_fano
import ./test_common

proc checkEf(xs: seq[uint64], universe: uint64) =
  let ef = genEliasFano(xs, universe)
  doAssert ef.n == int64(xs.len)
  doAssert ef.universe == universe
  doAssert ef.lowMask == maskForLowBits(ef.lowBits)
  doAssert ef.toSeq == xs

  var iterated: seq[uint64] = @[]
  for x in ef.items:
    iterated.add x
  doAssert iterated == xs

  for i, x in xs:
    doAssert ef.access(int64(i)) == x
    doAssert ef.select(int64(i)) == x
    doAssert ef[int64(i)] == x

  if xs.len > 0:
    expectRaises(IndexDefect): discard ef[-1]
    expectRaises(IndexDefect): discard ef[int64(xs.len)]

  for v in 0'u64..universe:
    var lbExpected = int64(xs.len)
    for i, x in xs:
      if x >= v:
        lbExpected = int64(i)
        break

    var ubExpected = int64(xs.len)
    for i, x in xs:
      if x > v:
        ubExpected = int64(i)
        break

    var leExpected = -1'i64
    for i, x in xs:
      if x <= v:
        leExpected = int64(i)

    doAssert ef.lowerBound(v) == lbExpected
    doAssert ef.lowerBoundByAccess(v) == lbExpected
    doAssert ef.upperBound(v) == ubExpected
    doAssert ef.lastLessEqual(v) == leExpected
    doAssert ef.predecessorIndex(v) == leExpected
    doAssert ef.countLessEqual(v) == ubExpected
    doAssert ef.countLessThan(v) == lbExpected

    if leExpected >= 0:
      doAssert ef.predecessor(v) == xs[int(leExpected)]
    else:
      expectRaises(ValueError): discard ef.predecessor(v)

block helpers:
  doAssert floorLog2(0) == 0
  doAssert floorLog2(1) == 0
  doAssert floorLog2(2) == 1
  doAssert floorLog2(3) == 1
  doAssert floorLog2(4) == 2
  doAssert floorLog2(uint64.high) == 63

  doAssert calcLowBits(0, 0) == 0
  doAssert calcLowBits(0, 10) == 0
  doAssert calcLowBits(8, 8) == 0
  doAssert calcLowBits(32, 6) == 2
  doAssert calcLowBits(1024, 8) == 7

  doAssert maskForLowBits(0) == 0'u64
  doAssert maskForLowBits(1) == 1'u64
  doAssert maskForLowBits(7) == 127'u64
  doAssert maskForLowBits(64) == uint64.high
  expectRaises(ValueError): discard maskForLowBits(-1)
  expectRaises(ValueError): discard maskForLowBits(65)

block empty:
  let ef = genEliasFano(newSeq[uint64](), 10)
  doAssert ef.n == 0
  doAssert ef.toSeq == newSeq[uint64]()
  doAssert ef.lowerBound(0) == 0
  doAssert ef.upperBound(0) == 0
  doAssert ef.lastLessEqual(0) == -1
  doAssert ef.predecessorIndex(0) == -1
  doAssert ef.countLessEqual(0) == 0
  doAssert ef.countLessThan(0) == 0
  doAssert ef.firstIndexWithHighAtLeast(0) == 0
  doAssert ef.firstIndexWithHighGreaterThan(0) == 0
  expectRaises(IndexDefect): discard ef[0]
  expectRaises(ValueError): discard ef.predecessor(0)

block smallStrict:
  checkEf(@[0'u64, 3, 7, 10, 15, 31], 32)

block duplicates:
  checkEf(@[0'u64, 0, 0, 1, 1, 5, 5, 5, 9], 10)

block lowBitsZero:
  let xs = @[0'u64, 1, 2, 3, 4, 5, 6, 7]
  let ef = genEliasFano(xs, 8)
  doAssert ef.lowBits == 0
  checkEf(xs, 8)

block highBuckets:
  let xs = @[0'u64, 1, 7, 8, 9, 16, 31]
  let ef = genEliasFano(xs, 64)
  doAssert ef.firstIndexWithHighAtLeast(0) == 0
  doAssert ef.firstIndexWithHighAtLeast(1) <= ef.n
  doAssert ef.firstIndexWithHighAtLeast(ef.maxHigh + 1) == ef.n
  doAssert ef.firstIndexWithHighGreaterThan(ef.maxHigh) == ef.n
  doAssert ef.upperBound(uint64.high) == ef.n

block larger:
  var xs: seq[uint64] = @[]
  var x = 0'u64

  for i in 0..<10_000:
    x += uint64((i mod 7) + 1)
    xs.add x

  let universe = xs[^1] + 100
  let ef = genEliasFano(xs, universe)

  for i in 0..<xs.len:
    doAssert ef[int64(i)] == xs[i]

  for v in countup(0'u64, universe - 1, 13'u64):
    var lbExpected = int64(xs.len)
    for i, y in xs:
      if y >= v:
        lbExpected = int64(i)
        break

    var leExpected = -1'i64
    for i, y in xs:
      if y <= v:
        leExpected = int64(i)

    doAssert ef.lowerBound(v) == lbExpected
    doAssert ef.lowerBoundByAccess(v) == lbExpected
    doAssert ef.lastLessEqual(v) == leExpected
    doAssert ef.predecessorIndex(v) == leExpected

    if leExpected >= 0:
      doAssert ef.predecessor(v) == xs[int(leExpected)]

block errors:
  expectRaises(ValueError): discard genEliasFano(@[0'u64], 0)
  expectRaises(ValueError): discard genEliasFano(@[10'u64], 10)
  expectRaises(ValueError): discard genEliasFano(@[0'u64, 2, 1], 3)

echo "OK telias_fano"
