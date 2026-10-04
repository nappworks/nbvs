## Wavelet Matrix の等値条件に一致する物理位置の連続区間を列挙します。
##
## Wavelet Matrix の `matchingRunsItems` は対象値に対応する terminal interval を
## rank で求め、短い probe で run の連続性を推定します。細かく分断される場合は
## sequential select cursor、長い連続区間が見つかる場合は terminal-to-root
## interval lifting を使用します。追加の永続補助構造は使用しません。

import wavelet_matrix
import wavelet_position_match
import wavelet_select_cursor
import succinct_bit_vector

type
  MatchingRun* = tuple[left, right: int64]
    ## 条件に一致する要素が連続する、極大な半開物理位置区間 `[left, right)` です。

  ReverseRunNode = tuple[
    level: int,
    left: int64,
    right: int64]

  RangeRunNode = tuple[
    level: int,
    physicalLeft: int64,
    physicalRight: int64,
    mappedLeft: int64,
    mappedRight: int64,
    prefix: uint64]

const
  HybridProbeChecks = 96
  HybridLiftSpan = 32'i64
  BitRunTraversalStackCapacity = 66
  RangeRunTraversalStackCapacity = 66
  RangeRunAdaptiveProbeWindows = 8
  RangeRunAdaptiveWindowSize = 64'i64
  RangeRunAdaptiveMinSpan = 2048'i64
  RangeRunAdaptiveTransitionLimit = 6

func valueFits(bitWidth: int, value: uint64): bool {.inline.} =
  if bitWidth == 0:
    value == 0
  elif bitWidth == 64:
    true
  else:
    (value shr bitWidth) == 0

