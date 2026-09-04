## Monotonic select cursor for SuccinctBitVector.
##
## Repeated `select0` / `select1` calls with increasing occurrence indexes can
## avoid descending the select prefix tree for every query. The first lookup is
## resolved with the regular select implementation; subsequent lookups scan
## forward from the previously selected bit and therefore reuse traversal state.

import std/bitops
import succinct_bit_vector

type
  BitVectorSelectCursor* = object
    ## Query-local state for monotonically increasing select targets.
    targetOne*: bool
    lastOccurrence*: int64
    lastPosition*: int64
    initialized*: bool

func initBitVectorSelectCursor*(targetOne: bool): BitVectorSelectCursor {.inline.} =
  result.targetOne = targetOne
  result.lastOccurrence = -1
  result.lastPosition = -1

func validMaskForCursor[S: SuccinctBitVector | SuccinctBitVectorView](
    sbv: S, wordIdx: int): uint64 {.inline.} =
  if wordIdx < 0 or wordIdx >= sbv.dataWords:
    return 0'u64
  let bitStart = int64(wordIdx) * 64
  let remaining = sbv.lenOfBits - bitStart
  if remaining >= 64:
    uint64.high
  elif remaining <= 0:
    0'u64
  else:
    (1'u64 shl int(remaining)) - 1'u64

func matchingWord[S: SuccinctBitVector | SuccinctBitVectorView](
    sbv: S, wordIdx: int, targetOne: bool): uint64 {.inline.} =
  let valid = sbv.validMaskForCursor(wordIdx)
  if targetOne:
    sbv.data[wordIdx] and valid
  else:
    (not sbv.data[wordIdx]) and valid

func selectMonotonic*[S: SuccinctBitVector | SuccinctBitVectorView](
    sbv: S, cursor: var BitVectorSelectCursor, occurrence: int64): int64 =
  ## Selects the 0-based occurrence while reusing the previous result.
  ##
  ## The fast path requires strictly increasing `occurrence` values. A first
  ## lookup, or a non-increasing lookup, falls back to the regular select and
  ## resets the cursor state. This keeps the API safe for general callers while
  ## making sequential Wavelet traversal allocation-free and monotonic.
  if not sbv.isCalced:
    raise newException(ValueError, "rank dictionary is not built")

  let total = if cursor.targetOne: sbv.totalOnes else: sbv.totalZeros
  if occurrence < 0 or occurrence >= total:
    return -1

  if not cursor.initialized or occurrence <= cursor.lastOccurrence:
    result = if cursor.targetOne: sbv.select1(occurrence) else: sbv.select0(occurrence)
    cursor.lastOccurrence = occurrence
    cursor.lastPosition = result
    cursor.initialized = result >= 0
    return

  var remaining = occurrence - cursor.lastOccurrence
  var position = cursor.lastPosition + 1
  var wordIdx = int(position shr 6)
  var bitOffset = int(position and 63)

  while wordIdx < sbv.dataWords:
    var word = sbv.matchingWord(wordIdx, cursor.targetOne)
    if bitOffset > 0:
      word = word and (uint64.high shl bitOffset)

    let count = int64(countSetBits(word))
    if remaining > count:
      remaining -= count
      inc wordIdx
      bitOffset = 0
      continue

    let bit = selectInWord64Pdep(word, int(remaining))
    result = int64(wordIdx) * 64 + int64(bit)
    cursor.lastOccurrence = occurrence
    cursor.lastPosition = result
    return

  result = -1
