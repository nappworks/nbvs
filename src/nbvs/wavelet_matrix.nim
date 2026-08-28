## Wavelet matrix for unsigned 64-bit integer sequences.
##
## Positions are 0-based and all ranges use half-open `[left, right)`
## semantics. The structure is immutable after construction.

import std/bitops
import succinct_bit_vector

type
  ValueCount* = tuple[value: uint64, frequency: int64]
    ## A distinct value and its number of occurrences.

  ValueCountFinalInterval* = tuple[
    value: uint64, frequency: int64, left, right: int64]
    ## 異なる値、出現頻度、および同じ探索で到達した最終Wavelet区間です。
    ## 区間は半開区間 `[left, right)` です。

  TraversalNode = tuple[level: int, left, right: int64, value: uint64]

  WaveletMatrix* = object
    ## Rank/select-capable representation of a `uint64` sequence.
    n*: int64               ## Number of values.
    bitWidth*: int          ## Number of significant bit levels (0 for an empty input).
    levels*: seq[SuccinctBitVector] ## Bit vectors, from most to least significant.
    zeroCounts*: seq[int64] ## Number of zero bits at each level.

  WaveletMatrixView* = object
    ## 下位の `SuccinctBitVectorView` 群を参照する非所有Wavelet Matrixです。
    n*: int64
    bitWidth*: int
    levels*: ExternalSpan[SuccinctBitVectorView]
    zeroCounts*: ExternalSpan[int64]

func initWaveletMatrixView*(n: int64, bitWidth: int,
    levels: ptr UncheckedArray[SuccinctBitVectorView], levelCount: int,
    zeroCounts: pointer, zeroCountsBytes: int): WaveletMatrixView =
  ## 呼び出し側が保持するlevel descriptor列とzero-count列からViewを作成します。
  ##
  ## descriptor列自体もViewより長く有効に保つ必要があります。各levelの長さ・build
  ## 状態、zero-count領域の容量とalignmentを検証します。
  if n < 0 or bitWidth < 0 or bitWidth > 64:
    raise newException(ValueError, "invalid Wavelet Matrix metadata")
  if levelCount != bitWidth:
    raise newException(ValueError, "level count does not match bitWidth")
  if bitWidth > 0 and levels == nil:
    raise newException(ValueError, "levels must not be nil")
  let requiredZeroBytes = bitWidth * sizeof(int64)
  if zeroCountsBytes < requiredZeroBytes:
    raise newException(ValueError, "zero-count memory is too small")
  if requiredZeroBytes > 0:
    if zeroCounts == nil:
      raise newException(ValueError, "zero-count memory must not be nil")
    if cast[uint](zeroCounts) mod uint(alignof(int64)) != 0'u:
      raise newException(ValueError, "zero-count memory is not int64-aligned")
  for level in 0..<bitWidth:
    if levels[level].lenOfBits != n or not levels[level].isCalced:
      raise newException(ValueError, "invalid succinct bit-vector level")
  result.n = n
  result.bitWidth = bitWidth
  result.levels = ExternalSpan[SuccinctBitVectorView](data: levels,
    len: levelCount)
  result.zeroCounts = ExternalSpan[int64](
    data: cast[ptr UncheckedArray[int64]](zeroCounts), len: bitWidth)

func valueBitWidth(x: uint64): int {.inline.} =
  if x == 0:
    1
  else:
    64 - countLeadingZeroBits(x)

