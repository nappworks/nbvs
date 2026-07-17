import std/algorithm
import nbvs/wavelet_matrix
import ./test_common

block empty:
  let wm = genWaveletMatrix(newSeq[uint64]())
  doAssert wm.n == 0
  doAssert wm.bitWidth == 0
  doAssert wm.toSeq == newSeq[uint64]()
  doAssert wm.rank(1, 0) == 0
  doAssert wm.select(1, 0) == -1
  doAssert wm.countLessThan(0, 0, 10) == 0
  doAssert wm.rangeFreq(0, 0, 0, 10) == 0
  expectRaises(IndexDefect): discard wm[0]
  expectRaises(IndexDefect): discard wm.quantile(0, 0, 0)
  expectRaises(ValueError): discard wm.predecessor(0, 0, 1)
  expectRaises(ValueError): discard wm.successor(0, 0, 1)

block allZeros:
  let xs = @[0'u64, 0, 0, 0]
  let wm = genWaveletMatrix(xs)
  doAssert wm.bitWidth == 1
  doAssert wm.toSeq == xs
  doAssert wm.rank(0, 4) == 4
  doAssert wm.rank(1, 4) == 0
  doAssert wm.select(0, 3) == 3
  doAssert wm.select(0, 4) == -1
  doAssert wm.quantile(0, 4, 2) == 0

block publicQueries:
  let xs = @[5'u64, 1, 7, 5, 2, 9, 1, 5, 0, 7, 3, 5]
  let wm = genWaveletMatrix(xs)
  doAssert wm.n == int64(xs.len)
  doAssert wm.toSeq == xs
  doAssert wm.valueCounts == @[
    (value: 0'u64, frequency: 1'i64),
    (value: 1'u64, frequency: 2'i64),
    (value: 2'u64, frequency: 1'i64),
    (value: 3'u64, frequency: 1'i64),
    (value: 5'u64, frequency: 4'i64),
    (value: 7'u64, frequency: 2'i64),
    (value: 9'u64, frequency: 1'i64)]
  doAssert wm.valueCounts(2, 8) == @[
    (value: 1'u64, frequency: 1'i64),
    (value: 2'u64, frequency: 1'i64),
    (value: 5'u64, frequency: 2'i64),
    (value: 7'u64, frequency: 1'i64),
    (value: 9'u64, frequency: 1'i64)]
  doAssert wm.valueCounts(3, 3).len == 0

  var iterated: seq[uint64] = @[]
  for x in wm.items:
    iterated.add x
  doAssert iterated == xs

  for i, x in xs:
    doAssert wm[int64(i)] == x
    doAssert wm.access(int64(i)) == x

  for value in 0'u64..12'u64:
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
      doAssert wm.rank(value, int64(pos)) == expected
      doAssert wm.rankLessThan(value, int64(pos)) == expectedLess
      if pos < xs.len:
        doAssert wm.rankIncl(value, int64(pos)) ==
          expected + (if xs[pos] == value: 1 else: 0)

    for k, pos in positions:
      doAssert wm.select(value, int64(k)) == pos
      doAssert wm.selectNth(value, int64(k + 1)) == pos
    doAssert wm.select(value, int64(positions.len)) == -1
    doAssert wm.select(value, -1) == -1
    doAssert wm.selectNth(value, int64(positions.len + 1)) == -1
    doAssert wm.selectNth(value, 0) == -1
    doAssert wm.selectNth(value, -1) == -1

  for left in 0..xs.len:
    for right in left..xs.len:
      var sorted = xs[left..<right]
      sorted.sort()

      for value in 0'u64..12'u64:
        var exact = 0'i64
        var less = 0'i64
        for x in xs[left..<right]:
          if x == value:
            inc exact
          if x < value:
            inc less
        doAssert wm.rank(value, int64(left), int64(right)) == exact
        doAssert wm.countLessThan(int64(left), int64(right), value) == less

      for lower in 0'u64..10'u64:
        for upper in lower..11'u64:
          var expected = 0'i64
          for x in xs[left..<right]:
            if x >= lower and x < upper:
              inc expected
          doAssert wm.rangeFreq(int64(left), int64(right), lower, upper) == expected

      for k, value in sorted:
        doAssert wm.quantile(int64(left), int64(right), int64(k)) == value

      if sorted.len > 0:
        for bound in 0'u64..11'u64:
          var predFound = false
          var pred = 0'u64
          var succFound = false
          var succ = 0'u64
          for x in sorted:
            if x < bound:
              pred = x
              predFound = true
            if not succFound and x >= bound:
              succ = x
              succFound = true

          if predFound:
            doAssert wm.predecessor(int64(left), int64(right), bound) == pred
          else:
            expectRaises(ValueError):
              discard wm.predecessor(int64(left), int64(right), bound)

          if succFound:
            doAssert wm.successor(int64(left), int64(right), bound) == succ
          else:
            expectRaises(ValueError):
              discard wm.successor(int64(left), int64(right), bound)

block fullWidth:
  let xs = @[uint64.high, 0'u64, 1'u64 shl 63, uint64.high - 1, 7]
  let wm = genWaveletMatrix(xs)
  doAssert wm.bitWidth == 64
  doAssert wm.toSeq == xs
  doAssert wm.select(uint64.high, 0) == 0
  doAssert wm.select(1'u64 shl 63, 0) == 2
  doAssert wm.quantile(0, wm.n, 0) == 0
  doAssert wm.quantile(0, wm.n, 4) == uint64.high
  doAssert wm.countLessThan(0, wm.n, uint64.high) == 4
  doAssert wm.rankLessThan(uint64.high, wm.n) == 4
  doAssert wm.successor(0, wm.n, uint64.high) == uint64.high

block invalidBounds:
  let wm = genWaveletMatrix(@[1'u64, 2, 3])
  expectRaises(IndexDefect): discard wm[-1]
  expectRaises(IndexDefect): discard wm[3]
  expectRaises(IndexDefect): discard wm.rank(1, -1)
  expectRaises(IndexDefect): discard wm.rank(1, 4)
  expectRaises(IndexDefect): discard wm.rankIncl(1, -1)
  expectRaises(IndexDefect): discard wm.rankIncl(1, 3)
  expectRaises(IndexDefect): discard wm.rankLessThan(1, 4)
  expectRaises(IndexDefect): discard wm.rank(1, 2, 1)
  expectRaises(IndexDefect): discard wm.countLessThan(-1, 2, 1)
  expectRaises(IndexDefect): discard wm.rangeFreq(0, 4, 0, 4)
  expectRaises(IndexDefect): discard wm.quantile(0, 3, -1)
  expectRaises(IndexDefect): discard wm.quantile(0, 3, 3)

echo "OK twavelet_matrix"
