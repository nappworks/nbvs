import std/[algorithm, memfiles, os, random, tempfiles]
import nbvs/[wavelet_matrix, quad_wavelet_matrix, quad_vector_view]
import ./test_common

proc checkEquivalent(values: seq[uint64], bitWidth: int) =
  let wm = genWaveletMatrix(values, bitWidth)
  let qwm = genQuadWaveletMatrix(values, bitWidth)
  doAssert qwm.n == wm.n
  doAssert qwm.bitWidth == wm.bitWidth
  doAssert qwm.levelCount == (bitWidth + 1) div 2

  for i, value in values:
    let pos = int64(i)
    doAssert qwm[pos] == value
    doAssert qwm.access(pos) == wm.access(pos)
    let qa = qwm.accessRank(pos)
    let wa = wm.accessRank(pos)
    doAssert qa.value == wa.value
    doAssert qa.rankBefore == wa.rankBefore
    doAssert qwm.accessRankUnchecked(pos) == qa

  var distinct = values
  distinct.sort()
  var probes = @[0'u64, 1'u64]
  for value in distinct:
    if probes.len < 24 and (probes.len == 0 or probes[^1] != value):
      probes.add value
  if bitWidth < 64:
    probes.add (if bitWidth == 0: 1'u64 else: 1'u64 shl bitWidth)
  else:
    probes.add uint64.high

  for value in probes:
    for pos in 0..values.len:
      doAssert qwm.rank(value, int64(pos)) == wm.rank(value, int64(pos))
      doAssert qwm.rankLessThan(value, int64(pos)) ==
        wm.rankLessThan(value, int64(pos))
    for left in 0..min(values.len, 24):
      for right in left..min(values.len, 24):
        doAssert qwm.rank(value, int64(left), int64(right)) ==
          wm.rank(value, int64(left), int64(right))
        let qr = qwm.rankPair(value, int64(left), int64(right))
        let wr = wm.rankPair(value, int64(left), int64(right))
        doAssert qr == wr
        doAssert qwm.countLessThan(int64(left), int64(right), value) ==
          wm.countLessThan(int64(left), int64(right), value)

    let total = wm.rank(value, wm.n)
    for k in 0'i64..<min(total, 8'i64):
      doAssert qwm.select(value, k) == wm.select(value, k)
      doAssert qwm.selectNth(value, k + 1) == wm.selectNth(value, k + 1)
    doAssert qwm.select(value, total) == -1
    doAssert qwm.select(value, -1) == -1

  let shortN = min(values.len, 32)
  for left in 0..shortN:
    for right in left..shortN:
      var sorted = values[left..<right]
      sorted.sort()
      for k, expected in sorted:
        doAssert qwm.quantile(int64(left), int64(right), int64(k)) == expected
      for lower in 0'u64..8'u64:
        for upper in lower..9'u64:
          doAssert qwm.rangeFreq(int64(left), int64(right), lower, upper) ==
            wm.rangeFreq(int64(left), int64(right), lower, upper)

