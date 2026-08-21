import std/random
import nbvs/[wavelet_matrix, reversed_wavelet_matrix, wavelet_position_match]
import ./test_common

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
