import nbvs/reversed_wavelet_matrix
import nbvs/succinct_bit_vector
import ./test_common

proc naiveCounts(xs: openArray[uint64], left, right: int): seq[ValueCount] =
  for value in 0'u64..15'u64:
    var count = 0'i64
    for i in left..<right:
      if xs[i] == value:
        inc count
    if count > 0:
      result.add (value: value, frequency: count)

block empty:
  let rwm = genReversedWaveletMatrix(newSeq[uint64]())
  doAssert rwm.n == 0
  doAssert rwm.bitWidth == 0
  doAssert rwm.toSeq.len == 0
  doAssert rwm.rank(1, 0) == 0
  doAssert rwm.select(1, 0) == -1
  doAssert rwm.valueCounts.len == 0
  expectRaises(IndexDefect): discard rwm[0]

block publicQueries:
  let xs = @[5'u64, 1, 7, 5, 2, 9, 1, 5, 0, 7, 3, 5]
  let rwm = genReversedWaveletMatrix(xs)
  doAssert rwm.n == int64(xs.len)
  doAssert rwm.bitWidth == 4
  doAssert rwm.toSeq == xs

  # The first level is the least significant bit.
  for i, x in xs:
    doAssert rwm.levels[0].access(int64(i)) == ((x and 1) != 0)

  var iterated: seq[uint64] = @[]
  for x in rwm.items:
    iterated.add x
  doAssert iterated == xs

  for i, x in xs:
    doAssert rwm[int64(i)] == x

  for value in 0'u64..15'u64:
    var positions: seq[int64] = @[]
    for i, x in xs:
      if x == value:
        positions.add int64(i)

    for pos in 0..xs.len:
      var expected = 0'i64
      var expectedLess = 0'i64
      for i in 0..<pos:
        if xs[i] == value:
          inc expected
        if xs[i] < value:
          inc expectedLess
      doAssert rwm.rank(value, int64(pos)) == expected
      doAssert rwm.rankLessThan(value, int64(pos)) == expectedLess
      if pos < xs.len:
        doAssert rwm.rankIncl(value, int64(pos)) ==
          expected + (if xs[pos] == value: 1 else: 0)

    for k, pos in positions:
      doAssert rwm.select(value, int64(k)) == pos
      doAssert rwm.selectNth(value, int64(k + 1)) == pos
    doAssert rwm.select(value, int64(positions.len)) == -1
    doAssert rwm.select(value, -1) == -1
    doAssert rwm.selectNth(value, int64(positions.len + 1)) == -1
    doAssert rwm.selectNth(value, 0) == -1
    doAssert rwm.selectNth(value, -1) == -1

  for left in 0..xs.len:
    for right in left..xs.len:
      doAssert rwm.valueCounts(int64(left), int64(right)) ==
        naiveCounts(xs, left, right)
      for value in 0'u64..15'u64:
        var expected = 0'i64
        for i in left..<right:
          if xs[i] == value:
            inc expected
        doAssert rwm.rank(value, int64(left), int64(right)) == expected

block allZeros:
  let rwm = genReversedWaveletMatrix(@[0'u64, 0, 0])
  doAssert rwm.bitWidth == 1
  doAssert rwm.valueCounts == @[(value: 0'u64, frequency: 3'i64)]

block fullWidth:
  let xs = @[uint64.high, 0'u64, 1'u64 shl 63, uint64.high - 1, 7]
  let rwm = genReversedWaveletMatrix(xs)
  doAssert rwm.bitWidth == 64
  doAssert rwm.toSeq == xs
  doAssert rwm.select(uint64.high, 0) == 0
  doAssert rwm.select(1'u64 shl 63, 0) == 2
  doAssert rwm.rankLessThan(uint64.high, rwm.n) == 4
  doAssert rwm.rankLessThan(1'u64 shl 63, rwm.n) == 2
  doAssert rwm.valueCounts == @[
    (value: 0'u64, frequency: 1'i64),
    (value: 7'u64, frequency: 1'i64),
    (value: 1'u64 shl 63, frequency: 1'i64),
    (value: uint64.high - 1, frequency: 1'i64),
    (value: uint64.high, frequency: 1'i64)]

block invalidBounds:
  let rwm = genReversedWaveletMatrix(@[1'u64, 2, 3])
  expectRaises(IndexDefect): discard rwm[-1]
  expectRaises(IndexDefect): discard rwm[3]
  expectRaises(IndexDefect): discard rwm.rank(1, -1)
  expectRaises(IndexDefect): discard rwm.rank(1, 4)
  expectRaises(IndexDefect): discard rwm.rankIncl(1, -1)
  expectRaises(IndexDefect): discard rwm.rankIncl(1, 3)
  expectRaises(IndexDefect): discard rwm.rankLessThan(1, 4)
  expectRaises(IndexDefect): discard rwm.rank(1, 2, 1)
  expectRaises(IndexDefect): discard rwm.valueCounts(-1, 2)

echo "OK treversed_wavelet_matrix"
