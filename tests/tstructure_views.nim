import std/[memfiles, os, strutils, tempfiles]
import nbvs/[bit_vector, packed_array, succinct_bit_vector, elias_fano,
  wavelet_matrix, reversed_wavelet_matrix, wavelet_matching_runs]
import ./test_common

proc storageForSuccinct(bitLength: int64): seq[uint64] =
  newSeq[uint64]((requiredSuccinctBitVectorViewBytes(bitLength) + 7) div 8)

proc initView(storage: var seq[uint64], bitLength: int64,
              built = false): SuccinctBitVectorView =
  let memory = if storage.len == 0: nil else: addr storage[0]
  initSuccinctBitVectorView(memory,
    storage.len * sizeof(uint64), bitLength, built)

proc copyBits(source: SuccinctBitVector,
              destination: var SuccinctBitVectorView) =
  for position in 0'i64..<source.lenOfBits:
    if source[position]:
      destination.setBit(position)
  destination.build()

block bitVectorViewCompatibility:
  let (file, path) = createTempFile("nbvs_bit_view_", ".bin")
  file.close()
  defer: removeFile(path)
  var mapped = memfiles.open(path, mode = fmReadWrite, newFileSize = 16)
  try:
    var view = initBitVectorView(mapped.mem, mapped.size, 128)
    view[0] = true
    view[65] = true
    doAssert view.access(0)
    doAssert view[65]
    doAssert view.lenOfBits == 66
    doAssert $view == "1" & repeat('0', 64) & "1"
  finally:
    mapped.close()
  mapped = memfiles.open(path, mode = fmReadWrite)
  try:
    let reopened = initBitVectorView(mapped.mem, mapped.size, 128, len = 66)
    doAssert reopened[0] and reopened[65]
  finally:
    mapped.close()

block succinctBitVectorViewCompatibility:
  for boundaryLength in [0'i64, 1, 511, 512, 513, 1024, 1025]:
    var boundaryStorage = storageForSuccinct(boundaryLength)
    var boundaryView = boundaryStorage.initView(boundaryLength)
    if boundaryLength > 0:
      boundaryView[boundaryLength - 1] = true
    boundaryView.build()
    doAssert boundaryView.totalOnes == (if boundaryLength > 0: 1 else: 0)

  const bitLength = 9000'i64
  var heap = genSuccinctBitVector(bitLength)
  var storage = storageForSuccinct(bitLength)
  var view = storage.initView(bitLength)
  for position in 0'i64..<bitLength:
    if position mod 7 == 0 or position mod 97 == 3:
      heap[position] = true
      view[position] = true
  heap.build()
  view.build()
  for position in [0'i64, 1, 511, 512, 8191, 8999, 9000]:
    doAssert view.rank1(position) == heap.rank1(position)
  for ordinal in [0'i64, 1, 20, heap.totalOnes - 1]:
    doAssert view.select1(ordinal) == heap.select1(ordinal)
  let reopened = storage.initView(bitLength, built = true)
  doAssert reopened.totalOnes == heap.totalOnes
  doAssert reopened.select0(100) == heap.select0(100)

block succinctBitVectorMmapPersistence:
  const bitLength = 2049'i64
  let requiredBytes = requiredSuccinctBitVectorViewBytes(bitLength)
  let (file, path) = createTempFile("nbvs_sbv_view_", ".bin")
  file.close()
  defer: removeFile(path)
  var mapped = memfiles.open(path, mode = fmReadWrite,
    newFileSize = requiredBytes)
  try:
    var view = initSuccinctBitVectorView(mapped.mem, mapped.size, bitLength)
    for position in [0'i64, 511, 512, 2048]: view[position] = true
    view.build()
    doAssert view.totalOnes == 4
  finally:
    mapped.close()
  mapped = memfiles.open(path, mode = fmReadWrite)
  try:
    let reopened = initSuccinctBitVectorView(mapped.mem, mapped.size,
      bitLength, built = true)
    doAssert reopened.totalOnes == 4
    doAssert reopened.select1(3) == 2048
  finally:
    mapped.close()

block eliasFanoViewCompatibility:
  let values = @[0'u64, 1, 1, 7, 15, 31]
  let heap = genEliasFano(values, 32)
  var lowStorage = newSeq[uint64](heap.lows.data.len)
  for index, word in heap.lows.data: lowStorage[index] = word
  let lowMemory = if lowStorage.len == 0: nil else: addr lowStorage[0]
  let lows = initPackedArrayView(lowMemory,
    lowStorage.len * sizeof(uint64), heap.n, heap.lowBits)
  var highStorage = storageForSuccinct(heap.highBits.lenOfBits)
  var highs = highStorage.initView(heap.highBits.lenOfBits)
  copyBits(heap.highBits, highs)
  let view = initEliasFanoView(heap.n, heap.universe, lows, highs)
  doAssert view.toSeq == heap.toSeq
  doAssert view.lowerBound(8) == heap.lowerBound(8)
  doAssert view.predecessor(20) == heap.predecessor(20)

block waveletViewsCompatibility:
  let values = @[5'u64, 1, 7, 5, 2, 9, 1]
  let heap = genWaveletMatrix(values)
  var levelStorage = newSeq[seq[uint64]](heap.bitWidth)
  var levelViews = newSeq[SuccinctBitVectorView](heap.bitWidth)
  for level in 0..<heap.bitWidth:
    levelStorage[level] = storageForSuccinct(heap.n)
    levelViews[level] = levelStorage[level].initView(heap.n)
    copyBits(heap.levels[level], levelViews[level])
  var zeros = heap.zeroCounts
  let view = initWaveletMatrixView(heap.n, heap.bitWidth,
    cast[ptr UncheckedArray[SuccinctBitVectorView]](addr levelViews[0]),
    levelViews.len, addr zeros[0], zeros.len * sizeof(int64))
  doAssert view.toSeq == values
  doAssert view.rank(5, 0, view.n) == heap.rank(5, 0, heap.n)
  doAssert view.quantile(0, view.n, 3) == heap.quantile(0, heap.n, 3)
  doAssert view.collectValueCounts == heap.collectValueCounts

  for value in [0'u64, 1, 5, 7, 9, uint64.high]:
    for left in 0'i64..heap.n:
      for right in left..heap.n:
        doAssert view.matchingRuns(value, left, right) ==
          heap.matchingRuns(value, left, right)
        doAssert view.collectMatchingRuns(value, left, right) ==
          heap.matchingRuns(value, left, right)

  let reversedHeap = genReversedWaveletMatrix(values)
  for level in 0..<reversedHeap.bitWidth:
    levelStorage[level] = storageForSuccinct(reversedHeap.n)
    levelViews[level] = levelStorage[level].initView(reversedHeap.n)
    copyBits(reversedHeap.levels[level], levelViews[level])
  zeros = reversedHeap.zeroCounts
  let reversedView = initReversedWaveletMatrixView(reversedHeap.n,
    reversedHeap.bitWidth,
    cast[ptr UncheckedArray[SuccinctBitVectorView]](addr levelViews[0]),
    levelViews.len, addr zeros[0], zeros.len * sizeof(int64))
  doAssert reversedView.toSeq == values
  doAssert reversedView.rank(1, reversedView.n) ==
    reversedHeap.rank(1, reversedHeap.n)
  doAssert reversedView.collectValueCounts == reversedHeap.collectValueCounts

block viewValidation:
  expectRaises(ValueError):
    discard initBitVectorView(nil, 0, 1)
  expectRaises(ValueError):
    discard initSuccinctBitVectorView(nil, 0, 1)
