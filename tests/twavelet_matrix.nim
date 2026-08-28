import std/[algorithm, random]
import nbvs/[succinct_bit_vector, wavelet_matrix]
import nbvs/reversed_wavelet_matrix
import ./test_common

block empty:
  let wm = genWaveletMatrix(newSeq[uint64]())
  doAssert wm.n == 0
  doAssert wm.bitWidth == 0
  doAssert wm.toSeq == newSeq[uint64]()
  doAssert wm.rank(1, 0) == 0
  doAssert wm.occPosition(0, 0) == 0
  doAssert wm.select(1, 0) == -1
  doAssert wm.countLessThan(0, 0, 10) == 0
  doAssert wm.rangeFreq(0, 0, 0, 10) == 0
  doAssert wm.collectValueCounts.len == 0
  doAssert wm.collectValueCountFinalIntervals.len == 0
  doAssert wm.valueCounts.len == 0
  doAssert wm.collectDistinctValues.len == 0
  doAssert wm.distinctValues.len == 0
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

block fixedBitWidthAndAccessRank:
  let values = @[0'u64, 257, 3, 257, 1, 3]
  let wm = genWaveletMatrix(values, 9)
  doAssert wm.bitWidth == 9
  doAssert wm.toSeq == values
  for index, value in values:
    let item = wm.accessRank(int64(index))
    doAssert wm.accessRankUnchecked(int64(index)) == item
    doAssert item.value == value
    doAssert item.rankBefore == wm.rank(value, int64(index))
  doAssert genWaveletMatrix(newSeq[uint64](), 9).bitWidth == 9
  expectRaises(ValueError): discard genWaveletMatrix(@[512'u64], 9)
  expectRaises(ValueError): discard genWaveletMatrix(@[0'u64], -1)
  expectRaises(ValueError): discard genWaveletMatrix(@[0'u64], 65)

block genericFixedBitWidth:
  let expected = @[0'u64, 1, 3, 7, 3, 1]
  let matrices = [
    genWaveletMatrix(@[0'u8, 1, 3, 7, 3, 1], 3),
    genWaveletMatrix(@[0'u16, 1, 3, 7, 3, 1], 3),
    genWaveletMatrix(@[0'u32, 1, 3, 7, 3, 1], 3),
    genWaveletMatrix(expected, 3)]
  for wm in matrices:
    doAssert wm.toSeq == expected
    for left in 0..expected.len:
      for right in left..expected.len:
        for value in 0'u64..8'u64:
          let ranks = wm.rankPair(value, int64(left), int64(right))
          doAssert ranks.leftRank == wm.rank(value, int64(left))
          doAssert ranks.rightRank == wm.rank(value, int64(right))
  expectRaises(ValueError):
    discard genWaveletMatrix(@[8'u16], 3)

block occPosition:
  let cases = [
    @[3'u64, 1, 4, 1, 5, 9, 2, 6, 5],
    @[2'u64, 2, 2, 2],
    @[0'u64, 2, 0, 1, 0],
    @[0'u64, 1, 2, 3, 4, 5],
    @[5'u64, 4, 3, 2, 1, 0],
    @[1'u64, 3, 5, 7]]
  for xs in cases:
    let wm = genWaveletMatrix(xs)
    let rwm = genReversedWaveletMatrix(xs)
    for value in 0'u64..10'u64:
      for pos in 0..xs.len:
        let expected = naiveOccPosition(xs, value, pos)
        doAssert wm.occPosition(value, int64(pos)) == expected
        doAssert rwm.occPosition(value, int64(pos)) == expected
        doAssert wm.occPosition(value, int64(pos)) ==
          rwm.occPosition(value, int64(pos))

  let narrow = genWaveletMatrix(@[1'u64, 2, 3])
  doAssert narrow.occPosition(100, 0) == 3
  doAssert narrow.occPosition(100, narrow.n) == 3

block randomOccPosition:
  var rng = initRand(0x4f4343)
  for trial in 0..<120:
    let length = rng.rand(200)
    var xs = newSeq[uint64](length)
    for value in xs.mitems:
      value = uint64(rng.rand(255))
    let wm = genWaveletMatrix(xs)
    let rwm = genReversedWaveletMatrix(xs)
    for sample in 0..<32:
      let value = uint64(rng.rand(300))
      let pos = rng.rand(length)
      let expected = naiveOccPosition(xs, value, pos)
      doAssert wm.occPosition(value, int64(pos)) == expected
      doAssert rwm.occPosition(value, int64(pos)) == expected

block wordBoundaries:
  for length in [63, 64, 65, 127, 128, 129]:
    var xs = newSeq[uint64](length)
    for i in 0..<length:
      xs[i] = uint64((i * 37) mod 257)
    let wm = genWaveletMatrix(xs)
    doAssert wm.toSeq == xs
    for i, value in xs:
      doAssert wm.access(int64(i)) == value

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
  doAssert wm.collectValueCounts == wm.valueCounts
  doAssert wm.collectValueCounts(2, 8) == wm.valueCounts(2, 8)
  let finalIntervals = wm.collectValueCountFinalIntervals()
  doAssert finalIntervals.len == wm.valueCounts.len
  for i, item in finalIntervals:
    doAssert item.value == wm.valueCounts[i].value
    doAssert item.frequency == wm.valueCounts[i].frequency
    doAssert item.right - item.left == item.frequency
  doAssert wm.distinctValues == @[0'u64, 1, 2, 3, 5, 7, 9]
  doAssert wm.distinctValues(2, 8) == @[1'u64, 2, 5, 7, 9]

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
  for value in xs:
    for pos in 0..xs.len:
      doAssert wm.occPosition(value, int64(pos)) ==
        naiveOccPosition(xs, value, pos)

block valueEnumerations:
  let cases = [
    @[1'u64, 3, 4, 1],
    newSeq[uint64](),
    @[7'u64],
    @[5'u64, 5, 5, 5],
    @[8'u64, 1, 6, 3],
    @[0'u64, 1, 0, 8],
    @[0'u64, uint64.high, 1, uint64.high]]
  for xs in cases:
    let wm = genWaveletMatrix(xs)
    assertEnumerations(wm, xs)

    var values: seq[uint64]
    for value in wm.distinctValuesItems:
      values.add value
    doAssert values == wm.distinctValues

    var counts: seq[ValueCount]
    for item in wm.valueCountsItems:
      counts.add item
    doAssert counts == wm.valueCounts

    values.setLen(0)
    for value in wm.collectDistinctValuesItems:
      values.add value
    doAssert values == wm.collectDistinctValues

    counts.setLen(0)
    for item in wm.collectValueCountsItems:
      counts.add item
    doAssert counts == wm.collectValueCounts

    let intervals = wm.collectValueCountFinalIntervals
    doAssert intervals.len == counts.len
    for i, item in intervals:
      doAssert item.value == counts[i].value
      doAssert item.frequency == counts[i].frequency
      doAssert item.right - item.left == item.frequency

    var intervalItems: seq[ValueCountFinalInterval]
    for item in wm.collectValueCountFinalIntervalsItems:
      intervalItems.add item
    doAssert intervalItems == intervals

    let rangeLeft = min(1'i64, wm.n)
    let rangeIntervals = wm.collectValueCountFinalIntervals(rangeLeft, wm.n)
    let rangeCounts = wm.collectValueCounts(rangeLeft, wm.n)
    doAssert rangeIntervals.len == rangeCounts.len
    for i, item in rangeIntervals:
      doAssert item.value == rangeCounts[i].value
      doAssert item.frequency == rangeCounts[i].frequency
      doAssert item.right - item.left == item.frequency

    intervalItems.setLen(0)
    for item in wm.collectValueCountFinalIntervalsItems(rangeLeft, wm.n):
      intervalItems.add item
    doAssert intervalItems == rangeIntervals

block valueCountFinalIntervalPositions:
  let xs = @[5'u64, 1, 7, 5, 2, 9, 1, 5, 0, 7, 3, 5]
  let wm = genWaveletMatrix(xs)
  let intervals = wm.collectValueCountFinalIntervals()
  var finalPositions = newSeq[int64](xs.len)
  for physical in 0..<xs.len:
    var position = int64(physical)
    for level in 0..<wm.bitWidth:
      let ones = wm.levels[level].rank1Unchecked(position)
      if wm.levels[level].access(position):
        position = wm.zeroCounts[level] + ones
      else:
        position -= ones
    finalPositions[physical] = position

  for interval in intervals:
    var seen = 0
    for physical, value in xs:
      if value == interval.value:
        doAssert finalPositions[physical] >= interval.left
        doAssert finalPositions[physical] < interval.right
        inc seen
    doAssert int64(seen) == interval.frequency

block invalidBounds:
  let wm = genWaveletMatrix(@[1'u64, 2, 3])
  expectRaises(IndexDefect): discard wm[-1]
  expectRaises(IndexDefect): discard wm[3]
  expectRaises(IndexDefect): discard wm.rank(1, -1)
  expectRaises(IndexDefect): discard wm.rank(1, 4)
  expectRaises(IndexDefect): discard wm.rankIncl(1, -1)
  expectRaises(IndexDefect): discard wm.rankIncl(1, 3)
  expectRaises(IndexDefect): discard wm.rankLessThan(1, 4)
  expectRaises(IndexDefect):
    discard wm.collectValueCountFinalIntervals(-1, 2)
  expectRaises(IndexDefect):
    discard wm.collectValueCountFinalIntervals(1, 4)
  expectRaises(IndexDefect): discard wm.occPosition(1, -1)
  expectRaises(IndexDefect): discard wm.occPosition(1, wm.n + 1)
  expectRaises(IndexDefect): discard wm.rank(1, 2, 1)
  expectRaises(IndexDefect): discard wm.rankPair(1, 2, 1)
  expectRaises(IndexDefect): discard wm.countLessThan(-1, 2, 1)
  expectRaises(IndexDefect): discard wm.rangeFreq(0, 4, 0, 4)
  expectRaises(IndexDefect): discard wm.quantile(0, 3, -1)
  expectRaises(IndexDefect): discard wm.quantile(0, 3, 3)
  expectRaises(IndexDefect): discard wm.collectDistinctValues(-1, 2)
  expectRaises(IndexDefect): discard wm.distinctValues(0, 4)
  expectRaises(IndexDefect):
    for value in wm.collectDistinctValuesItems(2, 1):
      discard value
  expectRaises(IndexDefect):
    for item in wm.valueCountsItems(-1, 2):
      discard item

echo "OK twavelet_matrix"
