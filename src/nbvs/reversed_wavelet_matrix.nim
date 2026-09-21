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
  TraversalNode = tuple[level: int, left, right: int64, value: uint64]

const ReversedWaveletTraversalStackCapacity = 66

  ReversedWaveletMatrix* = object
    ## Immutable LSB-first wavelet matrix.
    n*: int64
    bitWidth*: int
    levels*: seq[SuccinctBitVector] ## Bit vectors, from least to most significant.
    zeroCounts*: seq[int64]

  ReversedWaveletMatrixView* = object
    ## 下位の `SuccinctBitVectorView` 群を参照する非所有LSB-first Viewです。
    n*: int64
    bitWidth*: int
    levels*: ExternalSpan[SuccinctBitVectorView]
    zeroCounts*: ExternalSpan[int64]

func initReversedWaveletMatrixView*(n: int64, bitWidth: int,
    levels: ptr UncheckedArray[SuccinctBitVectorView], levelCount: int,
    zeroCounts: pointer, zeroCountsBytes: int): ReversedWaveletMatrixView =
  ## 呼び出し側所有のlevel descriptor列とzero-count列からViewを作成します。
  if n < 0 or bitWidth < 0 or bitWidth > 64:
    raise newException(ValueError, "invalid Reversed Wavelet Matrix metadata")
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

func checkIndex[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W, i: int64) {.inline.} =
  if i < 0 or i >= rwm.n:
    raise newException(IndexDefect, "index out of bounds")

func checkPosition[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W, pos: int64) {.inline.} =
  if pos < 0 or pos > rwm.n:
    raise newException(IndexDefect, "position out of bounds")

func checkRange[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W, left, right: int64) {.inline.} =
  if left < 0 or left > right or right > rwm.n:
    raise newException(IndexDefect, "range out of bounds")

func valueFits[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W, value: uint64): bool {.inline.} =
  rwm.bitWidth == 64 or
    (rwm.bitWidth > 0 and (value shr rwm.bitWidth) == 0)

func bitAtUnchecked[B: SuccinctBitVector | SuccinctBitVectorView](
    bits: B, pos: int64): bool {.inline.} =
  ((bits.data[int(pos shr 6)] shr int(pos and 63)) and 1'u64) != 0

func access*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W, i: int64): uint64 =
  ## Returns the value at index `i`.
  rwm.checkIndex(i)

  template runAccess(rankFn: untyped) =
    block:
      var pos = i
      for level in 0..<rwm.bitWidth:
        let ones = rankFn(rwm.levels[level], pos)
        if rwm.levels[level].bitAtUnchecked(pos):
          result = result or (1'u64 shl level)
          pos = rwm.zeroCounts[level] + ones
        else:
          pos -= ones

  case int(rwm.levels[0].level)
  of 0: runAccess(rank1UncheckedDepth0)
  of 1: runAccess(rank1UncheckedDepth1)
  of 2: runAccess(rank1UncheckedDepth2)
  of 3: runAccess(rank1UncheckedDepth3)
  of 4: runAccess(rank1UncheckedDepth4)
  of 5: runAccess(rank1UncheckedDepth5)
  of 6: runAccess(rank1UncheckedDepth6)
  of 7: runAccess(rank1UncheckedDepth7)
  else: runAccess(rank1UncheckedDepth8)

func `[]`*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W, i: int64): uint64 =
  ## Alias for `access(rwm, i)`.
  rwm.access(i)

