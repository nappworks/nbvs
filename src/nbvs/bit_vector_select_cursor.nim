## Monotonic select cursor for SuccinctBitVector.
##
## Repeated `select0` / `select1` calls with increasing occurrence indexes can
## avoid descending the select prefix tree for every query. The first lookup is
## resolved with the regular select implementation; subsequent lookups scan
## forward from the previously selected bit and therefore reuse traversal state.
##
## To avoid regressions on sparse bit distributions, the cursor scans at most one
## 512-bit block worth of words before falling back to the regular select tree.

import std/bitops
import succinct_bit_vector

const SelectCursorMaxScanWords = 8

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

func resetWithRegularSelect[S: SuccinctBitVector | SuccinctBitVectorView](
    sbv: S, cursor: var BitVectorSelectCursor, occurrence: int64): int64 {.inline.} =
  result = if cursor.targetOne: sbv.select1(occurrence) else: sbv.select0(occurrence)
  cursor.lastOccurrence = occurrence
  cursor.lastPosition = result
  cursor.initialized = result >= 0

func selectMonotonicUnchecked*[S: SuccinctBitVector | SuccinctBitVectorView](
    sbv: S, cursor: var BitVectorSelectCursor, occurrence: int64): int64 =
  ## Selects an in-range occurrence while reusing the previous result.
  ##
  ## `sbv` must be built and `occurrence` must be in range for the selected bit.
  ## Non-increasing targets are supported by resetting through regular select.
  if not cursor.initialized or occurrence <= cursor.lastOccurrence:
    return sbv.resetWithRegularSelect(cursor, occurrence)

  var remaining = occurrence - cursor.lastOccurrence
  var position = cursor.lastPosition + 1
  var wordIdx = int(position shr 6)
  var bitOffset = int(position and 63)
  var scannedWords = 0

  while wordIdx < sbv.dataWords and scannedWords < SelectCursorMaxScanWords:
    var word = sbv.matchingWord(wordIdx, cursor.targetOne)
    if bitOffset > 0:
      word = word and (uint64.high shl bitOffset)

    let count = int64(countSetBits(word))
    if remaining <= count:
      let bit = selectInWord64Pdep(word, int(remaining))
      result = int64(wordIdx) * 64 + int64(bit)
      cursor.lastOccurrence = occurrence
      cursor.lastPosition = result
      return

    remaining -= count
    inc wordIdx
    bitOffset = 0
    inc scannedWords

  # Sparse or widely separated targets are better served by the existing
  # logarithmic select tree than by an unbounded forward scan.
  result = sbv.resetWithRegularSelect(cursor, occurrence)

func selectMonotonic*[S: SuccinctBitVector | SuccinctBitVectorView](
    sbv: S, cursor: var BitVectorSelectCursor, occurrence: int64): int64 =
  ## Safe monotonic select wrapper.
  if not sbv.isCalced:
    raise newException(ValueError, "rank dictionary is not built")
  let total = if cursor.targetOne: sbv.totalOnes else: sbv.totalZeros
  if occurrence < 0 or occurrence >= total:
    return -1
  result = sbv.selectMonotonicUnchecked(cursor, occurrence)
