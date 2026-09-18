import nbvs/[packed_array, succinct_bit_vector, succinct_permutation]
import ./test_common

proc memory[T](values: var seq[T]): pointer =
  if values.len == 0: nil else: addr values[0]

proc packedView(source: PackedArray,
    storage: var seq[uint64]): PackedArrayView =
  storage = source.data
  initPackedArrayView(storage.memory, storage.len * sizeof(uint64),
    source.len, source.bitWidth)

proc succinctView(source: SuccinctBitVector,
    storage: var seq[uint64]): SuccinctBitVectorView =
  storage = newSeq[uint64]((requiredSuccinctBitVectorViewBytes(
    source.lenOfBits) + 7) div 8)
  result = initSuccinctBitVectorView(storage.memory,
    storage.len * sizeof(uint64), source.lenOfBits)
  for position in 0'i64..<source.lenOfBits:
    if source[position]:
      result.setBit(position)
  result.build()

proc checkPermutation(values: seq[uint64], stride: int) =
  let permutation = genSuccinctPermutation(values, stride)
  doAssert permutation.n == int64(values.len)
  doAssert permutation.inverseStride == stride
  doAssert permutation.toSeq == values

  var iterated: seq[uint64]
  for value in permutation.items:
    iterated.add value
  doAssert iterated == values

  for index, value in values:
    doAssert permutation.access(int64(index)) == value
    doAssert permutation[int64(index)] == value
    doAssert permutation.accessUnchecked(index) == value
    doAssert permutation.inverse(value) == uint64(index)
    doAssert permutation.inverseUnchecked(value) == uint64(index)

  if values.len == 0:
    expectRaises(IndexDefect): discard permutation[0]
    expectRaises(IndexDefect): discard permutation.inverse(0)
  else:
    expectRaises(IndexDefect): discard permutation[-1]
    expectRaises(IndexDefect): discard permutation[int64(values.len)]
    expectRaises(IndexDefect): discard permutation.inverse(uint64(values.len))

  var valuesStorage: seq[uint64]
  var landmarkStorage: seq[uint64]
  var previousStorage: seq[uint64]
  let valuesView = packedView(permutation.values, valuesStorage)
  let landmarkView = succinctView(permutation.landmarks, landmarkStorage)
  let previousView = packedView(
    permutation.previousLandmarks, previousStorage)
  let view = initSuccinctPermutationView(
    permutation.n, stride, valuesView, landmarkView, previousView)

  doAssert view.toSeq == values
  doAssert view.landmarkCount == permutation.landmarkCount
  for index, value in values:
    doAssert view[int64(index)] == value
    doAssert view.inverse(value) == uint64(index)

block bitWidth:
  doAssert permutationBitWidth(0) == 0
  doAssert permutationBitWidth(1) == 0
  doAssert permutationBitWidth(2) == 1
  doAssert permutationBitWidth(3) == 2
  doAssert permutationBitWidth(4) == 2
  doAssert permutationBitWidth(5) == 3
  doAssert permutationBitWidth(65_536) == 16
  doAssert permutationBitWidth(65_537) == 17
  expectRaises(ValueError): discard permutationBitWidth(-1)

block emptyAndSingleton:
  checkPermutation(@[], 4)
  checkPermutation(@[0'u64], 4)

block identityUsesNoLandmarks:
  var values = newSeq[uint64](128)
  for i in 0..<values.len:
    values[i] = uint64(i)
  let permutation = genSuccinctPermutation(values, 8)
  doAssert permutation.landmarkCount == 0
  checkPermutation(values, 8)

block shortCyclesUseNoLandmarks:
  let values = @[1'u64, 0, 3, 4, 2, 6, 7, 5]
  let permutation = genSuccinctPermutation(values, 4)
  doAssert permutation.landmarkCount == 0
  checkPermutation(values, 4)

block longCycleUsesSparseLandmarks:
  const n = 65
  var values = newSeq[uint64](n)
  for i in 0..<n:
    values[i] = uint64((i + 1) mod n)

  let permutation = genSuccinctPermutation(values, 8)
  doAssert permutation.landmarkCount == 9
  checkPermutation(values, 8)

block mixedCycles:
  let values = @[
    1'u64, 2, 3, 4, 5, 6, 7, 8, 9, 0,  # length 10
    11, 10,                              # length 2
    13, 14, 15, 16, 17, 18, 12          # length 7
  ]
  let permutation = genSuccinctPermutation(values, 4)
  doAssert permutation.landmarkCount == 5
  checkPermutation(values, 4)

block deterministicLargePermutation:
  const n = 4096
  var values = newSeq[uint64](n)
  # gcd(4051, 4096) == 1 なので、このaffine mappingはpermutationになります。
  for i in 0..<n:
    values[i] = uint64((i * 4051 + 17) mod n)
  checkPermutation(values, 32)

block constructorErrors:
  expectRaises(ValueError):
    discard genSuccinctPermutation(@[0'u64], 0)
  expectRaises(ValueError):
    discard genSuccinctPermutation(@[0'u64, 0], 4)
  expectRaises(ValueError):
    discard genSuccinctPermutation(@[0'u64, 2], 4)

block viewMetadataValidation:
  let permutation = genSuccinctPermutation(@[1'u64, 2, 0], 2)

  var valuesStorage: seq[uint64]
  var landmarkStorage: seq[uint64]
  var previousStorage: seq[uint64]
  let valuesView = packedView(permutation.values, valuesStorage)
  let landmarkView = succinctView(permutation.landmarks, landmarkStorage)
  let previousView = packedView(
    permutation.previousLandmarks, previousStorage)

  expectRaises(ValueError):
    discard initSuccinctPermutationView(
      -1, 2, valuesView, landmarkView, previousView)
  expectRaises(ValueError):
    discard initSuccinctPermutationView(
      permutation.n, 0, valuesView, landmarkView, previousView)

  let wrongValues = initPackedArrayView(nil, 0, permutation.n, 0)
  expectRaises(ValueError):
    discard initSuccinctPermutationView(
      permutation.n, 2, wrongValues, landmarkView, previousView)

echo "OK tsuccinct_permutation"
