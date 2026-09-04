## Wavelet Matrix の等値条件に一致する物理位置の連続区間を列挙します。
##
## `matchingRunsItems` は、既知の検索値を最上位ビット側の Wavelet level から
## 下位へ向かって辿ります。各 level では rank を使い、対象ビットを含まない
## 区間を除外し、全ビットが一致する区間は位置を個別列挙せずそのまま採用します。
## ビットが混在する区間だけを分割し、採用した区間は等値 rank と同じ変換で
## 次の Wavelet level 上の区間へ写像します。

import wavelet_matrix
import succinct_bit_vector

type
  MatchingRun* = tuple[left, right: int64]
    ## 条件に一致する要素が連続する、極大な半開物理位置区間 `[left, right)` です。

  MatchingRunCandidate = tuple[
    physicalLeft: int64,
    currentLeft: int64,
    currentRight: int64]

func valueFits(bitWidth: int, value: uint64): bool {.inline.} =
  if bitWidth == 0:
    value == 0
  elif bitWidth == 64:
    true
  else:
    (value shr bitWidth) == 0

iterator bitRunsItems*[B: SuccinctBitVector | SuccinctBitVectorView](
    bits: B, targetOne: bool, left, right: int64): MatchingRun =
  ## `[left, right)` のうち、全ビットが `targetOne` と一致する極大な部分区間を
  ## 左から右の順で列挙します。rank により区間全体の不一致・一致を判定し、
  ## 混在区間だけを再帰的に分割します。
  if left < 0 or left > right or right > bits.lenOfBits:
    raise newException(IndexDefect, "range out of bounds")
  if left == right:
    return

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
    # LIFO のため右側を先に積み、一致区間を左から右の順で処理します。
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
  ## Wavelet の `select` は使用しません。既知の検索値のビットに従い、rank で
  ## 区間全体の一致判定と次 level への写像を行いながら、上位 level から
  ## 候補区間を絞り込みます。
  if left < 0 or left > right or right > wm.n:
    raise newException(IndexDefect, "range out of bounds")
  if left == right or wm.n == 0 or not valueFits(wm.bitWidth, value):
    return

  if wm.bitWidth == 0:
    yield (left: left, right: right)
    return

  var candidates: seq[MatchingRunCandidate] = @[
    (physicalLeft: left, currentLeft: left, currentRight: right)]

  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let targetOne = ((value shr shift) and 1'u64) != 0
    var next: seq[MatchingRunCandidate]

    for candidate in candidates:
      for run in wm.levels[level].bitRunsItems(targetOne,
          candidate.currentLeft, candidate.currentRight):
        let physicalLeft = candidate.physicalLeft +
          (run.left - candidate.currentLeft)
        let leftOnes = wm.levels[level].rank1Unchecked(run.left)
        let rightOnes = wm.levels[level].rank1Unchecked(run.right)

        var mappedLeft, mappedRight: int64
        if targetOne:
          mappedLeft = wm.zeroCounts[level] + leftOnes
          mappedRight = wm.zeroCounts[level] + rightOnes
        else:
          mappedLeft = run.left - leftOnes
          mappedRight = run.right - rightOnes

        next.add (
          physicalLeft: physicalLeft,
          currentLeft: mappedLeft,
          currentRight: mappedRight)

    candidates = move(next)
    if candidates.len == 0:
      return

  for candidate in candidates:
    yield (
      left: candidate.physicalLeft,
      right: candidate.physicalLeft +
        (candidate.currentRight - candidate.currentLeft))

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
