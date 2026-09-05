## Wavelet Matrix の等値条件に一致する物理位置の連続区間を列挙します。
##
## Wavelet Matrix の `matchingRunsItems` は対象値に対応する terminal interval を
## rank で求め、短い probe で run の連続性を推定します。細かく分断される場合は
## sequential select cursor、長い連続区間が見つかる場合は terminal-to-root
## interval lifting を使用します。追加の永続補助構造は使用しません。

import wavelet_matrix
import wavelet_select_cursor
import succinct_bit_vector

type
  MatchingRun* = tuple[left, right: int64]
    ## 条件に一致する要素が連続する、極大な半開物理位置区間 `[left, right)` です。

  ReverseRunNode = tuple[
    level: int,
    left: int64,
    right: int64]

const
  HybridProbeChecks = 96
  HybridLiftSpan = 32'i64

func valueFits(bitWidth: int, value: uint64): bool {.inline.} =
  if bitWidth == 0:
    value == 0
  elif bitWidth == 64:
    true
  else:
    (value shr bitWidth) == 0

func parentInterval[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64, node: ReverseRunNode):
    tuple[left, right: int64, contiguous: bool] {.inline.} =
  let length = node.right - node.left
  let level = node.level
  let shift = wm.bitWidth - level - 1
  let targetOne = ((value shr shift) and 1'u64) != 0

  var parentLeft: int64
  var parentLast: int64
  if targetOne:
    let offset = wm.zeroCounts[level]
    parentLeft = wm.levels[level].select1(node.left - offset)
    if length == 1:
      parentLast = parentLeft
    else:
      parentLast = wm.levels[level].select1(node.right - 1 - offset)
  else:
    parentLeft = wm.levels[level].select0(node.left)
    if length == 1:
      parentLast = parentLeft
    else:
      parentLast = wm.levels[level].select0(node.right - 1)

  result.left = parentLeft
  result.right = parentLast + 1
  result.contiguous = length == 1 or parentLast - parentLeft + 1 == length

func preferSequentialCursor[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64, terminalLeft, terminalRight: int64): bool =
  ## lifting を最大 `HybridProbeChecks` 回だけ試走します。
  ## root まで持ち上げられた区間が `HybridLiftSpan` 以上なら長いrunがあるとみなし
  ## lifting を選択します。probe上限までその規模の区間が見つからなければ、
  ## 細かく分断された入力とみなし sequential cursor を選択します。
  ##
  ## この判定は性能上のheuristicであり、どちらの経路も同じ結果を返します。
  if wm.bitWidth == 0 or terminalRight - terminalLeft <= 1:
    return false

  var stack: seq[ReverseRunNode] = @[(
    level: wm.bitWidth - 1,
    left: terminalLeft,
    right: terminalRight)]
  var checks = 0

  while stack.len > 0 and checks < HybridProbeChecks:
    var node = stack.pop()
    var reachedRoot = true

    while node.level >= 0 and checks < HybridProbeChecks:
      let length = node.right - node.left
      let lifted = wm.parentInterval(value, node)
      inc checks

      if lifted.contiguous:
        node.left = lifted.left
        node.right = lifted.right
        dec node.level
      else:
        let middle = node.left + (length shr 1)
        stack.add (level: node.level, left: middle, right: node.right)
        stack.add (level: node.level, left: node.left, right: middle)
        reachedRoot = false
        break

    if node.level >= 0:
      reachedRoot = false

    if reachedRoot and node.right - node.left >= HybridLiftSpan:
      return false

  # probe内に長い物理区間が現れず、なお未処理候補が残るならcursorを優先する。
  result = stack.len > 0

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
  for run in bits.bitRunsItems(targetOne, 0, bits.lenOfBits):
    yield run

func bitRuns*[B: SuccinctBitVector | SuccinctBitVectorView](
    bits: B, targetOne: bool, left, right: int64): seq[MatchingRun] =
  for run in bits.bitRunsItems(targetOne, left, right):
    result.add run

func bitRuns*[B: SuccinctBitVector | SuccinctBitVectorView](
    bits: B, targetOne: bool): seq[MatchingRun] =
  bits.bitRuns(targetOne, 0, bits.lenOfBits)

iterator matchingRunsItems*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64, left, right: int64): MatchingRun =
  ## `[left, right)` 内で `value` と等しい要素が連続する極大な物理位置区間を
  ## 左から右の順で列挙します。
  ##
  ## まず `[left, right)` を対象値のbitに沿って terminal interval へ写像します。
  ## その後、bounded probeで長い連続区間が早期に見つかるかを調べます。
  ## 細かく分断された入力では #14 の sequential select cursor を使用し、
  ## 長いrunが見つかる入力では terminal-to-root interval lifting を使用します。
  ## 判定は性能heuristicのみで、公開APIの結果・順序には影響しません。
  if left < 0 or left > right or right > wm.n:
    raise newException(IndexDefect, "range out of bounds")

  if left < right and wm.n > 0 and valueFits(wm.bitWidth, value):
    var terminalLeft = left
    var terminalRight = right

    for level in 0..<wm.bitWidth:
      let shift = wm.bitWidth - level - 1
      let targetOne = ((value shr shift) and 1'u64) != 0
      let leftOnes = wm.levels[level].rank1Unchecked(terminalLeft)
      let rightOnes = wm.levels[level].rank1Unchecked(terminalRight)
      if targetOne:
        terminalLeft = wm.zeroCounts[level] + leftOnes
        terminalRight = wm.zeroCounts[level] + rightOnes
      else:
        terminalLeft -= leftOnes
        terminalRight -= rightOnes

    if terminalLeft < terminalRight:
      if wm.preferSequentialCursor(value, terminalLeft, terminalRight):
        var cursor = wm.initWaveletSelectCursor(value)
        cursor.nextOccurrence = terminalLeft - cursor.intervalStart
        let endOccurrence = terminalRight - cursor.intervalStart
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
      else:
        var stack: seq[ReverseRunNode]
        stack.add (
          level: wm.bitWidth - 1,
          left: terminalLeft,
          right: terminalRight)

        var pending = false
        var pendingLeft = 0'i64
        var pendingRight = 0'i64

        while stack.len > 0:
          var node = stack.pop()
          var contiguous = true

          while node.level >= 0:
            let length = node.right - node.left
            let lifted = wm.parentInterval(value, node)

            if lifted.contiguous:
              node.left = lifted.left
              node.right = lifted.right
              dec node.level
            else:
              let middle = node.left + (length shr 1)
              stack.add (level: node.level, left: middle, right: node.right)
              stack.add (level: node.level, left: node.left, right: middle)
              contiguous = false
              break

          if contiguous:
            if pending and pendingRight == node.left:
              pendingRight = node.right
            else:
              if pending:
                yield (left: pendingLeft, right: pendingRight)
              pending = true
              pendingLeft = node.left
              pendingRight = node.right

        if pending:
          yield (left: pendingLeft, right: pendingRight)

iterator matchingRunsItems*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64): MatchingRun =
  for run in wm.matchingRunsItems(value, 0, wm.n):
    yield run

func matchingRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64, left, right: int64): seq[MatchingRun] =
  for run in wm.matchingRunsItems(value, left, right):
    result.add run

func matchingRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64): seq[MatchingRun] =
  wm.matchingRuns(value, 0, wm.n)

func collectMatchingRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64, left, right: int64): seq[MatchingRun] =
  wm.matchingRuns(value, left, right)

func collectMatchingRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64): seq[MatchingRun] =
  wm.matchingRuns(value)
