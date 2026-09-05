## Wavelet Matrix の等値条件に一致する物理位置の連続区間を列挙します。
##
## Wavelet Matrix の `matchingRunsItems` は対象値に対応する terminal interval を
## rank で求め、各 level の select を逆向きに使って元の物理位置へ持ち上げます。
## 両端の select だけで親 level 上でも連続と判定できる区間はまとめて処理し、
## 非連続な区間だけを分割します。追加の永続補助構造は使用しません。

import wavelet_matrix
import succinct_bit_vector

type
  MatchingRun* = tuple[left, right: int64]
    ## 条件に一致する要素が連続する、極大な半開物理位置区間 `[left, right)` です。

  ReverseRunNode = tuple[
    level: int,
    left: int64,
    right: int64]

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
  ## まず `[left, right)` を対象値のbitに沿って terminal interval へ写像します。
  ## その interval を最下位levelから逆向きに持ち上げ、両端selectで得られる親区間
  ## の長さが要素数と一致すれば、その区間は親level上でも連続なので一括で進みます。
  ## 非連続な場合だけ current interval を二分して同じlevelを再評価します。
  ##
  ## したがって全 occurrence を個別selectせず、runが長いデータでは少数の区間を
  ## まとめて元の物理位置へ復元できます。永続的なrun境界indexは追加しません。
  ##
  ## bit幅を B、一致数を M とすると、rank呼び出しは O(B)、select呼び出しは
  ## 最悪 O(B * M) です。実行時間には各rank/selectのコストが掛かります。
  ## 二分時だけstackが増えるため、補助空間は O(1 + log(M + 1)) です。
  ## 短いrunでは区間分割と両端selectの負担により逐次selectより遅くなり得ます。
  if left < 0 or left > right or right > wm.n:
    raise newException(IndexDefect, "range out of bounds")

  if left < right and wm.n > 0 and valueFits(wm.bitWidth, value):
    var terminalLeft = left
    var terminalRight = right

    # 対象値に一致する `[left, right)` 内の要素だけを terminal 座標へ写像する。
    # levelをletへ取り出すと所有型のseqが複製されるため、rank/selectは直接参照する。
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

          if length == 1 or parentLast - parentLeft + 1 == length:
            node.left = parentLeft
            node.right = parentLast + 1
            dec node.level
          else:
            # LIFO のため右半分を先に積み、terminal occurrence 順を維持する。
            let middle = node.left + (length shr 1)
            stack.add (level: level, left: middle, right: node.right)
            stack.add (level: level, left: node.left, right: middle)
            contiguous = false
            break

        if contiguous:
          # level 0 を越えた時点で `[left,right)` は元配列上の物理区間。
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
