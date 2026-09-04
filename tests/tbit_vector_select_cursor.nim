import nbvs

proc makeVector(bits: openArray[bool]): SuccinctBitVector =
  result = genSuccinctBitVector(bits.len.int64)
  for i, bit in bits:
    if bit:
      result[i.int64] = true
  result.build()

let bits = @[
  false, true, false, true, true, false, false, true,
  false, false, true, true, false, true, false, false,
  true, false, true, false, true, true, true, false]
let sbv = makeVector(bits)

block sequentialOnesMatchRegularSelect:
  var cursor = initBitVectorSelectCursor(true)
  for occurrence in 0'i64..<sbv.totalOnes:
    doAssert sbv.selectMonotonic(cursor, occurrence) == sbv.select1(occurrence)

block sequentialZerosMatchRegularSelect:
  var cursor = initBitVectorSelectCursor(false)
  for occurrence in 0'i64..<sbv.totalZeros:
    doAssert sbv.selectMonotonic(cursor, occurrence) == sbv.select0(occurrence)

block skippedOccurrencesRemainCorrect:
  var oneCursor = initBitVectorSelectCursor(true)
  for occurrence in [0'i64, 2, 5, sbv.totalOnes - 1]:
    doAssert sbv.selectMonotonic(oneCursor, occurrence) == sbv.select1(occurrence)

  var zeroCursor = initBitVectorSelectCursor(false)
  for occurrence in [0'i64, 3, 7, sbv.totalZeros - 1]:
    doAssert sbv.selectMonotonic(zeroCursor, occurrence) == sbv.select0(occurrence)

block nonIncreasingTargetFallsBackSafely:
  var cursor = initBitVectorSelectCursor(true)
  doAssert sbv.selectMonotonic(cursor, 4) == sbv.select1(4)
  doAssert sbv.selectMonotonic(cursor, 1) == sbv.select1(1)
  doAssert sbv.selectMonotonic(cursor, 2) == sbv.select1(2)

block outOfRangeReturnsMinusOne:
  var ones = initBitVectorSelectCursor(true)
  doAssert sbv.selectMonotonic(ones, -1) == -1
  doAssert sbv.selectMonotonic(ones, sbv.totalOnes) == -1

  var zeros = initBitVectorSelectCursor(false)
  doAssert sbv.selectMonotonic(zeros, -1) == -1
  doAssert sbv.selectMonotonic(zeros, sbv.totalZeros) == -1

block sparseFallbackMatchesRegularSelect:
  var sparse = genSuccinctBitVector(4096)
  for position in [1'i64, 1024, 2048, 3072, 4095]:
    sparse[position] = true
  sparse.build()

  var cursor = initBitVectorSelectCursor(true)
  for occurrence in 0'i64..<sparse.totalOnes:
    doAssert sparse.selectMonotonic(cursor, occurrence) == sparse.select1(occurrence)
