## Succinct quad vector with rank/select support.
##
## `QuadVector` stores symbols in `0..3` using a 2-bit `PackedArray`. After
## `build`, rank uses 4096-symbol superblocks subdivided into 512-symbol blocks,
## and select uses one sampled superblock id per 1024 occurrences of each
## symbol.
##
## The asymptotic auxiliary-space budget is:
##
## * rank: 6.25% of the 2-bit payload (44-bit superblock counters plus seven
##   12-bit block prefixes for each of four symbols per 4096-symbol superblock)
## * select: 1.5625% of the payload (32-bit superblock id per 1024 occurrences)
## * total: 7.8125%, excluding object headers and tail rounding.
##
## Rank semantics match `SuccinctBitVector`: `rank(symbol, pos)` counts symbols
## in `[0, pos)`. Select is 0-based and returns `-1` when the occurrence index
## is out of range.

import std/bitops
import ./packed_array

const
  QuadRankBlockSize* = 512'i64
  QuadRankSuperBlockSize* = 4096'i64
  QuadBlocksPerSuperBlock* = 8'i64
  QuadSelectSampleRate* = 1024'i64
  MaxQuadVectorSymbols* = (1'i64 shl 43) - 1'i64

  RankSuperCounterWidth = 44
  RankBlockCounterWidth = 12
  SelectSampleWidth = 32
  RankBlockPrefixesPerSuper = 7'i64 * 4'i64
  QuadLaneMask = 0x5555_5555_5555_5555'u64

type
  QuadVector* = object
    ## Mutable 2-bit symbol vector. Call `build` after mutation before rank/select.
    maxOfSymbols*: int64
    lenOfSymbols*: int64
    data*: PackedArray

    isCalced*: bool
    totalCounts*: array[4, int64]
    superBlockCount*: int64

    ## Four 44-bit absolute counters at each 4096-symbol superblock start.
    rankSuperPrefix*: PackedArray
    ## Seven 12-bit local block prefixes for each of four symbols per superblock.
    rankBlockPrefix*: PackedArray
    ## Per-symbol sampled superblock ids, sampled every 1024 occurrences.
    selectSamples*: array[4, PackedArray]

func ceilDivPositive(x, y: int64): int64 {.inline.} =
  if x <= 0: 0 else: (x + y - 1) div y

func checkSymbol(symbol: int) {.inline.} =
  if symbol < 0 or symbol > 3:
    raise newException(ValueError, "symbol must be in 0..3")

func checkAccessIndex(qv: QuadVector, pos: int64) {.inline.} =
  if pos < 0 or pos >= qv.lenOfSymbols:
    raise newException(IndexDefect, "Index out of bounds")

func checkRankPosition(qv: QuadVector, pos: int64) {.inline.} =
  if pos < 0 or pos > qv.lenOfSymbols:
    raise newException(IndexDefect, "Index out of bounds")

func requireBuilt(qv: QuadVector) {.inline.} =
  if not qv.isCalced:
    raise newException(ValueError, "QuadVector rank/select dictionary is not built")

func rankSuperIndex(superBlock, symbol: int64): int64 {.inline.} =
  superBlock * 4'i64 + symbol

func rankBlockIndex(superBlock, block, symbol: int64): int64 {.inline.} =
  ## `block` is 1..7 and stores the prefix at that block's start.
  superBlock * RankBlockPrefixesPerSuper + (block - 1'i64) * 4'i64 + symbol

func matchingLaneMask(word: uint64, symbol: int): uint64 {.inline.} =
  ## One bit at every matching 2-bit lane, in bit positions 0,2,...,62.
  let pattern = uint64(symbol) * QuadLaneMask
  let different = word xor pattern
  result = (not (different or (different shr 1))) and QuadLaneMask

func validLaneMask(symbolCount: int): uint64 {.inline.} =
  if symbolCount <= 0:
    0'u64
  elif symbolCount >= 32:
    QuadLaneMask
  else:
    QuadLaneMask and ((1'u64 shl (symbolCount * 2)) - 1'u64)

func countSymbolRange(qv: QuadVector, symbol: int,
                      startPos, endPos: int64): int64 {.inline.} =
  ## Counts `symbol` in a word-aligned range. Rank block starts are 512-aligned.
  if endPos <= startPos:
    return 0

  var wordIndex = int(startPos shr 5)
  var remaining = endPos - startPos
  while remaining >= 32:
    result += int64(countSetBits(matchingLaneMask(qv.data.data[wordIndex], symbol)))
    inc wordIndex
    remaining -= 32

  if remaining > 0:
    let mask = matchingLaneMask(qv.data.data[wordIndex], symbol) and
      validLaneMask(int(remaining))
    result += int64(countSetBits(mask))

func selectSymbolRange(qv: QuadVector, symbol: int, startPos, endPos: int64,
                       occurrence: int64): int64 {.inline.} =
  ## Returns the `occurrence`-th matching symbol in the word-aligned range.
  var wanted = occurrence
  var wordPos = startPos
  var wordIndex = int(startPos shr 5)

  while wordPos < endPos:
    let symbolsInWord = int(min(32'i64, endPos - wordPos))
    var matches = matchingLaneMask(qv.data.data[wordIndex], symbol) and
      validLaneMask(symbolsInWord)
    let count = int64(countSetBits(matches))
    if wanted < count:
      var skip = wanted
      while skip > 0:
        matches = matches and (matches - 1'u64)
        dec skip
      return wordPos + int64(countTrailingZeroBits(matches) shr 1)
    wanted -= count
    wordPos += int64(symbolsInWord)
    inc wordIndex

  -1

func genQuadVector*(maxSymbols: int64): QuadVector =
  ## Creates a mutable quad vector with `maxSymbols` symbols initialized to 0.
  if maxSymbols < 0:
    raise newException(ValueError, "maxSymbols must be non-negative")
  if maxSymbols > MaxQuadVectorSymbols:
    raise newException(ValueError, "maxSymbols exceeds QuadVector limit")

  result.maxOfSymbols = maxSymbols
  result.lenOfSymbols = maxSymbols
  result.data = genPackedArray(maxSymbols, 2)
  result.superBlockCount = ceilDivPositive(maxSymbols, QuadRankSuperBlockSize)
  result.rankSuperPrefix = genPackedArray(result.superBlockCount * 4'i64,
                                           RankSuperCounterWidth)
  result.rankBlockPrefix = genPackedArray(
    result.superBlockCount * RankBlockPrefixesPerSuper,
    RankBlockCounterWidth)
  for symbol in 0..3:
    result.selectSamples[symbol] = genPackedArray(0, SelectSampleWidth)

func access*(qv: QuadVector, pos: int64): uint8 =
  ## Returns the symbol at `pos`.
  qv.checkAccessIndex(pos)
  result = uint8(qv.data[pos])

func `[]`*(qv: QuadVector, pos: int64): uint8 =
  ## Alias for `access`.
  qv.access(pos)

func setSymbol*(qv: var QuadVector, pos: int64, value: uint8) =
  ## Stores a symbol in `0..3` and invalidates rank/select metadata.
  qv.checkAccessIndex(pos)
  if value > 3'u8:
    raise newException(ValueError, "QuadVector value must be in 0..3")
  qv.data[pos] = uint64(value)
  qv.isCalced = false

func `[]=`*(qv: var QuadVector, pos: int64, value: uint8) =
  ## Alias for `setSymbol`.
  qv.setSymbol(pos, value)

func clearSymbol*(qv: var QuadVector, pos: int64) =
  ## Sets the symbol at `pos` to 0 and invalidates rank/select metadata.
  qv.setSymbol(pos, 0'u8)

func build*(qv: var QuadVector) =
  ## Builds or rebuilds the rank/select dictionary.
  qv.totalCounts = [0'i64, 0'i64, 0'i64, 0'i64]

  for pos in 0'i64..<qv.lenOfSymbols:
    inc qv.totalCounts[int(qv.data[pos])]

  for symbol in 0..3:
    let sampleCount = ceilDivPositive(qv.totalCounts[symbol],
                                      QuadSelectSampleRate)
    qv.selectSamples[symbol] = genPackedArray(sampleCount, SelectSampleWidth)

  qv.rankSuperPrefix = genPackedArray(qv.superBlockCount * 4'i64,
                                       RankSuperCounterWidth)
  qv.rankBlockPrefix = genPackedArray(
    qv.superBlockCount * RankBlockPrefixesPerSuper,
    RankBlockCounterWidth)

  var absolute = [0'i64, 0'i64, 0'i64, 0'i64]
  var local = [0'i64, 0'i64, 0'i64, 0'i64]

  for pos in 0'i64..<qv.lenOfSymbols:
    let offsetInSuper = pos mod QuadRankSuperBlockSize
    let superBlock = pos div QuadRankSuperBlockSize

    if offsetInSuper == 0:
      local = [0'i64, 0'i64, 0'i64, 0'i64]
      for symbol in 0..3:
        qv.rankSuperPrefix[rankSuperIndex(superBlock, int64(symbol))] =
          uint64(absolute[symbol])
    elif offsetInSuper mod QuadRankBlockSize == 0:
      let block = offsetInSuper div QuadRankBlockSize
      for symbol in 0..3:
        qv.rankBlockPrefix[rankBlockIndex(superBlock, block,
                                          int64(symbol))] =
          uint64(local[symbol])

    let symbol = int(qv.data[pos])
    if absolute[symbol] mod QuadSelectSampleRate == 0:
      let sampleIndex = absolute[symbol] div QuadSelectSampleRate
      qv.selectSamples[symbol][sampleIndex] = uint64(superBlock)

    inc absolute[symbol]
    inc local[symbol]

  qv.isCalced = true

func rankUnchecked*(qv: QuadVector, symbol: int, pos: int64): int64 {.inline.} =
  ## Unchecked rank. Requires built metadata, a symbol in 0..3, and 0<=pos<=len.
  if pos == qv.lenOfSymbols:
    return qv.totalCounts[symbol]

  let superBlock = pos div QuadRankSuperBlockSize
  let offsetInSuper = pos mod QuadRankSuperBlockSize
  let block = offsetInSuper div QuadRankBlockSize

  result = int64(qv.rankSuperPrefix[
    rankSuperIndex(superBlock, int64(symbol))])
  if block > 0:
    result += int64(qv.rankBlockPrefix[
      rankBlockIndex(superBlock, block, int64(symbol))])

  let blockStart = superBlock * QuadRankSuperBlockSize +
                   block * QuadRankBlockSize
  result += qv.countSymbolRange(symbol, blockStart, pos)

func rank*(qv: QuadVector, symbol: int, pos: int64): int64 =
  ## Counts `symbol` in `[0, pos)`.
  checkSymbol(symbol)
  qv.checkRankPosition(pos)
  qv.requireBuilt()
  result = qv.rankUnchecked(symbol, pos)

func rankIncl*(qv: QuadVector, symbol: int, pos: int64): int64 =
  ## Counts `symbol` in `[0, pos]`.
  checkSymbol(symbol)
  qv.checkAccessIndex(pos)
  qv.requireBuilt()
  result = qv.rankUnchecked(symbol, pos + 1)

func superStartRank(qv: QuadVector, symbol: int, superBlock: int64): int64 {.inline.} =
  if superBlock >= qv.superBlockCount:
    qv.totalCounts[symbol]
  else:
    int64(qv.rankSuperPrefix[rankSuperIndex(superBlock, int64(symbol))])

func select*(qv: QuadVector, symbol: int, k: int64): int64 =
  ## Returns the position of the 0-based `k`-th occurrence, or -1 if absent.
  checkSymbol(symbol)
  qv.requireBuilt()
  if k < 0 or k >= qv.totalCounts[symbol]:
    return -1

  let sampleIndex = k div QuadSelectSampleRate
  let sampleBlock = int64(qv.selectSamples[symbol][sampleIndex])
  let sampleCount = qv.selectSamples[symbol].len

  var upperExclusive = qv.superBlockCount
  if sampleIndex + 1 < sampleCount:
    upperExclusive = min(upperExclusive,
      int64(qv.selectSamples[symbol][sampleIndex + 1]) + 1'i64)

  # Find the first superblock whose end-prefix is greater than k. This stays
  # correct across runs of superblocks that contain no occurrence of `symbol`.
  var lo = sampleBlock
  var hi = upperExclusive
  while lo < hi:
    let mid = lo + ((hi - lo) shr 1)
    if qv.superStartRank(symbol, mid + 1) > k:
      hi = mid
    else:
      lo = mid + 1
  let superBlock = lo
  let superStartPos = superBlock * QuadRankSuperBlockSize
  let superEndPos = min(qv.lenOfSymbols,
                        superStartPos + QuadRankSuperBlockSize)
  let superRank = qv.superStartRank(symbol, superBlock)
  let wantedInSuper = k - superRank
  let symbolsInSuper = superEndPos - superStartPos
  let blockCount = ceilDivPositive(symbolsInSuper, QuadRankBlockSize)

  var previous = 0'i64
  for block in 0'i64..<blockCount:
    let blockEndRank =
      if block + 1 < blockCount:
        int64(qv.rankBlockPrefix[
          rankBlockIndex(superBlock, block + 1, int64(symbol))])
      else:
        qv.superStartRank(symbol, superBlock + 1) - superRank

    if wantedInSuper < blockEndRank:
      let blockStartPos = superStartPos + block * QuadRankBlockSize
      let blockEndPos = min(superEndPos, blockStartPos + QuadRankBlockSize)
      return qv.selectSymbolRange(symbol, blockStartPos, blockEndPos,
                                  wantedInSuper - previous)
    previous = blockEndRank

  -1

template defineRankWrappers(name, symbolValue: untyped) =
  func name*(qv: QuadVector, pos: int64): int64 =
    qv.rank(symbolValue, pos)

template defineRankInclWrappers(name, symbolValue: untyped) =
  func name*(qv: QuadVector, pos: int64): int64 =
    qv.rankIncl(symbolValue, pos)

template defineSelectWrappers(name, symbolValue: untyped) =
  func name*(qv: QuadVector, k: int64): int64 =
    qv.select(symbolValue, k)

defineRankWrappers(rank0, 0)
defineRankWrappers(rank1, 1)
defineRankWrappers(rank2, 2)
defineRankWrappers(rank3, 3)
defineRankInclWrappers(rank0Incl, 0)
defineRankInclWrappers(rank1Incl, 1)
defineRankInclWrappers(rank2Incl, 2)
defineRankInclWrappers(rank3Incl, 3)
defineSelectWrappers(select0, 0)
defineSelectWrappers(select1, 1)
defineSelectWrappers(select2, 2)
defineSelectWrappers(select3, 3)

func rawBytes*(qv: QuadVector): int64 =
  ## Allocated bytes in the 2-bit payload storage.
  int64(qv.data.data.len * sizeof(uint64))

func rankAuxiliaryBytes*(qv: QuadVector): int64 =
  ## Allocated rank dictionary bytes.
  int64((qv.rankSuperPrefix.data.len + qv.rankBlockPrefix.data.len) *
        sizeof(uint64))

func selectAuxiliaryBytes*(qv: QuadVector): int64 =
  ## Allocated select-sample bytes.
  for symbol in 0..3:
    result += int64(qv.selectSamples[symbol].data.len * sizeof(uint64))

func auxiliaryBytes*(qv: QuadVector): int64 =
  qv.rankAuxiliaryBytes + qv.selectAuxiliaryBytes

func allocatedBytes*(qv: QuadVector): int64 =
  ## Allocated packed storage bytes, excluding Nim object/seq headers.
  qv.rawBytes + qv.auxiliaryBytes

func `$`*(qv: QuadVector): string =
  ## Returns the symbol sequence as digits `0`..`3`.
  result = newStringOfCap(int(min(qv.lenOfSymbols, int64(int.high))))
  for pos in 0'i64..<qv.lenOfSymbols:
    result.add char(ord('0') + int(qv.data[pos]))
