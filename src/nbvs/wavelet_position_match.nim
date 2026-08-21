## Early-exit equality predicates for wavelet-matrix positions.
##
## `matchesAt` tests whether the value stored at a physical position equals the
## requested value without reconstructing the full value first. Traversal stops
## at the first mismatching bit. Both owning and non-owning View types are
## supported for WaveletMatrix (MSB-first) and ReversedWaveletMatrix (LSB-first).

import wavelet_matrix
import reversed_wavelet_matrix
import succinct_bit_vector

func bitAtUnchecked[B: SuccinctBitVector | SuccinctBitVectorView](
    bits: B, pos: int64): bool {.inline.} =
  ((bits.data[int(pos shr 6)] shr int(pos and 63)) and 1'u64) != 0

func valueFits(bitWidth: int, value: uint64): bool {.inline.} =
  bitWidth == 64 or (bitWidth > 0 and (value shr bitWidth) == 0)

func matchesAtUnchecked*[W: WaveletMatrix | WaveletMatrixView](
    wm: W, position: int64, value: uint64): bool =
  ## Tests equality at `position` without bounds checks.
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
  ## Returns true iff the value at `position` equals `value`.
  ##
  ## Positions are 0-based. The traversal stops at the first mismatching bit,
  ## avoiding full-value reconstruction for most negative probes.
  if position < 0 or position >= wm.n:
    raise newException(IndexDefect, "index out of bounds")
  wm.matchesAtUnchecked(position, value)

func matchesAtUnchecked*[W: ReversedWaveletMatrix | ReversedWaveletMatrixView](
    rwm: W, position: int64, value: uint64): bool =
  ## Tests equality at `position` without bounds checks for an LSB-first matrix.
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
  ## Returns true iff the value at `position` equals `value`.
  ##
  ## Positions are 0-based. For RWM the low-order bits are compared first, so
  ## negative probes whose low bits differ can return especially early.
  if position < 0 or position >= rwm.n:
    raise newException(IndexDefect, "index out of bounds")
  rwm.matchesAtUnchecked(position, value)
