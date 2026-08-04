import std/[algorithm, random]
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
  doAssert rwm.occPosition(0, 0) == 0
  doAssert rwm.select(1, 0) == -1
  doAssert rwm.collectValueCounts.len == 0
  doAssert rwm.valueCounts.len == 0
  doAssert rwm.collectDistinctValues.len == 0
  doAssert rwm.distinctValues.len == 0
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
      var collected = rwm.collectValueCounts(int64(left), int64(right))
      collected.sort(proc(a, b: ValueCount): int = cmp(a.value, b.value))
      doAssert collected == naiveCounts(xs, left, right)
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

block occPosition:
  let cases = [
    @[3'u64, 1, 4, 1, 5, 9, 2, 6, 5],
    @[2'u64, 2, 2, 2],
    @[0'u64, 2, 0, 1, 0],
    @[0'u64, 1, 2, 3, 4, 5],
    @[5'u64, 4, 3, 2, 1, 0],
    @[1'u64, 3, 5, 7]]
  for xs in cases:
    let rwm = genReversedWaveletMatrix(xs)
    for value in 0'u64..10'u64:
      for pos in 0..xs.len:
        doAssert rwm.occPosition(value, int64(pos)) ==
          naiveOccPosition(xs, value, pos)

  let narrow = genReversedWaveletMatrix(@[1'u64, 2, 3])
  doAssert narrow.occPosition(100, 0) == 3
  doAssert narrow.occPosition(100, narrow.n) == 3

block randomOccPosition:
  var rng = initRand(0x52574d)
  for trial in 0..<120:
    let length = rng.rand(200)
    var xs = newSeq[uint64](length)
    for value in xs.mitems:
      value = uint64(rng.rand(255))
    let rwm = genReversedWaveletMatrix(xs)
    for sample in 0..<32:
      let value = uint64(rng.rand(300))
      let pos = rng.rand(length)
      doAssert rwm.occPosition(value, int64(pos)) ==
        naiveOccPosition(xs, value, pos)

block wordBoundaries:
  for length in [63, 64, 65, 127, 128, 129]:
    var xs = newSeq[uint64](length)
    for i in 0..<length:
      xs[i] = uint64((i * 37) mod 257)
    let rwm = genReversedWaveletMatrix(xs)
    doAssert rwm.toSeq == xs
    for i, value in xs:
      doAssert rwm.access(int64(i)) == value

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
  for value in xs:
    for pos in 0..xs.len:
      doAssert rwm.occPosition(value, int64(pos)) ==
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
    let rwm = genReversedWaveletMatrix(xs)
    assertEnumerations(rwm, xs)

    var values: seq[uint64]
    for value in rwm.distinctValuesItems:
      values.add value
    doAssert values == rwm.distinctValues

    var counts: seq[ValueCount]
    for item in rwm.valueCountsItems:
      counts.add item
    doAssert counts == rwm.valueCounts

    values.setLen(0)
    for value in rwm.collectDistinctValuesItems:
      values.add value
    doAssert values == rwm.collectDistinctValues

    counts.setLen(0)
    for item in rwm.collectValueCountsItems:
      counts.add item
    doAssert counts == rwm.collectValueCounts

block invalidBounds:
  let rwm = genReversedWaveletMatrix(@[1'u64, 2, 3])
  expectRaises(IndexDefect): discard rwm[-1]
  expectRaises(IndexDefect): discard rwm[3]
  expectRaises(IndexDefect): discard rwm.rank(1, -1)
  expectRaises(IndexDefect): discard rwm.rank(1, 4)
  expectRaises(IndexDefect): discard rwm.rankIncl(1, -1)
  expectRaises(IndexDefect): discard rwm.rankIncl(1, 3)
  expectRaises(IndexDefect): discard rwm.rankLessThan(1, 4)
  expectRaises(IndexDefect): discard rwm.occPosition(1, -1)
  expectRaises(IndexDefect): discard rwm.occPosition(1, rwm.n + 1)
  expectRaises(IndexDefect): discard rwm.rank(1, 2, 1)
  expectRaises(IndexDefect): discard rwm.collectValueCounts(-1, 2)
  expectRaises(IndexDefect): discard rwm.valueCounts(-1, 2)
  expectRaises(IndexDefect): discard rwm.collectDistinctValues(-1, 2)
  expectRaises(IndexDefect): discard rwm.distinctValues(0, 4)
  expectRaises(IndexDefect):
    for value in rwm.collectDistinctValuesItems(2, 1):
      discard value
  expectRaises(IndexDefect):
    for item in rwm.valueCountsItems(-1, 2):
      discard item

echo "OK treversed_wavelet_matrix"