func terminalRangeForValue[
    W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64, left, right: int64):
    tuple[left, right: int64] =
  result.left = left
  result.right = right
  if wm.bitWidth == 0:
    return

  template runTerminalRange(rankFn: untyped) =
    block:
      for level in 0..<wm.bitWidth:
        let shift = wm.bitWidth - level - 1
        let targetOne = ((value shr shift) and 1'u64) != 0
        let leftOnes = rankFn(wm.levels[level], result.left)
        let rightOnes = rankFn(wm.levels[level], result.right)
        if targetOne:
          result.left = wm.zeroCounts[level] + leftOnes
          result.right = wm.zeroCounts[level] + rightOnes
        else:
          result.left -= leftOnes
          result.right -= rightOnes

  case int(wm.levels[0].level)
  of 0: runTerminalRange(rank1UncheckedDepth0)
  of 1: runTerminalRange(rank1UncheckedDepth1)
  of 2: runTerminalRange(rank1UncheckedDepth2)
  of 3: runTerminalRange(rank1UncheckedDepth3)
  of 4: runTerminalRange(rank1UncheckedDepth4)
  of 5: runTerminalRange(rank1UncheckedDepth5)
  of 6: runTerminalRange(rank1UncheckedDepth6)
  of 7: runTerminalRange(rank1UncheckedDepth7)
  else: runTerminalRange(rank1UncheckedDepth8)

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
    template runBitRuns(rankFn: untyped) =
      block:
        var stack: array[BitRunTraversalStackCapacity, MatchingRun]
        var stackLen = 1
        stack[0] = (left: left, right: right)
        var pending = false
        var pendingLeft = 0'i64
        var pendingRight = 0'i64

        while stackLen > 0:
          dec stackLen
          let node = stack[stackLen]
          let ones = rankFn(bits, node.right) - rankFn(bits, node.left)
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
          stack[stackLen] = (left: middle, right: node.right)
          inc stackLen
          stack[stackLen] = (left: node.left, right: middle)
          inc stackLen

        if pending:
          yield (left: pendingLeft, right: pendingRight)

    case int(bits.level)
    of 0: runBitRuns(rank1UncheckedDepth0)
    of 1: runBitRuns(rank1UncheckedDepth1)
    of 2: runBitRuns(rank1UncheckedDepth2)
    of 3: runBitRuns(rank1UncheckedDepth3)
    of 4: runBitRuns(rank1UncheckedDepth4)
    of 5: runBitRuns(rank1UncheckedDepth5)
    of 6: runBitRuns(rank1UncheckedDepth6)
    of 7: runBitRuns(rank1UncheckedDepth7)
    else: runBitRuns(rank1UncheckedDepth8)

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
  ## まず `[left, right)` を対象値のbitに沿って terminal interval へ写像します。
  ## その後、bounded probeで長い連続区間が早期に見つかるかを調べます。
  ## 細かく分断された入力では sequential select cursor を使用し、
  ## 長いrunが見つかる入力では terminal-to-root interval lifting を使用します。
  ## 判定は性能heuristicのみで、公開APIの結果・順序には影響しません。
  ## bit幅をB、一致数をMとするとrankはO(B)回、selectは最悪O(B * M)回です。
  ## 各rank/selectの実行コストは別途掛かります。補助空間は
  ## O(B + log(M + 1))で、sequence版は返却run数に比例する領域も必要です。
  if left < 0 or left > right or right > wm.n:
    raise newException(IndexDefect, "range out of bounds")

  if left < right and wm.n > 0 and valueFits(wm.bitWidth, value):
    let terminalRange = wm.terminalRangeForValue(value, left, right)
    let terminalLeft = terminalRange.left
    let terminalRight = terminalRange.right

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


func waveletDomainHigh(bitWidth: int): uint64 {.inline.} =
  if bitWidth <= 0:
    0'u64
  elif bitWidth >= 64:
    uint64.high
  else:
    (1'u64 shl bitWidth) - 1'u64

func rangeLowBitsMask(bitCount: int): uint64 {.inline.} =
  if bitCount <= 0:
    0'u64
  elif bitCount >= 64:
    uint64.high
  else:
    (1'u64 shl bitCount) - 1'u64

func preferRangeNativeAdaptive[
    W: WaveletMatrix | WaveletMatrixView](
    wm: W, low, high: uint64, left, right: int64): bool =
  ## Stage Bのbounded fragmentation probeです。
  ##
  ## physical range全体は走査せず、最大8個の64-row windowだけを均等配置して
  ## range predicateのmatch/non-match遷移数を数えます。局所遷移が多い場合は
  ## Stage Aで大幅regressionした高fragmentation workloadとみなしposition scanを
  ## 選択します。遷移が少ない場合だけrange-native traversalを選択します。
  ##
  ## 短いrangeではprobe overheadを回避するためposition scanを優先します。
  let span = right - left
  if span < RangeRunAdaptiveMinSpan:
    return false

  let windowSize = min(span, RangeRunAdaptiveWindowSize)
  let maxStartOffset = span - windowSize
  var transitions = 0

  for windowIndex in 0..<RangeRunAdaptiveProbeWindows:
    let startOffset =
      if RangeRunAdaptiveProbeWindows <= 1:
        0'i64
      else:
        let denominator = int64(RangeRunAdaptiveProbeWindows - 1)
        let index = int64(windowIndex)
        (maxStartOffset div denominator) * index +
          ((maxStartOffset mod denominator) * index) div denominator
    let windowLeft = left + startOffset
    let windowRight = windowLeft + windowSize

    var previous =
      wm.valueInRangeAtUnchecked(windowLeft, low, high)
    var position = windowLeft + 1
    while position < windowRight:
      let current = wm.valueInRangeAtUnchecked(position, low, high)
      if current != previous:
        inc transitions
        if transitions > RangeRunAdaptiveTransitionLimit:
          return false
      previous = current
      inc position

  true

iterator matchingRangeRunsPositionScanItems[
    W: WaveletMatrix | WaveletMatrixView](
    wm: W, low, high: uint64, left, right: int64): MatchingRun =
  ## PR #22のgeneral-range routeです。
  ## physical positionごとにprefix-pruned predicateを評価し、極大runへ結合します。
  var pending = false
  var pendingLeft = 0'i64
  for position in left..<right:
    if wm.valueInRangeAtUnchecked(position, low, high):
      if not pending:
        pending = true
        pendingLeft = position
    elif pending:
      yield (left: pendingLeft, right: position)
      pending = false

  if pending:
    yield (left: pendingLeft, right: right)

iterator matchingRangeRunsNativeItems[
    W: WaveletMatrix | WaveletMatrixView](
    wm: W, low, high: uint64, left, right: int64): MatchingRun =
  ## 一般range向けのMSB-first native traversalです。
  ##
  ## 各nodeは、同じvalue prefixを共有する元physical連続区間と、
  ## その要素を現在levelへstable projectionしたmapped区間を同時に保持します。
  ## prefixのvalue intervalがqueryに完全包含されればphysical区間をそのまま採用し、
  ## 非交差なら破棄します。部分交差時だけcurrent bitをrankで分類し、
  ## bitが混在する区間だけphysical orderを保ったまま二分します。
  ##
  ## 追加metadataやrow materializationは使用しません。
  if left < right:
    if wm.bitWidth == 0:
      if low == 0:
        yield (left: left, right: right)
    else:
      template runRangeNative(rankFn: untyped) =
        block:
          var stack: array[RangeRunTraversalStackCapacity, RangeRunNode]
          var stackLen = 1
          stack[0] = (
            level: 0,
            physicalLeft: left,
            physicalRight: right,
            mappedLeft: left,
            mappedRight: right,
            prefix: 0'u64)

          var pending = false
          var pendingLeft = 0'i64
          var pendingRight = 0'i64

          while stackLen > 0:
            dec stackLen
            var node = stack[stackLen]
            var finished = false

            while not finished:
              let remainingBits = wm.bitWidth - node.level
              let possibleLow = node.prefix
              let possibleHigh =
                node.prefix or rangeLowBitsMask(remainingBits)

              if possibleHigh < low or possibleLow > high:
                finished = true
              elif low <= possibleLow and possibleHigh <= high:
                if pending and pendingRight == node.physicalLeft:
                  pendingRight = node.physicalRight
                else:
                  if pending:
                    yield (left: pendingLeft, right: pendingRight)
                  pending = true
                  pendingLeft = node.physicalLeft
                  pendingRight = node.physicalRight
                finished = true
              else:
                let length = node.physicalRight - node.physicalLeft
                let bits = wm.levels[node.level]
                let mappedLeftOnes = rankFn(bits, node.mappedLeft)
                let mappedRightOnes = rankFn(bits, node.mappedRight)
                let ones = mappedRightOnes - mappedLeftOnes
                let shift = wm.bitWidth - node.level - 1

                if ones == 0:
                  node.mappedLeft -= mappedLeftOnes
                  node.mappedRight -= mappedRightOnes
                  inc node.level
                elif ones == length:
                  node.prefix =
                    node.prefix or (1'u64 shl shift)
                  node.mappedLeft =
                    wm.zeroCounts[node.level] + mappedLeftOnes
                  node.mappedRight =
                    wm.zeroCounts[node.level] + mappedRightOnes
                  inc node.level
                else:
                  let leftLength = length shr 1
                  let physicalMiddle =
                    node.physicalLeft + leftLength
                  let mappedMiddle =
                    node.mappedLeft + leftLength

                  stack[stackLen] = (
                    level: node.level,
                    physicalLeft: physicalMiddle,
                    physicalRight: node.physicalRight,
                    mappedLeft: mappedMiddle,
                    mappedRight: node.mappedRight,
                    prefix: node.prefix)
                  inc stackLen

                  node.physicalRight = physicalMiddle
                  node.mappedRight = mappedMiddle

          if pending:
            yield (left: pendingLeft, right: pendingRight)

      case int(wm.levels[0].level)
      of 0: runRangeNative(rank1UncheckedDepth0)
      of 1: runRangeNative(rank1UncheckedDepth1)
      of 2: runRangeNative(rank1UncheckedDepth2)
      of 3: runRangeNative(rank1UncheckedDepth3)
      of 4: runRangeNative(rank1UncheckedDepth4)
      of 5: runRangeNative(rank1UncheckedDepth5)
      of 6: runRangeNative(rank1UncheckedDepth6)
      of 7: runRangeNative(rank1UncheckedDepth7)
      else: runRangeNative(rank1UncheckedDepth8)

iterator matchingRangeRunsItems*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, low, high: uint64, left, right: int64): MatchingRun =
  ## 値のinclusive range `[low, high]` と、元入力のindex範囲
  ## `[left, right)` を受け取ります。
  ## 戻り値の `MatchingRun(left, right)` は、元入力上で
  ## `low <= value <= high` を満たす要素が連続する極大な半開index区間です。
  ## runは元入力のindex昇順で列挙します。
  ##
  ## ここでphysical positionはWavelet Matrix内部の並べ替え後位置ではなく、
  ## 元の入力配列におけるindexを意味します。
  ##
  ## 全value domainを含むrangeは入力physical rangeをそのまま返し、
  ## `low == high` は既存の等値run列挙へ委譲します。一般rangeはbounded
  ## fragmentation probeでstrategyを選択し、低fragmentationならMSB-first
  ## range-native traversal、高fragmentationならPR #22のposition scanを使います。
  if left < 0 or left > right or right > wm.n:
    raise newException(IndexDefect, "range out of bounds")

  if left < right and wm.n > 0 and low <= high:
    let domainHigh = waveletDomainHigh(wm.bitWidth)
    if low <= domainHigh:
      if low == 0 and high >= domainHigh:
        yield (left: left, right: right)
      elif low == high:
        for run in wm.matchingRunsItems(low, left, right):
          yield run
      else:
        if wm.preferRangeNativeAdaptive(low, high, left, right):
          for run in wm.matchingRangeRunsNativeItems(low, high, left, right):
            yield run
        else:
          for run in wm.matchingRangeRunsPositionScanItems(
              low, high, left, right):
            yield run

when defined(nbvsRangeRunBenchmark):
  func rangeRunAdaptiveUsesNativeBenchmark*[
      W: WaveletMatrix | WaveletMatrixView](
      wm: W, low, high: uint64, left, right: int64): bool =
    ## benchmark専用のstrategy観測hookです。通常buildでは公開されません。
    wm.preferRangeNativeAdaptive(low, high, left, right)

iterator matchingRangeRunsItems*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, low, high: uint64): MatchingRun =
  ## 値のinclusive range `[low, high]` を受け取り、元入力全体から条件に一致する
  ## 極大な `MatchingRun(left, right)` をindex昇順で列挙します。
  for run in wm.matchingRangeRunsItems(low, high, 0, wm.n):
    yield run

func matchingRangeRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, low, high: uint64, left, right: int64): seq[MatchingRun] =
  ## 値範囲 `[low, high]` と元入力index範囲 `[left, right)` を受け取り、
  ## 一致する極大な元入力index区間を `seq[MatchingRun]` で返します。
  for run in wm.matchingRangeRunsItems(low, high, left, right):
    result.add run

func matchingRangeRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, low, high: uint64): seq[MatchingRun] =
  ## 値範囲 `[low, high]` を受け取り、元入力全体の一致runを
  ## `seq[MatchingRun]` で返します。
  wm.matchingRangeRuns(low, high, 0, wm.n)

func collectMatchingRangeRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, low, high: uint64, left, right: int64): seq[MatchingRun] =
  ## `matchingRangeRuns(low, high, left, right)` の互換用別名です。
  wm.matchingRangeRuns(low, high, left, right)

func collectMatchingRangeRuns*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, low, high: uint64): seq[MatchingRun] =
  ## `matchingRangeRuns(low, high)` の互換用別名です。
  wm.matchingRangeRuns(low, high)