block emptyAndZeroWidth:
  let empty = genQuadWaveletMatrix(newSeq[uint64]())
  doAssert empty.n == 0
  doAssert empty.bitWidth == 0
  doAssert empty.levelCount == 0
  doAssert empty.rank(0, 0) == 0
  doAssert empty.select(0, 0) == -1
  expectRaises(IndexDefect):
    discard empty[0]

  let zeros = genQuadWaveletMatrix(@[0'u64, 0, 0], 0)
  doAssert zeros.levelCount == 0
  doAssert zeros.rank(0, 3) == 3
  doAssert zeros.select(0, 2) == 2
  doAssert zeros.select(1, 0) == -1
  doAssert zeros.quantile(0, 3, 1) == 0
  expectRaises(ValueError):
    discard genQuadWaveletMatrix(@[1'u64], 0)

block fixedWidths:
  checkEquivalent(@[0'u64, 1, 3, 7, 3, 1, 6, 2], 3)
  checkEquivalent(@[0'u64, 257, 3, 257, 1, 3, 511, 256], 9)
  checkEquivalent(@[0'u64, 1, 3, 7, 3, 1], 16)

block fullWidth:
  let values = @[uint64.high, 0'u64, 1'u64 shl 63,
                 uint64.high - 1, 7, 1'u64 shl 32]
  checkEquivalent(values, 64)

block genericFixedWidth:
  let expected = @[0'u64, 1, 3, 7, 3, 1]
  let q8 = genQuadWaveletMatrix(@[0'u8, 1, 3, 7, 3, 1], 3)
  let q16 = genQuadWaveletMatrix(@[0'u16, 1, 3, 7, 3, 1], 3)
  let q32 = genQuadWaveletMatrix(@[0'u32, 1, 3, 7, 3, 1], 3)
  for i, value in expected:
    doAssert q8[int64(i)] == value
    doAssert q16[int64(i)] == value
    doAssert q32[int64(i)] == value
  expectRaises(ValueError):
    discard genQuadWaveletMatrix(@[8'u16], 3)
  expectRaises(ValueError):
    discard genQuadWaveletMatrix(@[0'u16], -1)
  expectRaises(ValueError):
    discard genQuadWaveletMatrix(@[0'u16], 65)

block randomizedEquivalence:
  var rng = initRand(0x51574d)
  for trial in 0..<24:
    let length = 1 + rng.rand(180)
    let bitWidth = [1, 2, 3, 4, 7, 8, 9, 16, 32, 64][rng.rand(9)]
    var values = newSeq[uint64](length)
    for value in values.mitems:
      let hi = uint64(rng.rand(int.high))
      let lo = uint64(rng.rand(int.high))
      value = (hi shl 32) xor lo
      if bitWidth < 64:
        value = value and ((1'u64 shl bitWidth) - 1'u64)
    let wm = genWaveletMatrix(values, bitWidth)
    let qwm = genQuadWaveletMatrix(values, bitWidth)
    for sample in 0..<64:
      let pos = int64(rng.rand(length - 1))
      let right = int64(rng.rand(length))
      let value = values[rng.rand(length - 1)]
      doAssert qwm.access(pos) == wm.access(pos)
      doAssert qwm.rank(value, right) == wm.rank(value, right)
      let total = wm.rank(value, wm.n)
      if total > 0:
        let k = int64(rng.rand(int(total - 1)))
        doAssert qwm.select(value, k) == wm.select(value, k)

block mmapPersistence:
  const bitWidth = 17
  let values = @[0'u64, 1, 3, 7, 65535, 65536, 17, 3, 1, 131071,
                 9, 9, 9, 1024, 5, 7, 1, 2, 3, 4, 5, 6, 7, 8]
  let heap = genQuadWaveletMatrix(values, bitWidth)
  let requiredBytes = requiredQuadWaveletMatrixViewBytes(
    int64(values.len), bitWidth)
  let (file, path) = createTempFile("nbvs_qwm_view_", ".bin")
  file.close()
  defer: removeFile(path)

  var mapped = memfiles.open(path, mode = fmReadWrite,
    newFileSize = requiredBytes)
  try:
    var view = initQuadWaveletMatrixView(mapped.mem, mapped.size,
      int64(values.len), bitWidth)
    view.build(values)
    doAssert view.levelCount == heap.levelCount
    for i, value in values:
      doAssert view[int64(i)] == value
      doAssert view.accessRank(int64(i)) == heap.accessRank(int64(i))
    for value in values:
      doAssert view.rank(value, view.n) == heap.rank(value, heap.n)
      let total = heap.rank(value, heap.n)
      if total > 0:
        doAssert view.select(value, total - 1) == heap.select(value, total - 1)
  finally:
    mapped.close()

  mapped = memfiles.open(path, mode = fmReadWrite)
  try:
    let reopened = initQuadWaveletMatrixView(mapped.mem, mapped.size,
      int64(values.len), bitWidth, built = true)
    for i, value in values:
      doAssert reopened[int64(i)] == value
    for value in values:
      doAssert reopened.rank(value, reopened.n) == heap.rank(value, heap.n)
      let total = heap.rank(value, heap.n)
      if total > 0:
        doAssert reopened.select(value, 0) == heap.select(value, 0)
  finally:
    mapped.close()

block mmapValidation:
  expectRaises(ValueError):
    discard initQuadWaveletMatrixView(nil, 0, 1, 8)

  const n = 4097'i64
  const bitWidth = 9
  let requiredBytes = requiredQuadWaveletMatrixViewBytes(n, bitWidth)
  let (file, path) = createTempFile("nbvs_qwm_align_", ".bin")
  file.close()
  defer: removeFile(path)
  var mapped = memfiles.open(path, mode = fmReadWrite,
    newFileSize = requiredBytes + QuadVectorViewAlignment)
  try:
    expectRaises(ValueError):
      discard initQuadWaveletMatrixView(mapped.mem, requiredBytes - 1,
        n, bitWidth)
    let misaligned = cast[pointer](cast[uint](mapped.mem) + 1'u)
    expectRaises(ValueError):
      discard initQuadWaveletMatrixView(misaligned, mapped.size - 1,
        n, bitWidth)
  finally:
    mapped.close()
