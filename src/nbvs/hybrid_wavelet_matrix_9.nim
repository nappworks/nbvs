## 9-bit専用の2値/4値 hybrid Wavelet Matrixです。
##
## 9-bit値を10-bitへpaddingして5段のQuadVectorにせず、
## 最上位bit 8を1段のSuccinctBitVector、その後bits 7..0を
## 4段のQuadVectorで処理します。
##
## FmDictionaryの258-symbol alphabet向けに、固定の
## SBV -> QV -> QV -> QV -> QV traversalを提供します。

import ./[quad_vector, quad_vector_view, succinct_bit_vector]

const
  HybridWavelet9BitWidth* = 9
  HybridWavelet9QuadLevels* = 4
  HybridWavelet9QuadShifts = [6, 4, 2, 0]
  HybridWavelet9MaxValue* = (1'u64 shl HybridWavelet9BitWidth) - 1'u64

type
  HybridWaveletMatrix9* = object
    n*: int64
    firstBits*: SuccinctBitVector
    firstZeroCount*: int64
    levels*: array[HybridWavelet9QuadLevels, QuadVector]
    bucketStarts*: array[HybridWavelet9QuadLevels, array[4, int64]]

  HybridWaveletMatrix9View* = object
    n*: int64
    firstBits*: SuccinctBitVectorView
    firstZeroCount*: int64
    levels*: array[HybridWavelet9QuadLevels, QuadVectorView]
    bucketStarts*: array[HybridWavelet9QuadLevels, array[4, int64]]

func startsFromCounts(counts: array[4, int64]): array[4, int64] {.inline.} =
  result[0] = 0
  result[1] = counts[0]
  result[2] = counts[0] + counts[1]
  result[3] = counts[0] + counts[1] + counts[2]

func valueFits(value: uint64): bool {.inline.} =
  value <= HybridWavelet9MaxValue

func checkIndex[W: HybridWaveletMatrix9 | HybridWaveletMatrix9View](
    wm: W, pos: int64) {.inline.} =
  if pos < 0 or pos >= wm.n:
    raise newException(IndexDefect, "index out of bounds")

func checkPosition[W: HybridWaveletMatrix9 | HybridWaveletMatrix9View](
    wm: W, pos: int64) {.inline.} =
  if pos < 0 or pos > wm.n:
    raise newException(IndexDefect, "position out of bounds")

func checkRange[W: HybridWaveletMatrix9 | HybridWaveletMatrix9View](
    wm: W, left, right: int64) {.inline.} =
  if left < 0 or left > right or right > wm.n:
    raise newException(IndexDefect, "range out of bounds")

func quadSymbolUnchecked[V: QuadVector | QuadVectorView](
    qv: V, pos: int64): int {.inline.} =
  let wordIndex = int(pos shr 5)
  let shift = int((pos and 31'i64) shl 1)
  int((qv.data.data[wordIndex] shr shift) and 3'u64)

func bitUnchecked[S: SuccinctBitVector | SuccinctBitVectorView](
    bits: S, pos: int64): bool {.inline.} =
  ((bits.data[int(pos shr 6)] shr int(pos and 63'i64)) and 1'u64) != 0

func quadAccessRankUnchecked[V: QuadVector | QuadVectorView](
    qv: V, pos: int64): tuple[symbol: uint8, rankBefore: int64] {.inline.} =
  when V is QuadVector:
    result = qv.accessRankUnchecked(pos)
  else:
    result.symbol = uint8(qv.quadSymbolUnchecked(pos))
    result.rankBefore = qv.rankUnchecked(int(result.symbol), pos)

func routeBit[S: SuccinctBitVector | SuccinctBitVectorView](
    bits: S, zeroCount, pos: int64, bit: bool): int64 {.inline.} =
  let ones = bits.rank1Unchecked(pos)
  if bit: zeroCount + ones else: pos - ones

proc writeQuadPayload[Value: SomeUnsignedInt](
    qv: var QuadVector, values: openArray[Value], shift: int) =
  let wordCount = (values.len + 31) shr 5
  for wordIndex in 0..<wordCount:
    let start = wordIndex shl 5
    let count = min(32, values.len - start)
    var word = 0'u64
    for lane in 0..<count:
      let symbol = (uint64(values[start + lane]) shr shift) and 3'u64
      word = word or (symbol shl (lane shl 1))
    qv.data.data[wordIndex] = word
  qv.isCalced = false

func genHybridWaveletMatrix9*[Value: SomeUnsignedInt](
    values: openArray[Value]): HybridWaveletMatrix9 =
  result.n = int64(values.len)
  if values.len == 0:
    return

  var current = newSeq[Value](values.len)
  var next = newSeq[Value](values.len)
  for i, value in values:
    if not valueFits(uint64(value)):
      raise newException(ValueError, "value exceeds 9-bit range")
    current[i] = value

  # bit 8を最初に2分岐する。FM alphabetでは256/257だけが1側なので、
  # Separator/byte-255系を最初に小さいbucketへ分離できる。
  result.firstBits = genSuccinctBitVector(result.n)
  for i, value in current:
    if ((uint64(value) shr 8) and 1'u64) != 0:
      result.firstBits[int64(i)] = true
  result.firstBits.build()
  result.firstZeroCount = result.n - result.firstBits.totalOnes

  var zeroPos = 0'i64
  var onePos = result.firstZeroCount
  for value in current:
    if ((uint64(value) shr 8) and 1'u64) != 0:
      next[int(onePos)] = value
      inc onePos
    else:
      next[int(zeroPos)] = value
      inc zeroPos
  swap(current, next)

  for level in 0..<HybridWavelet9QuadLevels:
    let shift = HybridWavelet9QuadShifts[level]
    result.levels[level] = genQuadVector(result.n)
    result.levels[level].writeQuadPayload(current, shift)
    result.levels[level].build()
    result.bucketStarts[level] =
      startsFromCounts(result.levels[level].totalCounts)

    var nextPos = result.bucketStarts[level]
    for value in current:
      let symbol = int((uint64(value) shr shift) and 3'u64)
      next[int(nextPos[symbol])] = value
      inc nextPos[symbol]
    swap(current, next)

func initHybridWaveletMatrix9View*(
    n: int64,
    firstBits: SuccinctBitVectorView,
    firstZeroCount: int64,
    levels: array[HybridWavelet9QuadLevels, QuadVectorView],
    bucketStarts: array[HybridWavelet9QuadLevels, array[4, int64]]
    ): HybridWaveletMatrix9View =
  if n < 0:
    raise newException(ValueError, "n must be non-negative")
  if firstBits.lenOfBits != n or not firstBits.isCalced:
    raise newException(ValueError, "invalid hybrid first bitvector")
  if firstZeroCount < 0 or firstZeroCount > n:
    raise newException(ValueError, "invalid hybrid first zero count")
  for level in 0..<HybridWavelet9QuadLevels:
    if levels[level].lenOfSymbols != n or not levels[level].isCalced:
      raise newException(ValueError, "invalid hybrid QuadVector level")
    let starts = bucketStarts[level]
    if starts[0] != 0 or starts[1] < 0 or starts[1] > starts[2] or
        starts[2] > starts[3] or starts[3] > n:
      raise newException(ValueError, "invalid hybrid bucket starts")
  result = HybridWaveletMatrix9View(
    n: n, firstBits: firstBits, firstZeroCount: firstZeroCount,
    levels: levels, bucketStarts: bucketStarts)

func access*[W: HybridWaveletMatrix9 | HybridWaveletMatrix9View](
    wm: W, pos: int64): uint64 =
  wm.checkIndex(pos)
  var current = pos
  let firstBit = wm.firstBits.bitUnchecked(current)
  if firstBit:
    result = 1'u64 shl 8
  current = wm.firstBits.routeBit(wm.firstZeroCount, current, firstBit)

  for level in 0..<HybridWavelet9QuadLevels:
    let symbol = wm.levels[level].quadSymbolUnchecked(current)
    result = result or
      (uint64(symbol) shl HybridWavelet9QuadShifts[level])
    current = wm.bucketStarts[level][symbol] +
      wm.levels[level].rankUnchecked(symbol, current)

func `[]`*[W: HybridWaveletMatrix9 | HybridWaveletMatrix9View](
    wm: W, pos: int64): uint64 {.inline.} =
  wm.access(pos)

func accessRankUnchecked*[
    W: HybridWaveletMatrix9 | HybridWaveletMatrix9View](
    wm: W, pos: int64): tuple[value: uint64, rankBefore: int64] =
  var current = pos
  var intervalLeft = 0'i64

  let first = wm.firstBits.accessRank1Unchecked(current)
  let leftOnes = wm.firstBits.rank1Unchecked(intervalLeft)
  if first.bit:
    result.value = 1'u64 shl 8
    current = wm.firstZeroCount + first.rankBefore
    intervalLeft = wm.firstZeroCount + leftOnes
  else:
    current -= first.rankBefore
    intervalLeft -= leftOnes

  for level in 0..<HybridWavelet9QuadLevels:
    let item = wm.levels[level].quadAccessRankUnchecked(current)
    let symbol = int(item.symbol)
    result.value = result.value or
      (uint64(symbol) shl HybridWavelet9QuadShifts[level])
    let leftRank = wm.levels[level].rankUnchecked(symbol, intervalLeft)
    current = wm.bucketStarts[level][symbol] + item.rankBefore
    intervalLeft = wm.bucketStarts[level][symbol] + leftRank

  result.rankBefore = current - intervalLeft

func accessRank*[W: HybridWaveletMatrix9 | HybridWaveletMatrix9View](
    wm: W, pos: int64): tuple[value: uint64, rankBefore: int64] =
  wm.checkIndex(pos)
  wm.accessRankUnchecked(pos)

func rank*[W: HybridWaveletMatrix9 | HybridWaveletMatrix9View](
    wm: W, value: uint64, pos: int64): int64 =
  wm.checkPosition(pos)
  if wm.n == 0 or not valueFits(value):
    return 0

  let firstBit = ((value shr 8) and 1'u64) != 0
  var left = wm.firstBits.routeBit(wm.firstZeroCount, 0, firstBit)
  var right = wm.firstBits.routeBit(wm.firstZeroCount, pos, firstBit)

  for level in 0..<HybridWavelet9QuadLevels:
    let symbol = int((value shr HybridWavelet9QuadShifts[level]) and 3'u64)
    let start = wm.bucketStarts[level][symbol]
    left = start + wm.levels[level].rankUnchecked(symbol, left)
    right = start + wm.levels[level].rankUnchecked(symbol, right)
  result = right - left

func rank*[W: HybridWaveletMatrix9 | HybridWaveletMatrix9View](
    wm: W, value: uint64, left, right: int64): int64 =
  wm.checkRange(left, right)
  if left == right or wm.n == 0 or not valueFits(value):
    return 0

  let firstBit = ((value shr 8) and 1'u64) != 0
  var lo = wm.firstBits.routeBit(wm.firstZeroCount, left, firstBit)
  var hi = wm.firstBits.routeBit(wm.firstZeroCount, right, firstBit)

  for level in 0..<HybridWavelet9QuadLevels:
    let symbol = int((value shr HybridWavelet9QuadShifts[level]) and 3'u64)
    let start = wm.bucketStarts[level][symbol]
    lo = start + wm.levels[level].rankUnchecked(symbol, lo)
    hi = start + wm.levels[level].rankUnchecked(symbol, hi)
  result = hi - lo

func rankPair*[W: HybridWaveletMatrix9 | HybridWaveletMatrix9View](
    wm: W, value: uint64, left, right: int64):
    tuple[leftRank, rightRank: int64] =
  wm.checkRange(left, right)
  if wm.n == 0 or not valueFits(value):
    return

  let firstBit = ((value shr 8) and 1'u64) != 0
  var startPos = wm.firstBits.routeBit(wm.firstZeroCount, 0, firstBit)
  var leftPos = wm.firstBits.routeBit(wm.firstZeroCount, left, firstBit)
  var rightPos = wm.firstBits.routeBit(wm.firstZeroCount, right, firstBit)

  for level in 0..<HybridWavelet9QuadLevels:
    let symbol = int((value shr HybridWavelet9QuadShifts[level]) and 3'u64)
    let bucket = wm.bucketStarts[level][symbol]
    startPos = bucket + wm.levels[level].rankUnchecked(symbol, startPos)
    leftPos = bucket + wm.levels[level].rankUnchecked(symbol, leftPos)
    rightPos = bucket + wm.levels[level].rankUnchecked(symbol, rightPos)

  result.leftRank = leftPos - startPos
  result.rightRank = rightPos - startPos

func select*[W: HybridWaveletMatrix9 | HybridWaveletMatrix9View](
    wm: W, value: uint64, k: int64): int64 =
  if k < 0 or wm.n == 0 or not valueFits(value):
    return -1

  let firstBit = ((value shr 8) and 1'u64) != 0
  var left = wm.firstBits.routeBit(wm.firstZeroCount, 0, firstBit)
  var right = wm.firstBits.routeBit(wm.firstZeroCount, wm.n, firstBit)

  for level in 0..<HybridWavelet9QuadLevels:
    let symbol = int((value shr HybridWavelet9QuadShifts[level]) and 3'u64)
    let start = wm.bucketStarts[level][symbol]
    left = start + wm.levels[level].rankUnchecked(symbol, left)
    right = start + wm.levels[level].rankUnchecked(symbol, right)
  if k >= right - left:
    return -1

  var pos = left + k
  for level in countdown(HybridWavelet9QuadLevels - 1, 0):
    let symbol = int((value shr HybridWavelet9QuadShifts[level]) and 3'u64)
    pos = wm.levels[level].select(symbol,
      pos - wm.bucketStarts[level][symbol])
    if pos < 0:
      return -1

  if firstBit:
    pos = wm.firstBits.select1(pos - wm.firstZeroCount)
  else:
    pos = wm.firstBits.select0(pos)
  result = pos

func selectNth*[W: HybridWaveletMatrix9 | HybridWaveletMatrix9View](
    wm: W, value: uint64, nth: int64): int64 {.inline.} =
  if nth <= 0: -1 else: wm.select(value, nth - 1)

func estimateHybridWaveletMatrix9Bytes*(n: int64): int64 =
  ## build前のbackend選択用概算です。QuadVector select sampleはworst-caseで見積もります。
  if n <= 0:
    return 0

  let quadPayloadBytes = ((n + 31) div 32) * 8
  let quadRankBytes = ((n + 4095) div 4096) * 64
  var maxSelectWords = 0'i64
  let positiveLimit = min(4'i64, n)
  for positiveSymbols in 1'i64..positiveLimit:
    let words = positiveSymbols + (n - positiveSymbols) div 2048'i64
    if words > maxSelectWords:
      maxSelectWords = words
  let quadBytes = quadPayloadBytes + quadRankBytes + maxSelectWords * 8
  result = estimateSuccinctBitVectorBytes(n) +
    int64(HybridWavelet9QuadLevels) * quadBytes +
    int64(sizeof(int64) + HybridWavelet9QuadLevels * 4 * sizeof(int64))

func hybridWaveletMatrix9Bytes*(wm: HybridWaveletMatrix9): int64 =
  result += int64(wm.firstBits.data.len * sizeof(uint64))
  result += int64(wm.firstBits.selectStorage.len * sizeof(uint64))
  for level in 0..<HybridWavelet9QuadLevels:
    let qv = wm.levels[level]
    result += int64(qv.data.data.len * sizeof(uint64))
    result += int64(qv.rankMetadata.data.len * sizeof(uint64))
    for symbol in 0..3:
      result += int64(qv.selectSamples[symbol].len * sizeof(uint32))
  result += int64(sizeof(int64) +
    HybridWavelet9QuadLevels * 4 * sizeof(int64))

func hybridWaveletMatrix9Bytes*(wm: HybridWaveletMatrix9View): int64 =
  result += int64(wm.firstBits.data.len * sizeof(uint64))
  result += int64(wm.firstBits.selectStorage.len * sizeof(uint64))
  for level in 0..<HybridWavelet9QuadLevels:
    let qv = wm.levels[level]
    result += int64(qv.data.dataWords * sizeof(uint64))
    result += int64(qv.rankMetadata.dataWords * sizeof(uint64))
    result += int64(qv.selectStorageUsedWords * sizeof(uint64))
  result += int64(sizeof(int64) +
    HybridWavelet9QuadLevels * 4 * sizeof(int64))
