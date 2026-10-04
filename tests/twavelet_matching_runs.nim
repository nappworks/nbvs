import std/random
import nbvs/[succinct_bit_vector, wavelet_matrix, wavelet_matching_runs]
import ./test_common

func naiveRuns(xs: openArray[uint64], value: uint64,
    left, right: int): seq[MatchingRun] =
  var i = left
  while i < right:
    if xs[i] != value:
      inc i
      continue
    let start = i
    while i < right and xs[i] == value:
      inc i
    result.add (left: int64(start), right: int64(i))


func naiveRangeRuns(xs: openArray[uint64], low, high: uint64,
    left, right: int): seq[MatchingRun] =
  if low > high:
    return
  var i = left
  while i < right:
    if xs[i] < low or xs[i] > high:
      inc i
      continue
    let start = i
    while i < right and xs[i] >= low and xs[i] <= high:
      inc i
    result.add (left: int64(start), right: int64(i))

block bitRunsApi:
  var bits = genSuccinctBitVector(8)
  for pos in [1'i64, 2, 3, 5, 6]:
    bits[pos] = true
  bits.build()

  let expectedOnes = @[
    (left: 1'i64, right: 4'i64),
    (left: 5'i64, right: 7'i64)]
  let expectedZeros = @[
    (left: 0'i64, right: 1'i64),
    (left: 4'i64, right: 5'i64),
    (left: 7'i64, right: 8'i64)]

  doAssert bits.bitRuns(true) == expectedOnes
  doAssert bits.bitRuns(false) == expectedZeros
  doAssert bits.bitRuns(true, 2, 6) == @[
    (left: 2'i64, right: 4'i64),
    (left: 5'i64, right: 6'i64)]

  var iterated: seq[MatchingRun]
  for run in bits.bitRunsItems(true):
    iterated.add run
  doAssert iterated == expectedOnes

  expectRaises(IndexDefect): discard bits.bitRuns(true, -1, 2)
  expectRaises(IndexDefect): discard bits.bitRuns(true, 0, 9)
  expectRaises(IndexDefect): discard bits.bitRuns(true, 3, 2)

block simpleRuns:
  let xs = @[1'u64, 7, 7, 7, 1, 7, 7]
  let wm = genWaveletMatrix(xs)
  let expectedSevens = @[
    (left: 1'i64, right: 4'i64),
    (left: 5'i64, right: 7'i64)]

  doAssert wm.matchingRuns(7) == expectedSevens
  doAssert wm.collectMatchingRuns(7) == expectedSevens
  doAssert wm.matchingRuns(1) == @[
    (left: 0'i64, right: 1'i64),
    (left: 4'i64, right: 5'i64)]
  doAssert wm.matchingRuns(7, 2, 6) == @[
    (left: 2'i64, right: 4'i64),
    (left: 5'i64, right: 6'i64)]

  var iterated: seq[MatchingRun]
  for run in wm.matchingRunsItems(7):
    iterated.add run
  doAssert iterated == expectedSevens

block edgeCases:
  let empty = genWaveletMatrix(newSeq[uint64]())
  doAssert empty.matchingRuns(0).len == 0

  let zeros = genWaveletMatrix(@[0'u64, 0, 0, 0])
  doAssert zeros.matchingRuns(0) == @[
    (left: 0'i64, right: 4'i64)]
  doAssert zeros.matchingRuns(0, 1, 3) == @[
    (left: 1'i64, right: 3'i64)]
  doAssert zeros.matchingRuns(1).len == 0

  let wm = genWaveletMatrix(@[1'u64, 2, 3])
  doAssert wm.matchingRuns(100).len == 0
  doAssert wm.matchingRuns(2, 1, 1).len == 0
  expectRaises(IndexDefect): discard wm.matchingRuns(2, -1, 2)
  expectRaises(IndexDefect): discard wm.matchingRuns(2, 0, 4)
  expectRaises(IndexDefect): discard wm.matchingRuns(2, 2, 1)

block simpleRangeRuns:
  let xs = @[1'u64, 7, 5, 6, 1, 4, 7, 7, 3]
  let wm = genWaveletMatrix(xs, 3)
  let expected = @[
    (left: 1'i64, right: 4'i64),
    (left: 5'i64, right: 8'i64)]

  doAssert wm.matchingRangeRuns(4, 7) == expected
  doAssert wm.collectMatchingRangeRuns(4, 7) == expected
  doAssert wm.matchingRangeRuns(4, 7, 2, 7) == @[
    (left: 2'i64, right: 4'i64),
    (left: 5'i64, right: 7'i64)]
  doAssert wm.matchingRangeRuns(7, 7) == wm.matchingRuns(7)
  doAssert wm.matchingRangeRuns(0, 7) == @[
    (left: 0'i64, right: int64(xs.len))]
  doAssert wm.matchingRangeRuns(8, 10).len == 0
  doAssert wm.matchingRangeRuns(7, 4).len == 0
  doAssert wm.matchingRangeRuns(4, 7, 3, 3).len == 0

  var iterated: seq[MatchingRun]
  for run in wm.matchingRangeRunsItems(4, 7):
    iterated.add run
  doAssert iterated == expected

  expectRaises(IndexDefect): discard wm.matchingRangeRuns(4, 7, -1, 3)
  expectRaises(IndexDefect): discard wm.matchingRangeRuns(4, 7, 0, 10)
  expectRaises(IndexDefect): discard wm.matchingRangeRuns(4, 7, 5, 4)

block rangeNativePrefixSubtrees:
  # queryに完全包含されるvalue prefixと、部分交差するprefixを同じphysical列で
  # 混在させ、native traversalが元physical orderの極大runを維持することを確認する。
  let xs = @[
    12'u64, 64, 65, 95, 127, 200, 80, 81, 130, 159, 32, 63, 96, 160,
    72, 73, 74, 250]
  let wm = genWaveletMatrix(xs, 8)

  for query in [
      (64'u64, 127'u64),
      (48'u64, 159'u64),
      (65'u64, 130'u64),
      (1'u64, 254'u64)]:
    let (low, high) = query
    doAssert wm.matchingRangeRuns(low, high) ==
      naiveRangeRuns(xs, low, high, 0, xs.len)
    for left in 0..xs.len:
      for right in left..xs.len:
        doAssert wm.matchingRangeRuns(
          low, high, int64(left), int64(right)) ==
          naiveRangeRuns(xs, low, high, left, right)

block adaptiveRangeRuns:
  var clustered = newSeq[uint64](4096)
  for position in 0..<clustered.len:
    let cluster = position div 256
    clustered[position] =
      if (cluster and 1) == 0: 80'u64 else: 200'u64
  let clusteredWm = genWaveletMatrix(clustered, 8)
  doAssert clusteredWm.matchingRangeRuns(64, 127) ==
    naiveRangeRuns(clustered, 64, 127, 0, clustered.len)

  var fragmented = newSeq[uint64](4096)
  for position in 0..<fragmented.len:
    fragmented[position] =
      if (position and 1) == 0: 80'u64 else: 200'u64
  let fragmentedWm = genWaveletMatrix(fragmented, 8)
  doAssert fragmentedWm.matchingRangeRuns(64, 127) ==
    naiveRangeRuns(fragmented, 64, 127, 0, fragmented.len)

  when defined(nbvsRangeRunBenchmark):
    doAssert clusteredWm.rangeRunAdaptiveUsesNativeBenchmark(
      64, 127, 0, clusteredWm.n)
    doAssert not fragmentedWm.rangeRunAdaptiveUsesNativeBenchmark(
      64, 127, 0, fragmentedWm.n)
    doAssert not clusteredWm.rangeRunAdaptiveUsesNativeBenchmark(
      64, 127, 0, 1024)

block rangeRunsExplicitBitWidths:
  let zeros = genWaveletMatrix(@[0'u64, 0, 0, 0], 0)
  doAssert zeros.matchingRangeRuns(0, 0, 1, 3) == @[
    (left: 1'i64, right: 3'i64)]
  doAssert zeros.matchingRangeRuns(0, uint64.high) == @[
    (left: 0'i64, right: 4'i64)]
  doAssert zeros.matchingRangeRuns(1, uint64.high).len == 0

  let xs = @[0'u64, 1'u64 shl 63, uint64.high, 7'u64,
    uint64.high - 1, uint64.high]
  let wm = genWaveletMatrix(xs, 64)
  let queries = [
    (0'u64, 7'u64),
    (1'u64 shl 63, uint64.high),
    (uint64.high - 1, uint64.high),
    (uint64.high, uint64.high)]
  doAssert wm.matchingRangeRuns(0, uint64.high) == @[
    (left: 0'i64, right: int64(xs.len))]
  doAssert wm.matchingRangeRuns(1, 0).len == 0
  for (low, high) in queries:
    for left in 0..xs.len:
      for right in left..xs.len:
        doAssert wm.matchingRangeRuns(
          low, high, int64(left), int64(right)) ==
          naiveRangeRuns(xs, low, high, left, right)

block randomRangeRuns:
  var rng = initRand(0x52414e474552554e'i64)
  for trial in 0..<120:
    let length = rng.rand(220)
    var xs = newSeq[uint64](length)
    for value in xs.mitems:
      value = uint64(rng.rand(15))
    let wm = genWaveletMatrix(xs, 4)

    for sample in 0..<60:
      let first = uint64(rng.rand(20))
      let second = uint64(rng.rand(20))
      let low = min(first, second)
      let high = max(first, second)
      let left = rng.rand(length)
      let right = left + rng.rand(length - left)
      doAssert wm.matchingRangeRuns(low, high, int64(left), int64(right)) ==
        naiveRangeRuns(xs, low, high, left, right)

block prefixSplits:
  let xs = @[7'u64, 6, 7, 7, 4, 7, 6, 7]
  let wm = genWaveletMatrix(xs, 3)
  doAssert wm.matchingRuns(7) == naiveRuns(xs, 7, 0, xs.len)

block explicitBitWidths:
  # 自動推定では全ゼロ入力も1bitになるため、0bitを明示する。
  let zeros = genWaveletMatrix(@[0'u64, 0, 0, 0], 0)
  doAssert zeros.bitWidth == 0
  doAssert zeros.matchingRuns(0, 1, 3) == @[(left: 1'i64, right: 3'i64)]
  doAssert zeros.matchingRuns(1).len == 0
  let view = initWaveletMatrixView(4, 0, nil, 0, nil, 0)
  doAssert view.matchingRuns(0, 1, 3) == zeros.matchingRuns(0, 1, 3)
  doAssert view.matchingRuns(1).len == 0

  let xs = @[uint64.high, uint64.high, 0'u64, 1'u64 shl 63,
    uint64.high, uint64.high]
  let wm = genWaveletMatrix(xs, 64)
  for value in [0'u64, 1'u64 shl 63, uint64.high]:
    for left in 0..xs.len:
      for right in left..xs.len:
        doAssert wm.matchingRuns(value, int64(left), int64(right)) ==
          naiveRuns(xs, value, left, right)
  for run in wm.matchingRunsItems(uint64.high):
    doAssert run == (left: 0'i64, right: 2'i64)
    break

block alternatingRuns:
  var xs = newSeq[uint64](257)
  for i in 0..<xs.len:
    xs[i] = if (i and 1) == 0: 7'u64 else: uint64(i mod 7)
  let wm = genWaveletMatrix(xs, 3)
  doAssert wm.matchingRuns(7) == naiveRuns(xs, 7, 0, xs.len)
  doAssert wm.matchingRuns(7, 31, 224) == naiveRuns(xs, 7, 31, 224)

block longPhysicalRuns:
  var xs = newSeq[uint64](4096)
  for i in 0..<xs.len:
    if i in 127..1022 or i in 2049..3900:
      xs[i] = 7
    else:
      xs[i] = uint64(i mod 7)
  let wm = genWaveletMatrix(xs, 3)
  doAssert wm.matchingRuns(7) == naiveRuns(xs, 7, 0, xs.len)
  doAssert wm.matchingRuns(7, 512, 3072) == naiveRuns(xs, 7, 512, 3072)

block wordBoundaries:
  var xs = newSeq[uint64](140)
  for i in 0..<xs.len:
    if i in 60..68 or i in 127..133:
      xs[i] = 7
    else:
      xs[i] = uint64(i mod 5)
  let wm = genWaveletMatrix(xs)
  doAssert wm.matchingRuns(7) == naiveRuns(xs, 7, 0, xs.len)
  doAssert wm.matchingRuns(7, 63, 131) == naiveRuns(xs, 7, 63, 131)

block randomRuns:
  var rng = initRand(0x52554e53)
  for trial in 0..<120:
    let length = rng.rand(220)
    var xs = newSeq[uint64](length)
    for value in xs.mitems:
      value = uint64(rng.rand(15))
    let wm = genWaveletMatrix(xs, 4)

    for sample in 0..<40:
      let value = uint64(rng.rand(20))
      let left = rng.rand(length)
      let right = left + rng.rand(length - left)
      doAssert wm.matchingRuns(value, int64(left), int64(right)) ==
        naiveRuns(xs, value, left, right)

    for value in 0'u64..20'u64:
      doAssert wm.matchingRuns(value) == naiveRuns(xs, value, 0, xs.len)

block hybridRangesAndViews:
  # 短run・長runと64bitの深い経路で、範囲外の出現をcursorが列挙しないことを確認する。
  for bitWidth in [3, 64]:
    let target = if bitWidth == 64: uint64.high else: 7'u64
    for runLength in [1, 4, 16, 31, 32, 64, 256]:
      var xs = newSeq[uint64](4096)
      for i in 0..<xs.len:
        xs[i] = if i mod (runLength * 4) < runLength: target else: uint64(i mod 7)
      let wm = genWaveletMatrix(xs, bitWidth)
      var storage = newSeq[seq[uint64]](bitWidth)
      var levels = newSeq[SuccinctBitVectorView](bitWidth)
      var zeros = wm.zeroCounts
      for level in 0..<bitWidth:
        storage[level] = newSeq[uint64](
          (requiredSuccinctBitVectorViewBytes(wm.n) + 7) div 8)
        levels[level] = initSuccinctBitVectorView(addr storage[level][0],
          storage[level].len * sizeof(uint64), wm.n)
        for position in 0'i64..<wm.n:
          if wm.levels[level][position]: levels[level][position] = true
        levels[level].build()
      # backing storageと配列は検証中に再確保せず、viewより長く保持する。
      let view = initWaveletMatrixView(wm.n, bitWidth,
        cast[ptr UncheckedArray[SuccinctBitVectorView]](addr levels[0]),
        levels.len, addr zeros[0], zeros.len * sizeof(int64))
      for bounds in [(0, 4096), (17, 4011), (127, 2049), (4000, 4096),
                     (31, 32), (32, 32)]:
        let (left, right) = bounds
        let expected = naiveRuns(xs, target, left, right)
        doAssert wm.matchingRuns(target, int64(left), int64(right)) == expected
        doAssert view.matchingRuns(target, int64(left), int64(right)) == expected
        doAssert view.collectMatchingRuns(target, int64(left), int64(right)) == expected
        let rangeLow = if bitWidth == 64: uint64.high - 3 else: 5'u64
        let rangeHigh = target
        let expectedRange = naiveRangeRuns(
          xs, rangeLow, rangeHigh, left, right)
        doAssert wm.matchingRangeRuns(
          rangeLow, rangeHigh, int64(left), int64(right)) == expectedRange
        doAssert view.matchingRangeRuns(
          rangeLow, rangeHigh, int64(left), int64(right)) == expectedRange
        doAssert view.collectMatchingRangeRuns(
          rangeLow, rangeHigh, int64(left), int64(right)) == expectedRange
        var iterated: seq[MatchingRun]
        for run in view.matchingRunsItems(target, int64(left), int64(right)):
          iterated.add run
        doAssert iterated == expected
        for run in wm.matchingRunsItems(target, int64(left), int64(right)):
          doAssert run == expected[0]
          break
        for run in view.matchingRunsItems(target, int64(left), int64(right)):
          doAssert run == expected[0]
          break
