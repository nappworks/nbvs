## `WaveletMatrix` / `WaveletMatrixView` のterminal coordinate操作です。
##
## Wavelet Matrixの全levelを通過した後に到達するpositionまたはintervalを
## 公開します。positionは0-based、intervalはhalf-openです。

import wavelet_matrix
import succinct_bit_vector

func valueFitsTerminal[W: WaveletMatrix | WaveletMatrixView](wm: W,
    value: uint64): bool {.inline.} =
  if wm.bitWidth == 0:
    value == 0
  elif wm.bitWidth == 64:
    true
  else:
    (value shr wm.bitWidth) == 0

func bitAtUncheckedTerminal[B: SuccinctBitVector | SuccinctBitVectorView](
    bits: B, pos: int64): bool {.inline.} =
  ((bits.data[int(pos shr 6)] shr int(pos and 63)) and 1'u64) != 0

func terminalPositionUnchecked*[W: WaveletMatrix | WaveletMatrixView](wm: W,
    position: int64): int64 =
  ## Wavelet Matrixの全levelを通過した後に到達するpositionを返します。
  ##
  ## 呼び出し側は `0 <= position < wm.n` を保証する必要があります。
  result = position
  if wm.bitWidth == 0:
    return

  template runTerminal(rankFn: untyped) =
    block:
      for level in 0..<wm.bitWidth:
        let ones = rankFn(wm.levels[level], result)
        if wm.levels[level].bitAtUncheckedTerminal(result):
          result = wm.zeroCounts[level] + ones
        else:
          result -= ones

  case int(wm.levels[0].level)
  of 0: runTerminal(rank1UncheckedDepth0)
  of 1: runTerminal(rank1UncheckedDepth1)
  of 2: runTerminal(rank1UncheckedDepth2)
  of 3: runTerminal(rank1UncheckedDepth3)
  of 4: runTerminal(rank1UncheckedDepth4)
  of 5: runTerminal(rank1UncheckedDepth5)
  of 6: runTerminal(rank1UncheckedDepth6)
  of 7: runTerminal(rank1UncheckedDepth7)
  else: runTerminal(rank1UncheckedDepth8)

func terminalPosition*[W: WaveletMatrix | WaveletMatrixView](wm: W,
    position: int64): int64 =
  ## `terminalPositionUnchecked` の境界検証付きAPIです。
  if position < 0 or position >= wm.n:
    raise newException(IndexDefect, "index out of bounds")
  wm.terminalPositionUnchecked(position)

func accessWithTerminalPositionUnchecked*[
    W: WaveletMatrix | WaveletMatrixView](wm: W,
    position: int64): tuple[value: uint64, terminalPosition: int64] =
  ## `position` のvalueとterminal positionを1回のforward traversalで返します。
  ##
  ## 呼び出し側は `0 <= position < wm.n` を保証する必要があります。
  result.terminalPosition = position
  if wm.bitWidth == 0:
    return

  template runAccessTerminal(rankFn: untyped) =
    block:
      for level in 0..<wm.bitWidth:
        let shift = wm.bitWidth - level - 1
        let ones = rankFn(wm.levels[level], result.terminalPosition)
        if wm.levels[level].bitAtUncheckedTerminal(result.terminalPosition):
          result.value = result.value or (1'u64 shl shift)
          result.terminalPosition = wm.zeroCounts[level] + ones
        else:
          result.terminalPosition -= ones

  case int(wm.levels[0].level)
  of 0: runAccessTerminal(rank1UncheckedDepth0)
  of 1: runAccessTerminal(rank1UncheckedDepth1)
  of 2: runAccessTerminal(rank1UncheckedDepth2)
  of 3: runAccessTerminal(rank1UncheckedDepth3)
  of 4: runAccessTerminal(rank1UncheckedDepth4)
  of 5: runAccessTerminal(rank1UncheckedDepth5)
  of 6: runAccessTerminal(rank1UncheckedDepth6)
  of 7: runAccessTerminal(rank1UncheckedDepth7)
  else: runAccessTerminal(rank1UncheckedDepth8)

func accessWithTerminalPosition*[
    W: WaveletMatrix | WaveletMatrixView](wm: W,
    position: int64): tuple[value: uint64, terminalPosition: int64] =
  ## `accessWithTerminalPositionUnchecked` の境界検証付きAPIです。
  if position < 0 or position >= wm.n:
    raise newException(IndexDefect, "index out of bounds")
  wm.accessWithTerminalPositionUnchecked(position)

func terminalInterval*[W: WaveletMatrix | WaveletMatrixView](wm: W,
    value: uint64): tuple[left, right: int64] =
  ## `value` が全level通過後のWavelet permutation上で占めるhalf-open
  ## intervalを返します。存在しないvalueでは空intervalを返します。
  if wm.n == 0 or not wm.valueFitsTerminal(value):
    return

  result.left = 0
  result.right = wm.n
  if wm.bitWidth == 0:
    return

  template runTerminalInterval(rankFn: untyped) =
    block:
      for level in 0..<wm.bitWidth:
        let shift = wm.bitWidth - level - 1
        let leftOnes = rankFn(wm.levels[level], result.left)
        let rightOnes = rankFn(wm.levels[level], result.right)
        if ((value shr shift) and 1'u64) == 0:
          result.left -= leftOnes
          result.right -= rightOnes
        else:
          result.left = wm.zeroCounts[level] + leftOnes
          result.right = wm.zeroCounts[level] + rightOnes

  case int(wm.levels[0].level)
  of 0: runTerminalInterval(rank1UncheckedDepth0)
  of 1: runTerminalInterval(rank1UncheckedDepth1)
  of 2: runTerminalInterval(rank1UncheckedDepth2)
  of 3: runTerminalInterval(rank1UncheckedDepth3)
  of 4: runTerminalInterval(rank1UncheckedDepth4)
  of 5: runTerminalInterval(rank1UncheckedDepth5)
  of 6: runTerminalInterval(rank1UncheckedDepth6)
  of 7: runTerminalInterval(rank1UncheckedDepth7)
  else: runTerminalInterval(rank1UncheckedDepth8)
