## Wavelet Matrix向けの早期終了付きposition predicateです。
##
## `matchesAt` tests whether the value stored at a physical position equals the
## requested value without reconstructing the full value first. Traversal stops
## at the first mismatching bit. It is available for both the MSB-first
## WaveletMatrix and the LSB-first ReversedWaveletMatrix.
##
## `valueInRangeAt` is intentionally provided only for the MSB-first
## WaveletMatrix. Because each visited prefix represents one contiguous numeric
## interval, the traversal can reject or accept a position before reconstructing
## the full value. The LSB-first ReversedWaveletMatrix does not have the same
## contiguous-prefix property and therefore does not expose this API.

import wavelet_matrix
import reversed_wavelet_matrix
import succinct_bit_vector

func bitAtUnchecked[B: SuccinctBitVector | SuccinctBitVectorView](
    bits: B, pos: int64): bool {.inline.} =
  ((bits.data[int(pos shr 6)] shr int(pos and 63)) and 1'u64) != 0

func valueFits(bitWidth: int, value: uint64): bool {.inline.} =
  bitWidth == 64 or (bitWidth > 0 and (value shr bitWidth) == 0)

func lowBitsMask(bitCount: int): uint64 {.inline.} =
  if bitCount <= 0:
    0'u64
  elif bitCount >= 64:
    uint64.high
  else:
    (1'u64 shl bitCount) - 1'u64

func matchesAtUnchecked*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, position: int64, value: uint64): bool =
  ## 位置検証を省略し、`position` にある値との等値を判定します。
  ##
  ## The caller must guarantee `0 <= position < wm.n`. Unlike `access`, this
  ## exits as soon as a level bit differs from the requested value.
  if not valueFits(wm.bitWidth, value):
    return false

  var pos = position
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let actualOne = wm.levels[level].bitAtUnchecked(pos)
    let expectedOne = ((value shr shift) and 1'u64) != 0
    if actualOne != expectedOne:
      return false

    let ones = wm.levels[level].rank1Unchecked(pos)
    if actualOne:
      pos = wm.zeroCounts[level] + ones
    else:
      pos -= ones
  true

func matchesAt*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, position: int64, value: uint64): bool =
  ## `position` にある値が `value` と等しい場合にtrueを返します。
  ##
  ## Positions are 0-based. The traversal stops at the first mismatching bit,
  ## avoiding full-value reconstruction for most negative probes.
  if position < 0 or position >= wm.n:
    raise newException(IndexDefect, "index out of bounds")
  wm.matchesAtUnchecked(position, value)

func valueInRangeAtUnchecked*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, position: int64, low, high: uint64): bool =
  ## 位置検証を省略し、`position` の値がinclusive range `[low, high]` に
  ## 含まれるかを判定します。
  ##
  ## The caller must guarantee `0 <= position < wm.n`. Since WaveletMatrix is
  ## MSB-first, every visited prefix describes one contiguous interval. If that
  ## interval becomes disjoint from `[low, high]`, the function returns false;
  ## if the interval is fully contained by `[low, high]`, it returns true. Rank
  ## is evaluated only when traversal to the next level is still necessary.
  if low > high:
    return false

  let domainHigh = lowBitsMask(wm.bitWidth)
  if low == 0 and high >= domainHigh:
    return true

  var pos = position
  var prefix = 0'u64
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let actualOne = wm.levels[level].bitAtUnchecked(pos)
    if actualOne:
      prefix = prefix or (1'u64 shl shift)

    let possibleLow = prefix
    let possibleHigh = prefix or lowBitsMask(shift)
    if possibleHigh < low or possibleLow > high:
      return false
    if low <= possibleLow and possibleHigh <= high:
      return true

    let ones = wm.levels[level].rank1Unchecked(pos)
    if actualOne:
      pos = wm.zeroCounts[level] + ones
    else:
      pos -= ones

  true

func valueInRangeAt*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, position: int64, low, high: uint64): bool =
  ## `position` の値がinclusive range `[low, high]` に含まれる場合に
  ## trueを返します。
  ##
  ## This API is specific to the MSB-first WaveletMatrix because its prefixes
  ## map to contiguous numeric intervals and can therefore be pruned early.
  if position < 0 or position >= wm.n:
    raise newException(IndexDefect, "index out of bounds")
  wm.valueInRangeAtUnchecked(position, low, high)

func matchesAtUnchecked*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](
    rwm: W, position: int64, value: uint64): bool =
  ## LSB-first matrixで位置検証を省略して等値を判定します。
  ##
  ## The caller must guarantee `0 <= position < rwm.n`. Traversal stops at the
  ## first mismatching level.
  if not valueFits(rwm.bitWidth, value):
    return false

  var pos = position
  for level in 0..<rwm.bitWidth:
    let actualOne = rwm.levels[level].bitAtUnchecked(pos)
    let expectedOne = ((value shr level) and 1'u64) != 0
    if actualOne != expectedOne:
      return false

    let ones = rwm.levels[level].rank1Unchecked(pos)
    if actualOne:
      pos = rwm.zeroCounts[level] + ones
    else:
      pos -= ones
  true

func matchesAt*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](
    rwm: W, position: int64, value: uint64): bool =
  ## `position` にある値が `value` と等しい場合にtrueを返します。
  ##
  ## Positions are 0-based. For RWM the low-order bits are compared first, so
  ## negative probes whose low bits differ can return especially early.
  if position < 0 or position >= rwm.n:
    raise newException(IndexDefect, "index out of bounds")
  rwm.matchesAtUnchecked(position, value)
