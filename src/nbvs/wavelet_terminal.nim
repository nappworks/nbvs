## Terminal-coordinate helpers for `WaveletMatrix` and `WaveletMatrixView`.
##
## These APIs expose the position or interval reached after traversing all
## Wavelet Matrix levels. Positions are 0-based and intervals are half-open.

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
  ## Returns the position reached after traversing all Wavelet Matrix levels.
  ##
  ## The caller must guarantee `0 <= position < wm.n`.
  result = position
  for level in 0..<wm.bitWidth:
    let ones = wm.levels[level].rank1Unchecked(result)
    if wm.levels[level].bitAtUncheckedTerminal(result):
      result = wm.zeroCounts[level] + ones
    else:
      result -= ones

func terminalPosition*[W: WaveletMatrix | WaveletMatrixView](wm: W,
    position: int64): int64 =
  ## Checked version of `terminalPositionUnchecked`.
  if position < 0 or position >= wm.n:
    raise newException(IndexDefect, "index out of bounds")
  wm.terminalPositionUnchecked(position)

func accessWithTerminalPositionUnchecked*[
    W: WaveletMatrix | WaveletMatrixView](wm: W,
    position: int64): tuple[value: uint64, terminalPosition: int64] =
  ## Returns the value at `position` and its terminal Wavelet position in one
  ## forward traversal.
  ##
  ## The caller must guarantee `0 <= position < wm.n`.
  result.terminalPosition = position
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let ones = wm.levels[level].rank1Unchecked(result.terminalPosition)
    if wm.levels[level].bitAtUncheckedTerminal(result.terminalPosition):
      result.value = result.value or (1'u64 shl shift)
      result.terminalPosition = wm.zeroCounts[level] + ones
    else:
      result.terminalPosition -= ones

func accessWithTerminalPosition*[
    W: WaveletMatrix | WaveletMatrixView](wm: W,
    position: int64): tuple[value: uint64, terminalPosition: int64] =
  ## Checked version of `accessWithTerminalPositionUnchecked`.
  if position < 0 or position >= wm.n:
    raise newException(IndexDefect, "index out of bounds")
  wm.accessWithTerminalPositionUnchecked(position)

func terminalInterval*[W: WaveletMatrix | WaveletMatrixView](wm: W,
    value: uint64): tuple[left, right: int64] =
  ## Returns the half-open interval occupied by `value` after traversing all
  ## Wavelet Matrix levels. An absent value yields an empty interval.
  if wm.n == 0 or not wm.valueFitsTerminal(value):
    return

  result.left = 0
  result.right = wm.n
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let leftOnes = wm.levels[level].rank1Unchecked(result.left)
    let rightOnes = wm.levels[level].rank1Unchecked(result.right)
    if ((value shr shift) and 1'u64) == 0:
      result.left -= leftOnes
      result.right -= rightOnes
    else:
      result.left = wm.zeroCounts[level] + leftOnes
      result.right = wm.zeroCounts[level] + rightOnes
