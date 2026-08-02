## Wavelet matrix for unsigned 64-bit integer sequences.
##
## Positions are 0-based and all ranges use half-open `[left, right)`
## semantics. The structure is immutable after construction.

import std/[algorithm, bitops]
import succinct_bit_vector

type
  ValueCount* = tuple[value: uint64, frequency: int64]
    ## A distinct value and its number of occurrences.

  WaveletMatrix* = object
    ## Rank/select-capable representation of a `uint64` sequence.
    n*: int64 ## Number of values.
    bitWidth*: int ## Number of significant bit levels (0 for an empty input).
    levels*: seq[SuccinctBitVector] ## Bit vectors, from most to least significant.
    zeroCounts*: seq[int64] ## Number of zero bits at each level.

func valueBitWidth(x: uint64): int {.inline.} =
  if x == 0:
    1
  else:
    64 - countLeadingZeroBits(x)

func buildLevelBits(values: openArray[uint64],
                    shift: int): tuple[bits: SuccinctBitVector, zeros: int] =
  result.bits = genSuccinctBitVector(int64(values.len))
  let wordCount = (values.len + 63) shr 6
  for wordIndex in 0..<wordCount:
    let start = wordIndex shl 6
    let bitCount = min(64, values.len - start)
    var word = 0'u64
    for bitIndex in 0..<bitCount:
      word = word or
        (((values[start + bitIndex] shr shift) and 1'u64) shl bitIndex)
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

func checkIndex(wm: WaveletMatrix, i: int64) {.inline.} =
  if i < 0 or i >= wm.n:
    raise newException(IndexDefect, "index out of bounds")

func checkPosition(wm: WaveletMatrix, pos: int64) {.inline.} =
  if pos < 0 or pos > wm.n:
    raise newException(IndexDefect, "position out of bounds")

func checkRange(wm: WaveletMatrix, left, right: int64) {.inline.} =
  if left < 0 or left > right or right > wm.n:
    raise newException(IndexDefect, "range out of bounds")

func valueFits(wm: WaveletMatrix, value: uint64): bool {.inline.} =
  wm.bitWidth == 64 or (wm.bitWidth > 0 and (value shr wm.bitWidth) == 0)

func bitAtUnchecked(bits: SuccinctBitVector, pos: int64): bool {.inline.} =
  ((bits.data[int(pos shr 6)] shr int(pos and 63)) and 1'u64) != 0

func access*(wm: WaveletMatrix, i: int64): uint64 =
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

func `[]`*(wm: WaveletMatrix, i: int64): uint64 =
  ## Alias for `access(wm, i)`.
  wm.access(i)

func rank*(wm: WaveletMatrix, value: uint64, pos: int64): int64 =
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

func rank*(wm: WaveletMatrix, value: uint64, left, right: int64): int64 =
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

func rankIncl*(wm: WaveletMatrix, value: uint64, pos: int64): int64 =
  ## Counts occurrences of `value` in `[0, pos]`.
  wm.checkIndex(pos)
  result = wm.rank(value, pos + 1)

func select*(wm: WaveletMatrix, value: uint64, k: int64): int64 =
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

func selectNth*(wm: WaveletMatrix, value: uint64, nth: int64): int64 =
  ## Returns the position of the 1-based `nth` occurrence, or `-1`.
  if nth <= 0:
    return -1
  result = wm.select(value, nth - 1)

func countLessThan*(wm: WaveletMatrix, left, right: int64,
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

func rankLessThan*(wm: WaveletMatrix, value: uint64, pos: int64): int64 =
  ## Counts values smaller than `value` in `[0, pos)`.
  ##
  ## Runs in `O(bitWidth)` time.
  result = wm.countLessThan(0, pos, value)

func occPosition*(wm: WaveletMatrix, value: uint64, pos: int64): int64 =
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

func rangeFreq*(wm: WaveletMatrix, left, right: int64,
                lower, upper: uint64): int64 =
  ## Counts values in `[lower, upper)` within positions `[left, right)`.
  wm.checkRange(left, right)
  if lower >= upper:
    return 0
  result = wm.countLessThan(left, right, upper) -
    wm.countLessThan(left, right, lower)

func quantile*(wm: WaveletMatrix, left, right, k: int64): uint64 =
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

func predecessor*(wm: WaveletMatrix, left, right: int64,
                  upper: uint64): uint64 =
  ## Returns the greatest value `< upper` in `[left, right)`.
  ## Raises `ValueError` when no such value exists.
  let count = wm.countLessThan(left, right, upper)
  if count == 0:
    raise newException(ValueError, "predecessor does not exist")
  result = wm.quantile(left, right, count - 1)

func successor*(wm: WaveletMatrix, left, right: int64,
                lower: uint64): uint64 =
  ## Returns the smallest value `>= lower` in `[left, right)`.
  ## Raises `ValueError` when no such value exists.
  let count = wm.countLessThan(left, right, lower)
  if count >= right - left:
    raise newException(ValueError, "successor does not exist")
  result = wm.quantile(left, right, count)

iterator items*(wm: WaveletMatrix): uint64 =
  ## Iterates over values in original order.
  for i in 0'i64..<wm.n:
    yield wm.access(i)

func toSeq*(wm: WaveletMatrix): seq[uint64] =
  ## Decodes the matrix to a sequence in original order.
  result = newSeq[uint64](int(wm.n))
  for i in 0'i64..<wm.n:
    result[int(i)] = wm.access(i)

func collectValueCountsNode(wm: WaveletMatrix, level: int, left, right: int64,
                            value: uint64, result: var seq[ValueCount]) =
  if left >= right:
    return
  if level == wm.bitWidth:
    result.add (value: value, frequency: right - left)
    return

  let shift = wm.bitWidth - level - 1
  let leftOnes = wm.levels[level].rank1Unchecked(left)
  let rightOnes = wm.levels[level].rank1Unchecked(right)
  let zeroLeft = left - leftOnes
  let zeroRight = right - rightOnes
  wm.collectValueCountsNode(level + 1, zeroLeft, zeroRight, value, result)

  let oneLeft = wm.zeroCounts[level] + leftOnes
  let oneRight = wm.zeroCounts[level] + rightOnes
  wm.collectValueCountsNode(level + 1, oneLeft, oneRight,
    value or (1'u64 shl shift), result)

func collectValueCounts*(wm: WaveletMatrix,
                         left, right: int64): seq[ValueCount] =
  ## `[left, right)` の異なる値と頻度を走査順で収集します。
  ##
  ## 結果の順序をAPI仕様として保証しません。昇順が必要な場合は
  ## `valueCounts` を使用してください。
  wm.checkRange(left, right)
  wm.collectValueCountsNode(0, left, right, 0, result)

func collectValueCounts*(wm: WaveletMatrix): seq[ValueCount] =
  ## 列全体の異なる値と頻度を走査順で収集します。
  wm.collectValueCounts(0, wm.n)

func valueCounts*(wm: WaveletMatrix, left, right: int64): seq[ValueCount] =
  ## `[left, right)` の異なる値と頻度を値の昇順で返します。
  result = wm.collectValueCounts(left, right)
  result.sort(proc(a, b: ValueCount): int = cmp(a.value, b.value))

func valueCounts*(wm: WaveletMatrix): seq[ValueCount] =
  ## 列全体の異なる値と頻度を値の昇順で返します。
  wm.valueCounts(0, wm.n)