func rank*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W, value: uint64, pos: int64): int64 =
  ## Counts occurrences of `value` in `[0, pos)`.
  rwm.checkPosition(pos)
  if rwm.n == 0 or not rwm.valueFits(value):
    return 0

  template runRank(rankFn: untyped) =
    block:
      var left = 0'i64
      var right = pos
      for level in 0..<rwm.bitWidth:
        if ((value shr level) and 1'u64) == 0:
          left -= rankFn(rwm.levels[level], left)
          right -= rankFn(rwm.levels[level], right)
        else:
          left = rwm.zeroCounts[level] + rankFn(rwm.levels[level], left)
          right = rwm.zeroCounts[level] + rankFn(rwm.levels[level], right)
      result = right - left

  case int(rwm.levels[0].level)
  of 0: runRank(rank1UncheckedDepth0)
  of 1: runRank(rank1UncheckedDepth1)
  of 2: runRank(rank1UncheckedDepth2)
  of 3: runRank(rank1UncheckedDepth3)
  of 4: runRank(rank1UncheckedDepth4)
  of 5: runRank(rank1UncheckedDepth5)
  of 6: runRank(rank1UncheckedDepth6)
  of 7: runRank(rank1UncheckedDepth7)
  else: runRank(rank1UncheckedDepth8)

func occPosition*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W, value: uint64,
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
  template runOccPosition(rankFn: untyped) =
    block:
      var right = pos
      for level in 0..<rwm.bitWidth:
        let ones = rankFn(rwm.levels[level], right)
        if ((value shr level) and 1'u64) == 0:
          right -= ones
        else:
          right = rwm.zeroCounts[level] + ones
      result = right

  case int(rwm.levels[0].level)
  of 0: runOccPosition(rank1UncheckedDepth0)
  of 1: runOccPosition(rank1UncheckedDepth1)
  of 2: runOccPosition(rank1UncheckedDepth2)
  of 3: runOccPosition(rank1UncheckedDepth3)
  of 4: runOccPosition(rank1UncheckedDepth4)
  of 5: runOccPosition(rank1UncheckedDepth5)
  of 6: runOccPosition(rank1UncheckedDepth6)
  of 7: runOccPosition(rank1UncheckedDepth7)
  else: runOccPosition(rank1UncheckedDepth8)

func rank*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W, value: uint64,
           left, right: int64): int64 =
  ## Counts occurrences of `value` in `[left, right)`.
  rwm.checkRange(left, right)
  if left == right or rwm.n == 0 or not rwm.valueFits(value):
    return 0

  template runRankRange(rankFn: untyped) =
    block:
      var lo = left
      var hi = right
      for level in 0..<rwm.bitWidth:
        if ((value shr level) and 1'u64) == 0:
          lo -= rankFn(rwm.levels[level], lo)
          hi -= rankFn(rwm.levels[level], hi)
        else:
          lo = rwm.zeroCounts[level] + rankFn(rwm.levels[level], lo)
          hi = rwm.zeroCounts[level] + rankFn(rwm.levels[level], hi)
      result = hi - lo

  case int(rwm.levels[0].level)
  of 0: runRankRange(rank1UncheckedDepth0)
  of 1: runRankRange(rank1UncheckedDepth1)
  of 2: runRankRange(rank1UncheckedDepth2)
  of 3: runRankRange(rank1UncheckedDepth3)
  of 4: runRankRange(rank1UncheckedDepth4)
  of 5: runRankRange(rank1UncheckedDepth5)
  of 6: runRankRange(rank1UncheckedDepth6)
  of 7: runRankRange(rank1UncheckedDepth7)
  else: runRankRange(rank1UncheckedDepth8)

func rankIncl*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W, value: uint64,
               pos: int64): int64 =
  ## Counts occurrences of `value` in `[0, pos]`.
  rwm.checkIndex(pos)
  result = rwm.rank(value, pos + 1)

func select*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W, value: uint64, k: int64): int64 =
  ## Returns the position of the 0-based `k`-th occurrence, or `-1`.
  if k < 0 or rwm.n == 0 or not rwm.valueFits(value):
    return -1

  template runSelectForward(rankFn: untyped) =
    block:
      var left = 0'i64
      var right = rwm.n
      for level in 0..<rwm.bitWidth:
        if ((value shr level) and 1'u64) == 0:
          left -= rankFn(rwm.levels[level], left)
          right -= rankFn(rwm.levels[level], right)
        else:
          left = rwm.zeroCounts[level] + rankFn(rwm.levels[level], left)
          right = rwm.zeroCounts[level] + rankFn(rwm.levels[level], right)
      if k >= right - left:
        return -1

      var pos = left + k
      for level in countdown(rwm.bitWidth - 1, 0):
        if ((value shr level) and 1'u64) == 0:
          pos = rwm.levels[level].select0(pos)
        else:
          pos = rwm.levels[level].select1(pos - rwm.zeroCounts[level])
      result = pos

  case int(rwm.levels[0].level)
  of 0: runSelectForward(rank1UncheckedDepth0)
  of 1: runSelectForward(rank1UncheckedDepth1)
  of 2: runSelectForward(rank1UncheckedDepth2)
  of 3: runSelectForward(rank1UncheckedDepth3)
  of 4: runSelectForward(rank1UncheckedDepth4)
  of 5: runSelectForward(rank1UncheckedDepth5)
  of 6: runSelectForward(rank1UncheckedDepth6)
  of 7: runSelectForward(rank1UncheckedDepth7)
  else: runSelectForward(rank1UncheckedDepth8)

func selectNth*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W, value: uint64,
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

func countLessThanNodeFixed[Depth: static[int],
    W: ReversedWaveletMatrix | ReversedWaveletMatrixView](
    rwm: W, level: int, left, right: int64,
    partial, value: uint64): int64 =
  if left >= right:
    return 0

  if partial >= value:
    return 0
  if (partial or remainingMask(rwm.bitWidth, level)) < value:
    return right - left
  if level == rwm.bitWidth:
    return right - left

  template rankAt(bits, position: untyped): untyped =
    when Depth == 0: rank1UncheckedDepth0(bits, position)
    elif Depth == 1: rank1UncheckedDepth1(bits, position)
    elif Depth == 2: rank1UncheckedDepth2(bits, position)
    elif Depth == 3: rank1UncheckedDepth3(bits, position)
    elif Depth == 4: rank1UncheckedDepth4(bits, position)
    elif Depth == 5: rank1UncheckedDepth5(bits, position)
    elif Depth == 6: rank1UncheckedDepth6(bits, position)
    elif Depth == 7: rank1UncheckedDepth7(bits, position)
    else: rank1UncheckedDepth8(bits, position)

  let leftOnes = rankAt(rwm.levels[level], left)
  let rightOnes = rankAt(rwm.levels[level], right)
  let zeroLeft = left - leftOnes
  let zeroRight = right - rightOnes
  result = countLessThanNodeFixed[Depth](
    rwm, level + 1, zeroLeft, zeroRight, partial, value)

  let oneLeft = rwm.zeroCounts[level] + leftOnes
  let oneRight = rwm.zeroCounts[level] + rightOnes
  result += countLessThanNodeFixed[Depth](
    rwm, level + 1, oneLeft, oneRight,
    partial or (1'u64 shl level), value)

func rankLessThan*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W, value: uint64,
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
  case int(rwm.levels[0].level)
  of 0: result = countLessThanNodeFixed[0](rwm, 0, 0, pos, 0, value)
  of 1: result = countLessThanNodeFixed[1](rwm, 0, 0, pos, 0, value)
  of 2: result = countLessThanNodeFixed[2](rwm, 0, 0, pos, 0, value)
  of 3: result = countLessThanNodeFixed[3](rwm, 0, 0, pos, 0, value)
  of 4: result = countLessThanNodeFixed[4](rwm, 0, 0, pos, 0, value)
  of 5: result = countLessThanNodeFixed[5](rwm, 0, 0, pos, 0, value)
  of 6: result = countLessThanNodeFixed[6](rwm, 0, 0, pos, 0, value)
  of 7: result = countLessThanNodeFixed[7](rwm, 0, 0, pos, 0, value)
  else: result = countLessThanNodeFixed[8](rwm, 0, 0, pos, 0, value)

iterator collectValueCountsItems*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W,
                                  left, right: int64): ValueCount =
  ## `[left, right)` の異なる値と頻度を内部探索順で逐次返します。
  ##
  ## 頻度は葉の区間長から求め、追加の走査は行いません。
  rwm.checkRange(left, right)
  if left < right:
    template runTraversal(rankFn: untyped) =
      block:
        var stack: array[ReversedWaveletTraversalStackCapacity, TraversalNode]
        var stackLen = 1
        stack[0] = (level: 0, left: left, right: right, value: 0'u64)
        while stackLen > 0:
          dec stackLen
          let node = stack[stackLen]
          if node.left >= node.right:
            continue
          if node.level == rwm.bitWidth:
            yield (value: node.value, frequency: node.right - node.left)
            continue

          let leftOnes = rankFn(rwm.levels[node.level], node.left)
          let rightOnes = rankFn(rwm.levels[node.level], node.right)
          let oneLeft = rwm.zeroCounts[node.level] + leftOnes
          let oneRight = rwm.zeroCounts[node.level] + rightOnes
          if oneLeft < oneRight:
            stack[stackLen] = (
              level: node.level + 1, left: oneLeft, right: oneRight,
              value: node.value or (1'u64 shl node.level))
            inc stackLen
          let zeroLeft = node.left - leftOnes
          let zeroRight = node.right - rightOnes
          if zeroLeft < zeroRight:
            stack[stackLen] = (
              level: node.level + 1, left: zeroLeft, right: zeroRight,
              value: node.value)
            inc stackLen

    case int(rwm.levels[0].level)
    of 0: runTraversal(rank1UncheckedDepth0)
    of 1: runTraversal(rank1UncheckedDepth1)
    of 2: runTraversal(rank1UncheckedDepth2)
    of 3: runTraversal(rank1UncheckedDepth3)
    of 4: runTraversal(rank1UncheckedDepth4)
    of 5: runTraversal(rank1UncheckedDepth5)
    of 6: runTraversal(rank1UncheckedDepth6)
    of 7: runTraversal(rank1UncheckedDepth7)
    else: runTraversal(rank1UncheckedDepth8)

iterator collectValueCountsItems*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W): ValueCount =
  ## 列全体の異なる値と頻度を内部探索順で逐次返します。
  for item in rwm.collectValueCountsItems(0, rwm.n):
    yield item

func collectValueCounts*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W,
                         left, right: int64): seq[ValueCount] =
  ## `[left, right)` の異なる値と頻度を走査順で収集します。
  ##
  ## 結果の順序をAPI仕様として保証しません。昇順が必要な場合は
  ## `valueCounts` を使用してください。
  for item in rwm.collectValueCountsItems(left, right):
    result.add item

func collectValueCounts*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W): seq[ValueCount] =
  ## 列全体の異なる値と頻度を走査順で収集します。
  rwm.collectValueCounts(0, rwm.n)

iterator valueCountsItems*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W,
                           left, right: int64): ValueCount =
  ## `[left, right)` の異なる値と頻度を値の昇順で逐次返します。
  ##
  ## LSB-firstの探索順は数値順ではないため、全結果を保持してソートします。
  var values = rwm.collectValueCounts(left, right)
  values.sort(proc(a, b: ValueCount): int = cmp(a.value, b.value))
  for item in values:
    yield item

iterator valueCountsItems*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W): ValueCount =
  ## 列全体の異なる値と頻度を値の昇順で逐次返します。
  for item in rwm.valueCountsItems(0, rwm.n):
    yield item

func valueCounts*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W,
                  left, right: int64): seq[ValueCount] =
  ## `[left, right)` の異なる値と頻度を値の昇順で返します。
  for item in rwm.valueCountsItems(left, right):
    result.add item

