## LSB-first wavelet matrix for unsigned 64-bit integer sequences.
##
## Unlike `WaveletMatrix`, levels are constructed from the least significant
## bit to the most significant bit. The structure supports access, rank,
## select, and distinct-value frequency enumeration.

import std/[algorithm, bitops]
import succinct_bit_vector
import wavelet_matrix

export ValueCount

type
  ReversedWaveletMatrix* = object
    ## Immutable LSB-first wavelet matrix.
    n*: int64
    bitWidth*: int
    levels*: seq[SuccinctBitVector] ## Bit vectors, from least to most significant.
    zeroCounts*: seq[int64]

func valueBitWidth(x: uint64): int {.inline.} =
  if x == 0: 1 else: 64 - countLeadingZeroBits(x)

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

func genReversedWaveletMatrix*(xs: openArray[uint64]): ReversedWaveletMatrix =
  ## Constructs an LSB-first wavelet matrix.
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
    let (bits, zeros) = buildLevelBits(current, level)
    result.levels[level] = bits
    result.zeroCounts[level] = int64(zeros)

    var zeroPos = 0
    var onePos = zeros
    for x in current:
      if ((x shr level) and 1'u64) == 0:
        next[zeroPos] = x
        inc zeroPos
      else:
        next[onePos] = x
        inc onePos
    swap(current, next)

func checkIndex(rwm: ReversedWaveletMatrix, i: int64) {.inline.} =
  if i < 0 or i >= rwm.n:
    raise newException(IndexDefect, "index out of bounds")

func checkPosition(rwm: ReversedWaveletMatrix, pos: int64) {.inline.} =
  if pos < 0 or pos > rwm.n:
    raise newException(IndexDefect, "position out of bounds")

func checkRange(rwm: ReversedWaveletMatrix, left, right: int64) {.inline.} =
  if left < 0 or left > right or right > rwm.n:
    raise newException(IndexDefect, "range out of bounds")

func valueFits(rwm: ReversedWaveletMatrix, value: uint64): bool {.inline.} =
  rwm.bitWidth == 64 or
    (rwm.bitWidth > 0 and (value shr rwm.bitWidth) == 0)

func bitAtUnchecked(bits: SuccinctBitVector, pos: int64): bool {.inline.} =
  ((bits.data[int(pos shr 6)] shr int(pos and 63)) and 1'u64) != 0

func access*(rwm: ReversedWaveletMatrix, i: int64): uint64 =
  ## Returns the value at index `i`.
  rwm.checkIndex(i)
  var pos = i
  for level in 0..<rwm.bitWidth:
    let ones = rwm.levels[level].rank1Unchecked(pos)
    if rwm.levels[level].bitAtUnchecked(pos):
      result = result or (1'u64 shl level)
      pos = rwm.zeroCounts[level] + ones
    else:
      pos -= ones

func `[]`*(rwm: ReversedWaveletMatrix, i: int64): uint64 =
  ## Alias for `access(rwm, i)`.
  rwm.access(i)

func rank*(rwm: ReversedWaveletMatrix, value: uint64, pos: int64): int64 =
  ## Counts occurrences of `value` in `[0, pos)`.
  rwm.checkPosition(pos)
  if rwm.n == 0 or not rwm.valueFits(value):
    return 0
  var left = 0'i64
  var right = pos
  for level in 0..<rwm.bitWidth:
    if ((value shr level) and 1'u64) == 0:
      left -= rwm.levels[level].rank1Unchecked(left)
      right -= rwm.levels[level].rank1Unchecked(right)
    else:
      left = rwm.zeroCounts[level] + rwm.levels[level].rank1Unchecked(left)
      right = rwm.zeroCounts[level] + rwm.levels[level].rank1Unchecked(right)
  result = right - left

func occPosition*(rwm: ReversedWaveletMatrix, value: uint64,
                  pos: int64): int64 =
  ## 安定な全体昇順列で、`[0, pos)` に由来する `value` の終端位置を返します。
  ##
  ## 単純な出現回数ではなく、列全体にある `value` 未満の要素数と、
  ## 半開区間 `[0, pos)` にある `value` の出現回数の和です。
  ## FM-indexにおける `C[value] + Occ(value, pos)` に相当します。
  rwm.checkPosition(pos)
  if rwm.n == 0:
    return 0
  if not rwm.valueFits(value):
    return rwm.n

  # LSBからの安定分割を完了すると数値昇順になるため、右境界の
  # 最終写像位置が直接 `C[value] + Occ(value, pos)` になる。
  var right = pos
  for level in 0..<rwm.bitWidth:
    let ones = rwm.levels[level].rank1Unchecked(right)
    if ((value shr level) and 1'u64) == 0:
      right -= ones
    else:
      right = rwm.zeroCounts[level] + ones
  result = right

func rank*(rwm: ReversedWaveletMatrix, value: uint64,
           left, right: int64): int64 =
  ## Counts occurrences of `value` in `[left, right)`.
  rwm.checkRange(left, right)
  if left == right or rwm.n == 0 or not rwm.valueFits(value):
    return 0

  var lo = left
  var hi = right
  for level in 0..<rwm.bitWidth:
    if ((value shr level) and 1'u64) == 0:
      lo -= rwm.levels[level].rank1Unchecked(lo)
      hi -= rwm.levels[level].rank1Unchecked(hi)
    else:
      lo = rwm.zeroCounts[level] + rwm.levels[level].rank1Unchecked(lo)
      hi = rwm.zeroCounts[level] + rwm.levels[level].rank1Unchecked(hi)
  result = hi - lo

func rankIncl*(rwm: ReversedWaveletMatrix, value: uint64,
               pos: int64): int64 =
  ## Counts occurrences of `value` in `[0, pos]`.
  rwm.checkIndex(pos)
  result = rwm.rank(value, pos + 1)

func select*(rwm: ReversedWaveletMatrix, value: uint64, k: int64): int64 =
  ## Returns the position of the 0-based `k`-th occurrence, or `-1`.
  if k < 0 or rwm.n == 0 or not rwm.valueFits(value):
    return -1
  var left = 0'i64
  var right = rwm.n
  for level in 0..<rwm.bitWidth:
    if ((value shr level) and 1'u64) == 0:
      left -= rwm.levels[level].rank1Unchecked(left)
      right -= rwm.levels[level].rank1Unchecked(right)
    else:
      left = rwm.zeroCounts[level] + rwm.levels[level].rank1Unchecked(left)
      right = rwm.zeroCounts[level] + rwm.levels[level].rank1Unchecked(right)
  if k >= right - left:
    return -1

  var pos = left + k
  for level in countdown(rwm.bitWidth - 1, 0):
    if ((value shr level) and 1'u64) == 0:
      pos = rwm.levels[level].select0(pos)
    else:
      pos = rwm.levels[level].select1(pos - rwm.zeroCounts[level])
  result = pos

func selectNth*(rwm: ReversedWaveletMatrix, value: uint64,
                nth: int64): int64 =
  ## Returns the position of the 1-based `nth` occurrence, or `-1`.
  if nth <= 0:
    return -1
  result = rwm.select(value, nth - 1)

func remainingMask(bitWidth, level: int): uint64 {.inline.} =
  ## Bits in `[level, bitWidth)`; lower levels are already fixed.
  let lowMask =
    if level == 0: 0'u64
    elif level >= 64: uint64.high
    else: (1'u64 shl level) - 1'u64
  let fullMask =
    if bitWidth == 64: uint64.high
    else: (1'u64 shl bitWidth) - 1'u64
  fullMask and not lowMask

func countLessThanNode(rwm: ReversedWaveletMatrix, level: int,
                       left, right: int64, partial, value: uint64): int64 =
  if left >= right:
    return 0

  # All values below this node lie between partial and partial|remainingMask.
  # These bounds let the LSB-first traversal accept or reject whole subtrees.
  if partial >= value:
    return 0
  if (partial or remainingMask(rwm.bitWidth, level)) < value:
    return right - left
  if level == rwm.bitWidth:
    return right - left

  let leftOnes = rwm.levels[level].rank1Unchecked(left)
  let rightOnes = rwm.levels[level].rank1Unchecked(right)
  let zeroLeft = left - leftOnes
  let zeroRight = right - rightOnes
  result = rwm.countLessThanNode(level + 1, zeroLeft, zeroRight,
    partial, value)

  let oneLeft = rwm.zeroCounts[level] + leftOnes
  let oneRight = rwm.zeroCounts[level] + rightOnes
  result += rwm.countLessThanNode(level + 1, oneLeft, oneRight,
    partial or (1'u64 shl level), value)

func rankLessThan*(rwm: ReversedWaveletMatrix, value: uint64,
                   pos: int64): int64 =
  ## Counts values smaller than `value` in `[0, pos)`.
  ##
  ## LSB-first levels cannot represent this numeric-order prefix as one path.
  ## The implementation traverses occupied subtrees and prunes them by their
  ## possible value bounds; its cost depends on the value distribution.
  rwm.checkPosition(pos)
  if pos == 0 or rwm.n == 0 or value == 0:
    return 0
  if not rwm.valueFits(value):
    return pos
  result = rwm.countLessThanNode(0, 0, pos, 0, value)

func collectValueCounts(rwm: ReversedWaveletMatrix, level: int,
                        left, right: int64, value: uint64,
                        result: var seq[ValueCount]) =
  if left >= right:
    return
  if level == rwm.bitWidth:
    result.add (value: value, frequency: right - left)
    return
  let leftOnes = rwm.levels[level].rank1Unchecked(left)
  let rightOnes = rwm.levels[level].rank1Unchecked(right)
  let zeroLeft = left - leftOnes
  let zeroRight = right - rightOnes
  rwm.collectValueCounts(level + 1, zeroLeft, zeroRight, value, result)
  let oneLeft = rwm.zeroCounts[level] + leftOnes
  let oneRight = rwm.zeroCounts[level] + rightOnes
  rwm.collectValueCounts(level + 1, oneLeft, oneRight,
    value or (1'u64 shl level), result)

func valueCounts*(rwm: ReversedWaveletMatrix,
                  left, right: int64): seq[ValueCount] =
  ## Returns distinct values and frequencies in `[left, right)`, sorted by value.
  rwm.checkRange(left, right)
  rwm.collectValueCounts(0, left, right, 0, result)
  result.sort(proc(a, b: ValueCount): int = cmp(a.value, b.value))

func valueCounts*(rwm: ReversedWaveletMatrix): seq[ValueCount] =
  ## Returns distinct values and frequencies for the complete sequence.
  rwm.valueCounts(0, rwm.n)

iterator items*(rwm: ReversedWaveletMatrix): uint64 =
  ## Iterates over values in original order.
  for i in 0'i64..<rwm.n:
    yield rwm.access(i)

func toSeq*(rwm: ReversedWaveletMatrix): seq[uint64] =
  ## Decodes the matrix to a sequence in original order.
  result = newSeq[uint64](int(rwm.n))
  for i in 0'i64..<rwm.n:
    result[int(i)] = rwm.access(i)