func buildLevelBits[Value: SomeUnsignedInt](values: openArray[Value],
                    shift: int): tuple[bits: SuccinctBitVector, zeros: int] =
  result.bits = genSuccinctBitVector(int64(values.len))
  let wordCount = (values.len + 63) shr 6
  for wordIndex in 0..<wordCount:
    let start = wordIndex shl 6
    let bitCount = min(64, values.len - start)
    var word = 0'u64
    for bitIndex in 0..<bitCount:
      word = word or
        (((uint64(values[start + bitIndex]) shr shift) and 1'u64) shl bitIndex)
    result.bits.data[wordIndex] = word
    result.zeros += bitCount - countSetBits(word)
  result.bits.build()

func genWaveletMatrix*(xs: openArray[uint64]): WaveletMatrix =
  ## Constructs a wavelet matrix. Input order and duplicate values are kept.
  result.n = int64(xs.len)
  if xs.len == 0:
    return

  var maximum = 0'u64
  for x in xs:
    if x > maximum:
      maximum = x

  result.bitWidth = valueBitWidth(maximum)
  result.levels = newSeq[SuccinctBitVector](result.bitWidth)
  result.zeroCounts = newSeq[int64](result.bitWidth)

  var current = newSeq[uint64](xs.len)
  for i, x in xs:
    current[i] = x
  var next = newSeq[uint64](xs.len)

  for level in 0..<result.bitWidth:
    let shift = result.bitWidth - level - 1
    let (bits, zeros) = buildLevelBits(current, shift)
    result.levels[level] = bits
    result.zeroCounts[level] = int64(zeros)

    var zeroPos = 0
    var onePos = zeros
    for x in current:
      if ((x shr shift) and 1'u64) == 0:
        next[zeroPos] = x
        inc zeroPos
      else:
        next[onePos] = x
        inc onePos
    swap(current, next)

func genWaveletMatrix*[Value: SomeUnsignedInt](values: openArray[Value],
    bitWidth: int): WaveletMatrix =
  ## 指定した固定bit幅でWavelet Matrixを構築します。
  ##
  ## `bitWidth` は `0..64` で、すべての値がその幅に収まる必要があります。
  if bitWidth < 0 or bitWidth > 64:
    raise newException(ValueError, "bitWidth must be in 0..64")
  for value in values:
    if bitWidth == 0:
      if value != 0:
        raise newException(ValueError, "value exceeds bitWidth")
    elif bitWidth < 64 and (value shr bitWidth) != 0:
      raise newException(ValueError, "value exceeds bitWidth")

  result.n = int64(values.len)
  result.bitWidth = bitWidth
  result.levels = newSeq[SuccinctBitVector](bitWidth)
  result.zeroCounts = newSeq[int64](bitWidth)
  if values.len == 0 or bitWidth == 0:
    return

  var current = newSeq[Value](values.len)
  for index, value in values:
    current[index] = value
  var next = newSeq[Value](values.len)

  for level in 0..<bitWidth:
    let shift = bitWidth - level - 1
    let (bits, zeros) = buildLevelBits(current, shift)
    result.levels[level] = bits
    result.zeroCounts[level] = int64(zeros)
    var zeroPos = 0
    var onePos = zeros
    for value in current:
      if ((uint64(value) shr shift) and 1'u64) == 0:
        next[zeroPos] = value
        inc zeroPos
      else:
        next[onePos] = value
        inc onePos
    swap(current, next)

func checkIndex[W: WaveletMatrix | WaveletMatrixView](wm: W, i: int64) {.inline.} =
  if i < 0 or i >= wm.n:
    raise newException(IndexDefect, "index out of bounds")

func checkPosition[W: WaveletMatrix | WaveletMatrixView](wm: W, pos: int64) {.inline.} =
  if pos < 0 or pos > wm.n:
    raise newException(IndexDefect, "position out of bounds")

func checkRange[W: WaveletMatrix | WaveletMatrixView](wm: W, left, right: int64) {.inline.} =
  if left < 0 or left > right or right > wm.n:
    raise newException(IndexDefect, "range out of bounds")

func valueFits[W: WaveletMatrix | WaveletMatrixView](wm: W, value: uint64): bool {.inline.} =
  wm.bitWidth == 64 or (wm.bitWidth > 0 and (value shr wm.bitWidth) == 0)

func bitAtUnchecked[B: SuccinctBitVector | SuccinctBitVectorView](
    bits: B, pos: int64): bool {.inline.} =
  ((bits.data[int(pos shr 6)] shr int(pos and 63)) and 1'u64) != 0

func access*[W: WaveletMatrix | WaveletMatrixView](wm: W, i: int64): uint64 =
  ## Returns the value at index `i`.
  wm.checkIndex(i)
  var pos = i

  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let ones = wm.levels[level].rank1Unchecked(pos)
    if wm.levels[level].bitAtUnchecked(pos):
      result = result or (1'u64 shl shift)
      pos = wm.zeroCounts[level] + ones
    else:
      pos -= ones

func accessRankUnchecked*[W: WaveletMatrix | WaveletMatrixView](wm: W,
    pos: int64): tuple[value: uint64, rankBefore: int64] =
  ## 検査なしで`pos`の値と同値の`[0, pos)`における出現数を返します。
  ##
  ## 呼び出し側は`0 <= pos < wm.n`を保証する必要があります。FM内部の
  ## LF traversalなど、範囲が既に保証されたhot path向けです。
  var current = pos
  var intervalLeft = 0'i64
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let currentOnes = wm.levels[level].rank1Unchecked(current)
    let leftOnes = wm.levels[level].rank1Unchecked(intervalLeft)
    if wm.levels[level].bitAtUnchecked(current):
      result.value = result.value or (1'u64 shl shift)
      current = wm.zeroCounts[level] + currentOnes
      intervalLeft = wm.zeroCounts[level] + leftOnes
    else:
      current -= currentOnes
      intervalLeft -= leftOnes
  result.rankBefore = current - intervalLeft

func accessRank*[W: WaveletMatrix | WaveletMatrixView](wm: W,
                 pos: int64): tuple[value: uint64, rankBefore: int64] =
  ## `pos` の値と、同じ値の `[0, pos)` における出現回数を返します。
  ##
  ## accessとrankに共通する経路を融合し、`O(bitWidth)` 時間で処理します。
  wm.checkIndex(pos)
  wm.accessRankUnchecked(pos)

func `[]`*[W: WaveletMatrix | WaveletMatrixView](wm: W, i: int64): uint64 =
  ## Alias for `access(wm, i)`.
  wm.access(i)

func rank*[W: WaveletMatrix | WaveletMatrixView](wm: W, value: uint64, pos: int64): int64 =
  ## Counts occurrences of `value` in `[0, pos)`.
  wm.checkPosition(pos)
  if wm.n == 0 or not wm.valueFits(value):
    return 0

  var left = 0'i64
  var right = pos
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    if ((value shr shift) and 1'u64) == 0:
      left -= wm.levels[level].rank1Unchecked(left)
      right -= wm.levels[level].rank1Unchecked(right)
    else:
      left = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(left)
      right = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(right)
  result = right - left

func rank*[W: WaveletMatrix | WaveletMatrixView](wm: W, value: uint64, left, right: int64): int64 =
  ## Counts occurrences of `value` in `[left, right)`.
  wm.checkRange(left, right)
  if left == right or wm.n == 0 or not wm.valueFits(value):
    return 0

  var lo = left
  var hi = right
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    if ((value shr shift) and 1'u64) == 0:
      lo -= wm.levels[level].rank1Unchecked(lo)
      hi -= wm.levels[level].rank1Unchecked(hi)
    else:
      lo = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(lo)
      hi = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(hi)
  result = hi - lo

func rankPair*[W: WaveletMatrix | WaveletMatrixView](wm: W, value: uint64, left,
               right: int64): tuple[leftRank, rightRank: int64] =
  ## `value`の`[0, left)`と`[0, right)`におけるrankを同時に返します。
  ##
  ## `left <= right`の半開区間を検証し、`O(bitWidth)`時間で処理します。
  wm.checkRange(left, right)
  if wm.n == 0 or not wm.valueFits(value):
    return

  var start = 0'i64
  var leftPos = left
  var rightPos = right
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let startOnes = wm.levels[level].rank1Unchecked(start)
    let leftPosOnes = wm.levels[level].rank1Unchecked(leftPos)
    let rightPosOnes = wm.levels[level].rank1Unchecked(rightPos)
    if ((value shr shift) and 1'u64) == 0:
      start -= startOnes
      leftPos -= leftPosOnes
      rightPos -= rightPosOnes
    else:
      start = wm.zeroCounts[level] + startOnes
      leftPos = wm.zeroCounts[level] + leftPosOnes
      rightPos = wm.zeroCounts[level] + rightPosOnes
  result.leftRank = leftPos - start
  result.rightRank = rightPos - start

func rankIncl*[W: WaveletMatrix | WaveletMatrixView](wm: W, value: uint64, pos: int64): int64 =
  ## Counts occurrences of `value` in `[0, pos]`.
  wm.checkIndex(pos)
  result = wm.rank(value, pos + 1)

func select*[W: WaveletMatrix | WaveletMatrixView](wm: W, value: uint64, k: int64): int64 =
  ## Returns the position of the 0-based `k`-th occurrence, or `-1`.
  if k < 0 or wm.n == 0 or not wm.valueFits(value):
    return -1

  var left = 0'i64
  var right = wm.n
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    if ((value shr shift) and 1'u64) == 0:
      left -= wm.levels[level].rank1Unchecked(left)
      right -= wm.levels[level].rank1Unchecked(right)
    else:
      left = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(left)
      right = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(right)

  if k >= right - left:
    return -1

  var pos = left + k
  for level in countdown(wm.bitWidth - 1, 0):
    let shift = wm.bitWidth - level - 1
    if ((value shr shift) and 1'u64) == 0:
      pos = wm.levels[level].select0(pos)
    else:
      pos = wm.levels[level].select1(pos - wm.zeroCounts[level])
  result = pos

func selectNth*[W: WaveletMatrix | WaveletMatrixView](wm: W, value: uint64, nth: int64): int64 =
  ## Returns the position of the 1-based `nth` occurrence, or `-1`.
  if nth <= 0:
    return -1
  result = wm.select(value, nth - 1)

func countLessThan*[W: WaveletMatrix | WaveletMatrixView](wm: W, left, right: int64,
                    value: uint64): int64 =
  ## Counts values smaller than `value` in `[left, right)`.
  wm.checkRange(left, right)
  if left == right or wm.n == 0:
    return 0
  if not wm.valueFits(value):
    return right - left

  var lo = left
  var hi = right
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let loOnes = wm.levels[level].rank1Unchecked(lo)
    let hiOnes = wm.levels[level].rank1Unchecked(hi)
    let loZeros = lo - loOnes
    let hiZeros = hi - hiOnes
    if ((value shr shift) and 1'u64) == 0:
      lo = loZeros
      hi = hiZeros
    else:
      result += hiZeros - loZeros
      lo = wm.zeroCounts[level] + loOnes
      hi = wm.zeroCounts[level] + hiOnes

func rankLessThan*[W: WaveletMatrix | WaveletMatrixView](wm: W, value: uint64, pos: int64): int64 =
  ## Counts values smaller than `value` in `[0, pos)`.
  ##
  ## Runs in `O(bitWidth)` time.
  result = wm.countLessThan(0, pos, value)

func occPosition*[W: WaveletMatrix | WaveletMatrixView](wm: W, value: uint64, pos: int64): int64 =
  ## 安定な全体昇順列で、`[0, pos)` に由来する `value` の終端位置を返します。
  ##
  ## 単純な出現回数ではなく、列全体にある `value` 未満の要素数と、
  ## 半開区間 `[0, pos)` にある `value` の出現回数の和です。
  ## FM-indexにおける `C[value] + Occ(value, pos)` に相当します。
  wm.checkPosition(pos)
  if wm.n == 0:
    return 0
  if not wm.valueFits(value):
    return wm.n
  result = wm.rankLessThan(value, wm.n) + wm.rank(value, pos)

func rangeFreq*[W: WaveletMatrix | WaveletMatrixView](wm: W, left, right: int64,
                lower, upper: uint64): int64 =
  ## Counts values in `[lower, upper)` within positions `[left, right)`.
  wm.checkRange(left, right)
  if lower >= upper:
    return 0
  result = wm.countLessThan(left, right, upper) -
    wm.countLessThan(left, right, lower)

func quantile*[W: WaveletMatrix | WaveletMatrixView](wm: W, left, right, k: int64): uint64 =
  ## Returns the 0-based `k`-th smallest value in `[left, right)`.
  wm.checkRange(left, right)
  if k < 0 or k >= right - left:
    raise newException(IndexDefect, "quantile index out of bounds")

  var lo = left
  var hi = right
  var rest = k
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let loOnes = wm.levels[level].rank1Unchecked(lo)
    let hiOnes = wm.levels[level].rank1Unchecked(hi)
    let loZeros = lo - loOnes
    let hiZeros = hi - hiOnes
    let zeros = hiZeros - loZeros
    if rest < zeros:
      lo = loZeros
      hi = hiZeros
    else:
      result = result or (1'u64 shl shift)
      rest -= zeros
      lo = wm.zeroCounts[level] + loOnes
      hi = wm.zeroCounts[level] + hiOnes

func predecessor*[W: WaveletMatrix | WaveletMatrixView](wm: W, left, right: int64,
                  upper: uint64): uint64 =
  ## Returns the greatest value `< upper` in `[left, right)`.
  ## Raises `ValueError` when no such value exists.
  let count = wm.countLessThan(left, right, upper)
  if count == 0:
    raise newException(ValueError, "predecessor does not exist")
  result = wm.quantile(left, right, count - 1)

func successor*[W: WaveletMatrix | WaveletMatrixView](wm: W, left, right: int64,
                lower: uint64): uint64 =
  ## Returns the smallest value `>= lower` in `[left, right)`.
  ## Raises `ValueError` when no such value exists.
  let count = wm.countLessThan(left, right, lower)
  if count >= right - left:
    raise newException(ValueError, "successor does not exist")
  result = wm.quantile(left, right, count)

iterator items*[W: WaveletMatrix | WaveletMatrixView](wm: W): uint64 =
  ## Iterates over values in original order.
  for i in 0'i64..<wm.n:
    yield wm.access(i)

func toSeq*[W: WaveletMatrix | WaveletMatrixView](wm: W): seq[uint64] =
  ## Decodes the matrix to a sequence in original order.
  result = newSeq[uint64](int(wm.n))
  for i in 0'i64..<wm.n:
    result[int(i)] = wm.access(i)

iterator collectValueCountsItems*[W: WaveletMatrix | WaveletMatrixView](wm: W,
                                  left, right: int64): ValueCount =
  ## `[left, right)` の異なる値と頻度を内部探索順で逐次返します。
  ##
  ## 探索時間は概ね `O(σ * bitWidth)`、明示スタックの追加領域は
  ## 探索中のノード数に依存します。`σ` は異なる値の数です。
  wm.checkRange(left, right)
  var stack: seq[TraversalNode] =
    @[(level: 0, left: left, right: right, value: 0'u64)]
  while stack.len > 0:
    let node = stack.pop()
    if node.left >= node.right:
      continue
    if node.level == wm.bitWidth:
      yield (value: node.value, frequency: node.right - node.left)
      continue

    let shift = wm.bitWidth - node.level - 1
    let leftOnes = wm.levels[node.level].rank1Unchecked(node.left)
    let rightOnes = wm.levels[node.level].rank1Unchecked(node.right)
    let oneLeft = wm.zeroCounts[node.level] + leftOnes
    let oneRight = wm.zeroCounts[node.level] + rightOnes
    stack.add (level: node.level + 1, left: oneLeft, right: oneRight,
      value: node.value or (1'u64 shl shift))
    stack.add (level: node.level + 1, left: node.left - leftOnes,
      right: node.right - rightOnes, value: node.value)

iterator collectValueCountsItems*[W: WaveletMatrix | WaveletMatrixView](wm: W): ValueCount =
  ## 列全体の異なる値と頻度を内部探索順で逐次返します。
  for item in wm.collectValueCountsItems(0, wm.n):
    yield item

iterator collectValueCountFinalIntervalsItems*[
    W: WaveletMatrix | WaveletMatrixView](wm: W,
    left, right: int64): ValueCountFinalInterval =
  ## `[left, right)` の異なる値・頻度と、同じWM探索で到達したterminal
  ## intervalを逐次返します。
  ##
  ## `collectValueCountsItems` の後で値ごとに再度WMを辿る必要がある用途向けです。
  ## terminal intervalは最終level後のWavelet permutation上のhalf-open rangeです。
  wm.checkRange(left, right)
  var stack: seq[TraversalNode] =
    @[(level: 0, left: left, right: right, value: 0'u64)]
  while stack.len > 0:
    let node = stack.pop()
    if node.left >= node.right:
      continue
    if node.level == wm.bitWidth:
      yield (value: node.value, frequency: node.right - node.left,
        left: node.left, right: node.right)
      continue

    let shift = wm.bitWidth - node.level - 1
    let leftOnes = wm.levels[node.level].rank1Unchecked(node.left)
    let rightOnes = wm.levels[node.level].rank1Unchecked(node.right)
    let oneLeft = wm.zeroCounts[node.level] + leftOnes
    let oneRight = wm.zeroCounts[node.level] + rightOnes
    stack.add (level: node.level + 1, left: oneLeft, right: oneRight,
      value: node.value or (1'u64 shl shift))
    stack.add (level: node.level + 1, left: node.left - leftOnes,
      right: node.right - rightOnes, value: node.value)

iterator collectValueCountFinalIntervalsItems*[
    W: WaveletMatrix | WaveletMatrixView](wm: W): ValueCountFinalInterval =
  ## 列全体についてterminal interval付きの異なる値と頻度を逐次返します。
  for item in wm.collectValueCountFinalIntervalsItems(0, wm.n):
    yield item

func collectValueCountFinalIntervals*[
    W: WaveletMatrix | WaveletMatrixView](wm: W,
    left, right: int64): seq[ValueCountFinalInterval] =
  ## `[left, right)` のterminal interval付きvalue countsを収集します。
  for item in wm.collectValueCountFinalIntervalsItems(left, right):
    result.add item

func collectValueCountFinalIntervals*[
    W: WaveletMatrix | WaveletMatrixView](wm: W):
    seq[ValueCountFinalInterval] =
  ## 列全体のterminal interval付きvalue countsを収集します。
  wm.collectValueCountFinalIntervals(0, wm.n)

func collectValueCounts*[W: WaveletMatrix | WaveletMatrixView](wm: W,
                         left, right: int64): seq[ValueCount] =
  ## `[left, right)` の異なる値と頻度を走査順で収集します。
  ##
  ## 結果の順序をAPI仕様として保証しません。昇順が必要な場合は
  ## `valueCounts` を使用してください。
  for item in wm.collectValueCountsItems(left, right):
    result.add item

func collectValueCounts*[W: WaveletMatrix | WaveletMatrixView](wm: W): seq[ValueCount] =
  ## 列全体の異なる値と頻度を走査順で収集します。
  wm.collectValueCounts(0, wm.n)

iterator valueCountsItems*[W: WaveletMatrix | WaveletMatrixView](wm: W,
                           left, right: int64): ValueCount =
  ## `[left, right)` の異なる値と頻度を値の昇順で逐次返します。
  ##
  ## MSB-firstで0側を先に探索するため、葉は数値の昇順になります。
  for item in wm.collectValueCountsItems(left, right):
    yield item

iterator valueCountsItems*[W: WaveletMatrix | WaveletMatrixView](wm: W): ValueCount =
  ## 列全体の異なる値と頻度を値の昇順で逐次返します。
  for item in wm.valueCountsItems(0, wm.n):
    yield item

func valueCounts*[W: WaveletMatrix | WaveletMatrixView](wm: W, left, right: int64): seq[ValueCount] =
  ## `[left, right)` の異なる値と頻度を値の昇順で返します。
  for item in wm.valueCountsItems(left, right):
    result.add item

func valueCounts*[W: WaveletMatrix | WaveletMatrixView](wm: W): seq[ValueCount] =
  ## 列全体の異なる値と頻度を値の昇順で返します。
  wm.valueCounts(0, wm.n)

iterator collectDistinctValuesItems*[W: WaveletMatrix | WaveletMatrixView](wm: W,
                                     left, right: int64): uint64 =
  ## `[left, right)` の異なる値を内部探索順で逐次返します。
  ##
  ## 頻度を計算せず、存在するノードだけを直接探索します。
  wm.checkRange(left, right)
  var stack: seq[TraversalNode] =
    @[(level: 0, left: left, right: right, value: 0'u64)]
  while stack.len > 0:
    let node = stack.pop()
    if node.left >= node.right:
      continue
    if node.level == wm.bitWidth:
      yield node.value
      continue

    let shift = wm.bitWidth - node.level - 1
    let leftOnes = wm.levels[node.level].rank1Unchecked(node.left)
    let rightOnes = wm.levels[node.level].rank1Unchecked(node.right)
    let oneLeft = wm.zeroCounts[node.level] + leftOnes
    let oneRight = wm.zeroCounts[node.level] + rightOnes
    stack.add (level: node.level + 1, left: oneLeft, right: oneRight,
      value: node.value or (1'u64 shl shift))
    stack.add (level: node.level + 1, left: node.left - leftOnes,
      right: node.right - rightOnes, value: node.value)

iterator collectDistinctValuesItems*[W: WaveletMatrix | WaveletMatrixView](wm: W): uint64 =
  ## 列全体の異なる値を内部探索順で逐次返します。
  for value in wm.collectDistinctValuesItems(0, wm.n):
    yield value

func collectDistinctValues*[W: WaveletMatrix | WaveletMatrixView](wm: W,
                            left, right: int64): seq[uint64] =
  ## `[left, right)` の異なる値を内部探索順で収集します。
  for value in wm.collectDistinctValuesItems(left, right):
    result.add value

func collectDistinctValues*[W: WaveletMatrix | WaveletMatrixView](wm: W): seq[uint64] =
  ## 列全体の異なる値を内部探索順で収集します。
  wm.collectDistinctValues(0, wm.n)

iterator distinctValuesItems*[W: WaveletMatrix | WaveletMatrixView](wm: W,
                              left, right: int64): uint64 =
  ## `[left, right)` の異なる値を昇順で逐次返します。
  ##
  ## MSB-firstで0側を先に探索するため、追加のソートは不要です。
  for value in wm.collectDistinctValuesItems(left, right):
    yield value

iterator distinctValuesItems*[W: WaveletMatrix | WaveletMatrixView](wm: W): uint64 =
  ## 列全体の異なる値を昇順で逐次返します。
  for value in wm.distinctValuesItems(0, wm.n):
    yield value

func distinctValues*[W: WaveletMatrix | WaveletMatrixView](wm: W,
                     left, right: int64): seq[uint64] =
  ## `[left, right)` の異なる値を昇順で返します。
  for value in wm.distinctValuesItems(left, right):
    result.add value

func distinctValues*[W: WaveletMatrix | WaveletMatrixView](wm: W): seq[uint64] =
  ## 列全体の異なる値を昇順で返します。
  wm.distinctValues(0, wm.n)