func valueCounts*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W): seq[ValueCount] =
  ## 列全体の異なる値と頻度を値の昇順で返します。
  rwm.valueCounts(0, rwm.n)

iterator collectDistinctValuesItems*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W,
                                     left, right: int64): uint64 =
  ## `[left, right)` の異なる値を内部探索順で逐次返します。
  ##
  ## 頻度を計算せず、存在するノードだけを直接探索します。
  rwm.checkRange(left, right)
  if left < right:
    template runTraversal(rankFn: untyped) =
      block:
        var stack: array[ReversedWaveletTraversalStackCapacity, TraversalNode]
        var stackLen = 1
        stack[0] = (level: 0, left: left, right: right, value: 0'u64)
        while stackLen > 0:
          dec stackLen
          let node = stack[stackLen]
          if node.left >= node.right:
            continue
          if node.level == rwm.bitWidth:
            yield node.value
            continue

          let leftOnes = rankFn(rwm.levels[node.level], node.left)
          let rightOnes = rankFn(rwm.levels[node.level], node.right)
          let oneLeft = rwm.zeroCounts[node.level] + leftOnes
          let oneRight = rwm.zeroCounts[node.level] + rightOnes
          if oneLeft < oneRight:
            stack[stackLen] = (
              level: node.level + 1, left: oneLeft, right: oneRight,
              value: node.value or (1'u64 shl node.level))
            inc stackLen
          let zeroLeft = node.left - leftOnes
          let zeroRight = node.right - rightOnes
          if zeroLeft < zeroRight:
            stack[stackLen] = (
              level: node.level + 1, left: zeroLeft, right: zeroRight,
              value: node.value)
            inc stackLen

    case int(rwm.levels[0].level)
    of 0: runTraversal(rank1UncheckedDepth0)
    of 1: runTraversal(rank1UncheckedDepth1)
    of 2: runTraversal(rank1UncheckedDepth2)
    of 3: runTraversal(rank1UncheckedDepth3)
    of 4: runTraversal(rank1UncheckedDepth4)
    of 5: runTraversal(rank1UncheckedDepth5)
    of 6: runTraversal(rank1UncheckedDepth6)
    of 7: runTraversal(rank1UncheckedDepth7)
    else: runTraversal(rank1UncheckedDepth8)

iterator collectDistinctValuesItems*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W): uint64 =
  ## 列全体の異なる値を内部探索順で逐次返します。
  for value in rwm.collectDistinctValuesItems(0, rwm.n):
    yield value

func collectDistinctValues*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W,
                            left, right: int64): seq[uint64] =
  ## `[left, right)` の異なる値を内部探索順で収集します。
  for value in rwm.collectDistinctValuesItems(left, right):
    result.add value

func collectDistinctValues*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W): seq[uint64] =
  ## 列全体の異なる値を内部探索順で収集します。
  rwm.collectDistinctValues(0, rwm.n)

