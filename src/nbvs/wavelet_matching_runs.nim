## Wavelet Matrix の等値条件に一致する物理位置の連続区間を列挙します。
##
## Wavelet Matrix の `matchingRunsItems` は `WaveletSelectCursor` を使って一致位置を
## 昇順に復元し、隣接する位置を極大な物理runへまとめます。

import wavelet_matrix
import wavelet_select_cursor
import succinct_bit_vector

type
  MatchingRun* = tuple[left, right: int64]
    ## 条件に一致する要素が連続する、極大な半開物理位置区間 `[left, right)` です。

iterator bitRunsItems*[B: SuccinctBitVector | SuccinctBitVectorView](
    bits: B, targetOne: bool, left, right: int64): MatchingRun =
  ## `[left, right)` のうち、全ビットが `targetOne` と一致する極大な部分区間を
  ## 左から右の順で列挙します。rank により区間全体の不一致・一致を判定し、
  ## 混在区間だけを再帰的に分割します。
  if left < 0 or left > right or right > bits.lenOfBits:
    raise newException(IndexDefect, "range out of bounds")
  if left < right:
    var stack: seq[MatchingRun] = @[(left: left, right: right)]
    var pending = false
    var pendingLeft = 0'i64
    var pendingRight = 0'i64

    while stack.len > 0:
      let node = stack.pop()
      let ones = bits.rank1Unchecked(node.right) - bits.rank1Unchecked(node.left)
      let length = node.right - node.left
      let matching = if targetOne: ones else: length - ones

      if matching == 0:
        continue

      if matching == length:
        if pending and pendingRight == node.left:
          pendingRight = node.right
        else:
          if pending:
            yield (left: pendingLeft, right: pendingRight)
          pending = true
          pendingLeft = node.left
          pendingRight = node.right
        continue

      let middle = node.left + (length shr 1)
      stack.add (left: middle, right: node.right)
      stack.add (left: node.left, right: middle)

    if pending:
      yield (left: pendingLeft, right: pendingRight)

iterator bitRunsItems*[B: SuccinctBitVector | SuccinctBitVectorView](
    bits: B, targetOne: bool): MatchingRun =
  ## BitVector 全体から `targetOne` と一致する極大な連続区間を列挙します。
  for run in bits.bitRunsItems(targetOne, 0, bits.lenOfBits):
    yield run

func bitRuns*[B: SuccinctBitVector | SuccinctBitVectorView](
    bits: B, targetOne: bool, left, right: int64): seq[MatchingRun] =
  ## `bitRunsItems(targetOne, left, right)` の結果を sequence として返します。
  for run in bits.bitRunsItems(targetOne, left, right):
    result.add run

func bitRuns*[B: SuccinctBitVector | SuccinctBitVectorView](
    bits: B, targetOne: bool): seq[MatchingRun] =
  ## BitVector 全体の `bitRunsItems(targetOne)` の結果を sequence として返します。
  bits.bitRuns(targetOne, 0, bits.lenOfBits)

iterator matchingRunsItems*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64, left, right: int64): MatchingRun =
  ## `[left, right)` 内で `value` と等しい要素が連続する極大な物理位置区間を
  ## 左から右の順で列挙します。
  ##
  ## #14 の sequential select cursor を使い、一致する occurrence だけを昇順に
  ## 復元します。範囲指定時は `rank` で `[left, right)` に対応する occurrence
  ## 範囲を先に求めるため、範囲外の occurrence は列挙しません。
  if left < 0 or left > right or right > wm.n:
    raise newException(IndexDefect, "range out of bounds")

  if left < right and wm.n > 0:
    var cursor = wm.initWaveletSelectCursor(value)
    if cursor.count > 0:
      let firstOccurrence = wm.rank(value, 0, left)
      let endOccurrence = wm.rank(value, 0, right)
      cursor.nextOccurrence = firstOccurrence

      var hasRun = false
      var runLeft = 0'i64
      var previous = -2'i64

      while cursor.nextOccurrence < endOccurrence:
        let position = wm.nextSelectUnchecked(cursor)
        if not hasRun:
          hasRun = true
          runLeft = position
        elif position != previous + 1:
          yield (left: runLeft, right: previous + 1)
          runLeft = position
        previous = position

      if hasRun:
        yield (left: runLeft, right: previous + 1)

iterator matchingRunsItems*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64): MatchingRun =
  ## Wavelet Matrix 全体から `value` と等しい要素の極大な連続物理位置区間を
  ## 列挙します。
  for run in wm.matchingRunsItems(value, 0, wm.n):
    yield run

func matchingRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64, left, right: int64): seq[MatchingRun] =
  ## `matchingRunsItems(value, left, right)` の結果を sequence として返します。
  for run in wm.matchingRunsItems(value, left, right):
    result.add run

func matchingRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64): seq[MatchingRun] =
  ## Wavelet Matrix 全体の `matchingRunsItems(value)` の結果を sequence として
  ## 返します。
  wm.matchingRuns(value, 0, wm.n)

func collectMatchingRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64, left, right: int64): seq[MatchingRun] =
  ## `matchingRuns(value, left, right)` の互換用別名です。
  wm.matchingRuns(value, left, right)

func collectMatchingRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64): seq[MatchingRun] =
  ## `matchingRuns(value)` の互換用別名です。
  wm.matchingRuns(value)
