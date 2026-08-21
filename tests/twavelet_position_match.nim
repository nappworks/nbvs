import std/random
import nbvs/[succinct_bit_vector, wavelet_matrix, reversed_wavelet_matrix,
  wavelet_position_match]
import ./test_common

proc storageForSuccinct(bitLength: int64): seq[uint64] =
  newSeq[uint64]((requiredSuccinctBitVectorViewBytes(bitLength) + 7) div 8)

proc copyAsView(source: SuccinctBitVector,
    storage: var seq[uint64]): SuccinctBitVectorView =
  storage = storageForSuccinct(source.lenOfBits)
  let memory = if storage.len == 0: nil else: addr storage[0]
  result = initSuccinctBitVectorView(memory,
    storage.len * sizeof(uint64), source.lenOfBits)
  for position in 0'i64..<source.lenOfBits:
    if source[position]:
      result[position] = true
  result.build()

block basicWaveletMatrix:
  let xs = @[5'u64, 1, 7, 5, 2, 9, 1, 5, 0, 7, 3, 5]
  let wm = genWaveletMatrix(xs)
  for i, actual in xs:
    for expected in 0'u64..15'u64:
      doAssert wm.matchesAt(int64(i), expected) == (actual == expected)
      doAssert wm.matchesAtUnchecked(int64(i), expected) == (actual == expected)
    for low in 0'u64..15'u64:
      for high in low..15'u64:
        let expected = actual >= low and actual <= high
        doAssert wm.valueInRangeAt(int64(i), low, high) == expected
        doAssert wm.valueInRangeAtUnchecked(int64(i), low, high) == expected
    doAssert not wm.valueInRangeAt(int64(i), 10, 9)
  doAssert not wm.matchesAt(0, 16)
  expectRaises(IndexDefect): discard wm.matchesAt(-1, 5)
  expectRaises(IndexDefect): discard wm.matchesAt(wm.n, 5)
  expectRaises(IndexDefect): discard wm.valueInRangeAt(-1, 0, 10)
  expectRaises(IndexDefect): discard wm.valueInRangeAt(wm.n, 0, 10)

block basicReversedWaveletMatrix:
  let xs = @[5'u64, 1, 7, 5, 2, 9, 1, 5, 0, 7, 3, 5]
  let rwm = genReversedWaveletMatrix(xs)
  for i, actual in xs:
    for expected in 0'u64..15'u64:
      doAssert rwm.matchesAt(int64(i), expected) == (actual == expected)
      doAssert rwm.matchesAtUnchecked(int64(i), expected) == (actual == expected)
  doAssert not rwm.matchesAt(0, 16)
  expectRaises(IndexDefect): discard rwm.matchesAt(-1, 5)
  expectRaises(IndexDefect): discard rwm.matchesAt(rwm.n, 5)

block fixedBitWidth:
  let xs = @[0'u64, 1, 3, 7, 3, 1]
  let wm = genWaveletMatrix(xs, 8)
  for i, actual in xs:
    doAssert wm.matchesAt(int64(i), actual)
    doAssert not wm.matchesAt(int64(i), 256)
    doAssert wm.valueInRangeAt(int64(i), actual, actual)
    doAssert wm.valueInRangeAt(int64(i), 0, 255)
    doAssert wm.valueInRangeAt(int64(i), 0, uint64.high)
    doAssert wm.valueInRangeAt(int64(i), 256, uint64.high) == false
    doAssert wm.valueInRangeAtUnchecked(int64(i), 6, 300) == (actual >= 6)

block viewEquivalence:
  let xs = @[0'u64, 1, 3, 7, 15, 31, 63, 127, 255]
  let wm = genWaveletMatrix(xs, 8)
  var levelStorage = newSeq[seq[uint64]](wm.bitWidth)
  var levelViews = newSeq[SuccinctBitVectorView](wm.bitWidth)
  for level in 0..<wm.bitWidth:
    levelViews[level] = copyAsView(wm.levels[level], levelStorage[level])
  var zeroCounts = wm.zeroCounts
  let wmView = initWaveletMatrixView(wm.n, wm.bitWidth,
    cast[ptr UncheckedArray[SuccinctBitVectorView]](addr levelViews[0]),
    levelViews.len, addr zeroCounts[0], zeroCounts.len * sizeof(int64))

  for position, actual in xs:
    for candidate in [0'u64, actual, 127'u64, 255'u64, 256'u64]:
      doAssert wmView.matchesAt(int64(position), candidate) ==
        (wmView.access(int64(position)) == candidate)
      doAssert wmView.matchesAtUnchecked(int64(position), candidate) ==
        wmView.matchesAt(int64(position), candidate)
    for bounds in [(0'u64, 0'u64), (3'u64, 127'u64),
                   (25'u64, 125'u64), (200'u64, uint64.high),
                   (9'u64, 8'u64)]:
      let expected = bounds[0] <= bounds[1] and actual >= bounds[0] and
        actual <= bounds[1]
      doAssert wmView.valueInRangeAt(int64(position), bounds[0], bounds[1]) ==
        expected
      doAssert wmView.valueInRangeAtUnchecked(int64(position), bounds[0],
        bounds[1]) == expected
  expectRaises(IndexDefect): discard wmView.matchesAt(-1, 0)
  expectRaises(IndexDefect):
    discard wmView.valueInRangeAt(wmView.n, 0, uint64.high)

  let rwm = genReversedWaveletMatrix(xs)
  for level in 0..<rwm.bitWidth:
    levelViews[level] = copyAsView(rwm.levels[level], levelStorage[level])
  zeroCounts = rwm.zeroCounts
  let rwmView = initReversedWaveletMatrixView(rwm.n, rwm.bitWidth,
    cast[ptr UncheckedArray[SuccinctBitVectorView]](addr levelViews[0]),
    levelViews.len, addr zeroCounts[0], zeroCounts.len * sizeof(int64))
  for position, actual in xs:
    for candidate in [0'u64, actual, 127'u64, 255'u64, 256'u64]:
      doAssert rwmView.matchesAt(int64(position), candidate) ==
        (rwmView.access(int64(position)) == candidate)
      doAssert rwmView.matchesAtUnchecked(int64(position), candidate) ==
        rwmView.matchesAt(int64(position), candidate)
  expectRaises(IndexDefect): discard rwmView.matchesAt(rwmView.n, 0)

block fullWidth:
  let xs = @[uint64.high, 0'u64, 1'u64 shl 63, uint64.high - 1, 7]
  let wm = genWaveletMatrix(xs)
  let rwm = genReversedWaveletMatrix(xs)
  for i, actual in xs:
    doAssert wm.matchesAt(int64(i), actual)
    doAssert rwm.matchesAt(int64(i), actual)
    doAssert wm.matchesAt(int64(i), actual xor 1'u64) ==
      ((actual xor 1'u64) == actual)
    doAssert rwm.matchesAt(int64(i), actual xor 1'u64) ==
      ((actual xor 1'u64) == actual)
    doAssert wm.valueInRangeAt(int64(i), actual, actual)
    doAssert wm.valueInRangeAt(int64(i), 0, uint64.high)

block randomEquivalenceWithAccess:
  var rng = initRand(0x4d41544348)
  for trial in 0..<100:
    let length = 1 + rng.rand(255)
    var xs = newSeq[uint64](length)
    for value in xs.mitems:
      value = uint64(rng.rand(1023))
    let wm = genWaveletMatrix(xs)
    let rwm = genReversedWaveletMatrix(xs)
    for sample in 0..<64:
      let position = rng.rand(length - 1)
      let candidate = uint64(rng.rand(1200))
      doAssert wm.matchesAt(int64(position), candidate) ==
        (wm.access(int64(position)) == candidate)
      doAssert rwm.matchesAt(int64(position), candidate) ==
        (rwm.access(int64(position)) == candidate)

      let a = uint64(rng.rand(1200))
      let b = uint64(rng.rand(1200))
      let low = min(a, b)
      let high = max(a, b)
      let actual = wm.access(int64(position))
      let expected = actual >= low and actual <= high
      doAssert wm.valueInRangeAt(int64(position), low, high) == expected
      doAssert wm.valueInRangeAtUnchecked(int64(position), low, high) == expected

echo "OK twavelet_position_match"