iterator distinctValuesItems*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W,
                              left, right: int64): uint64 =
  ## `[left, right)` の異なる値を昇順で逐次返します。
  ##
  ## LSB-firstの探索順は数値順ではないため、全結果を保持してソートします。
  var values = rwm.collectDistinctValues(left, right)
  values.sort()
  for value in values:
    yield value

iterator distinctValuesItems*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W): uint64 =
  ## 列全体の異なる値を昇順で逐次返します。
  for value in rwm.distinctValuesItems(0, rwm.n):
    yield value

func distinctValues*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W,
                     left, right: int64): seq[uint64] =
  ## `[left, right)` の異なる値を昇順で返します。
  for value in rwm.distinctValuesItems(left, right):
    result.add value

func distinctValues*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W): seq[uint64] =
  ## 列全体の異なる値を昇順で返します。
  rwm.distinctValues(0, rwm.n)

iterator items*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W): uint64 =
  ## Iterates over values in original order.
  for i in 0'i64..<rwm.n:
    yield rwm.access(i)

func toSeq*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](rwm: W): seq[uint64] =
  ## Decodes the matrix to a sequence in original order.
  result = newSeq[uint64](int(rwm.n))
  for i in 0'i64..<rwm.n:
    result[int(i)] = rwm.access(i)
