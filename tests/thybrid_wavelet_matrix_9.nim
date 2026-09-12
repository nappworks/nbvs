import std/[algorithm, random]
import nbvs/[hybrid_wavelet_matrix_9, wavelet_matrix]

proc checkEquivalent(values: seq[uint64]) =
  let binary = genWaveletMatrix(values, HybridWavelet9BitWidth)
  let hybrid = genHybridWaveletMatrix9(values)
  doAssert hybrid.n == binary.n

  for i, value in values:
    let pos = int64(i)
    doAssert hybrid.access(pos) == value
    doAssert hybrid[pos] == binary[pos]
    doAssert hybrid.accessRank(pos) == binary.accessRank(pos)
    doAssert hybrid.accessRankUnchecked(pos) == binary.accessRankUnchecked(pos)

  var probes = @[0'u64, 1, 2, 3, 127, 128, 255, 256, 257, 511]
  for value in values:
    if value notin probes and probes.len < 32:
      probes.add value

  for value in probes:
    for pos in 0..values.len:
      doAssert hybrid.rank(value, int64(pos)) ==
        binary.rank(value, int64(pos))

    let shortN = min(values.len, 32)
    for left in 0..shortN:
      for right in left..shortN:
        doAssert hybrid.rank(value, int64(left), int64(right)) ==
          binary.rank(value, int64(left), int64(right))
        doAssert hybrid.rankPair(value, int64(left), int64(right)) ==
          binary.rankPair(value, int64(left), int64(right))

    let total = binary.rank(value, binary.n)
    for k in 0'i64..<min(total, 12'i64):
      doAssert hybrid.select(value, k) == binary.select(value, k)
      doAssert hybrid.selectNth(value, k + 1) ==
        binary.selectNth(value, k + 1)
    doAssert hybrid.select(value, total) == -1
    doAssert hybrid.select(value, -1) == -1

block knownValues:
  checkEquivalent(@[
    0'u64, 1, 2, 3, 255, 256, 257, 511,
    257, 0, 256, 1, 3, 127, 128, 255
  ])

block fmAlphabet:
  var values: seq[uint64]
  for value in 0'u64..257'u64:
    values.add value
    if (value and 7'u64) == 0:
      values.add value
  checkEquivalent(values)

block randomized:
  var rng = initRand(0x4839574d)
  for trial in 0..<32:
    let length = 1 + rng.rand(300)
    var values = newSeq[uint64](length)
    for value in values.mitems:
      value = uint64(rng.rand(511))
    checkEquivalent(values)

block validation:
  let empty = genHybridWaveletMatrix9(newSeq[uint64]())
  doAssert empty.n == 0
  doAssert empty.rank(0, 0) == 0
  doAssert empty.select(0, 0) == -1

  var raised = false
  try:
    discard genHybridWaveletMatrix9(@[512'u64])
  except ValueError:
    raised = true
  doAssert raised

echo "OK thybrid_wavelet_matrix_9"
