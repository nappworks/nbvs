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

block prefixSplits:
  let xs = @[7'u64, 6, 7, 7, 4, 7, 6, 7]
  let wm = genWaveletMatrix(xs, 3)
  doAssert wm.matchingRuns(7) == naiveRuns(xs, 7, 0, xs.len)

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
