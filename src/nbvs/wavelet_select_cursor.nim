## Wavelet Matrix same-value select cursor.
##
## Repeated `WaveletMatrix.select(value, k)` recomputes the value interval from
## the root for every occurrence.  This module separates that fixed forward
## traversal from the per-occurrence reverse select path.
##
## The cursor is intentionally small and owning-free.  It can be reused with
## `WaveletMatrix` and `WaveletMatrixView` as long as the matrix remains valid.

import wavelet_matrix
import succinct_bit_vector

type
  WaveletSelectCursor* = object
    ## Prepared occurrence interval for one value.
    value*: uint64
    intervalStart*: int64
    count*: int64
    nextOccurrence*: int64
    valid*: bool

func valueFits(bitWidth: int, value: uint64): bool {.inline.} =
  bitWidth == 64 or (bitWidth > 0 and (value shr bitWidth) == 0)

func initWaveletSelectCursor*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, value: uint64): WaveletSelectCursor =
  ## Prepares the final Wavelet interval for `value` once.
  ##
  ## When the value is outside the matrix domain, or the matrix is empty,
  ## `count == 0` and the cursor remains valid for iteration.
  result.value = value
  result.valid = true
  if wm.n == 0 or not valueFits(wm.bitWidth, value):
    return

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

  result.intervalStart = left
  result.count = right - left

func selectPrepared*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, cursor: WaveletSelectCursor, occurrence: int64): int64 =
  ## Selects one 0-based occurrence using a previously prepared value interval.
  ##
  ## Returns `-1` when `occurrence` is outside the prepared interval.  The
  ## cursor must have been prepared for the same matrix/value pair.
  if not cursor.valid or occurrence < 0 or occurrence >= cursor.count:
    return -1

  var pos = cursor.intervalStart + occurrence
  for level in countdown(wm.bitWidth - 1, 0):
    let shift = wm.bitWidth - level - 1
    if ((cursor.value shr shift) and 1'u64) == 0:
      pos = wm.levels[level].select0(pos)
    else:
      pos = wm.levels[level].select1(pos - wm.zeroCounts[level])
  result = pos

proc nextSelect*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, cursor: var WaveletSelectCursor): int64 =
  ## Returns the next occurrence position, or `-1` when exhausted.
  if not cursor.valid or cursor.nextOccurrence >= cursor.count:
    return -1
  result = wm.selectPrepared(cursor, cursor.nextOccurrence)
  inc cursor.nextOccurrence

func remaining*(cursor: WaveletSelectCursor): int64 {.inline.} =
  ## Number of occurrences not yet consumed by `nextSelect`.
  max(0'i64, cursor.count - cursor.nextOccurrence)
