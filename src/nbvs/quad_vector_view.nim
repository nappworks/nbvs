## 外部連続メモリを参照する非所有 QuadVector view です。
##
## `QuadVectorView` は `PackedArrayView` を使い、2-bit payload、64-byte rank
## metadata record、select sampleを1つのcaller-owned領域へ配置します。
## mmap、shared memory、application-managed bufferを想定し、memoryの所有・解放は
## 行いません。backing先頭は64-byte alignmentが必要です。
##
## `built = false` でmutable viewを初期化し、symbol設定後に `build()` を呼べます。
## 永続化済み領域を再openする場合は `built = true` を指定します。この場合、
## totalCountsとselect sample descriptorはpayloadから再構成し、永続化済みrank/select
## metadataをそのまま利用します。

import std/bitops
import ./[packed_array, quad_vector]

when defined(nbvsSimd):
  when defined(gcc) or defined(clang):
    {.passC: "-mavx2".}
    {.passC: "-mbmi2".}
  when defined(vcc):
    {.passC: "/arch:AVX2".}
  import ./internal/x86_intrinsics

const
  QuadVectorViewAlignment* = 64
  ViewRankBlockShift = 9
  ViewRankSuperBlockShift = 12
  ViewRankSuperCounterWidth = 44
  ViewRankBlockCounterWidth = 12
  ViewSelectSampleWidth = 32
  ViewRankSuperBitsPerRecord = 4 * ViewRankSuperCounterWidth
  ViewRankMetadataWordsPerSuper = 8'i64
  ViewRankSuperCounterMask = (1'u64 shl ViewRankSuperCounterWidth) - 1'u64
  ViewRankBlockCounterMask = (1'u64 shl ViewRankBlockCounterWidth) - 1'u64
  ViewQuadLaneMask = 0x5555_5555_5555_5555'u64

when defined(nbvsSimd):
  const ViewQuadZeroPairNibbleLookup = [
    2'i8, 1'i8, 1'i8, 1'i8, 1'i8, 0'i8, 0'i8, 0'i8,
    1'i8, 0'i8, 0'i8, 0'i8, 1'i8, 0'i8, 0'i8, 0'i8,
    2'i8, 1'i8, 1'i8, 1'i8, 1'i8, 0'i8, 0'i8, 0'i8,
    1'i8, 0'i8, 0'i8, 0'i8, 1'i8, 0'i8, 0'i8, 0'i8
  ]

type
  QuadVectorView* = object
    ## caller-owned memory上の非所有QuadVectorです。
    maxOfSymbols*: int64
    lenOfSymbols*: int64
    data*: PackedArrayView

    isCalced*: bool
    totalCounts*: array[4, int64]
    superBlockCount*: int64
    rankMetadata*: PackedArrayView
    selectSamples*: array[4, PackedArrayView]

    ## select sample用に予約した連続word領域です。descriptor再構成用のruntime情報で、
    ## pointer値自体は永続化しません。
    selectStorage*: ptr UncheckedArray[uint64]
    selectStorageWords*: int
    selectStorageUsedWords*: int
    backingBytes*: int

func ceilDivPositive(x, y: int64): int64 {.inline.} =
  if x <= 0: 0 else: (x + y - 1) div y

func alignUpPositive(x, alignment: int64): int64 {.inline.} =
  if x <= 0: 0 else: ceilDivPositive(x, alignment) * alignment

func validateSymbolCount(maxSymbols: int64) {.inline.} =
  if maxSymbols < 0:
    raise newException(ValueError, "maxSymbols must be non-negative")
  if maxSymbols > MaxQuadVectorSymbols:
    raise newException(ValueError, "maxSymbols exceeds QuadVector limit")

func payloadWords(maxSymbols: int64): int64 {.inline.} =
  ceilDivPositive(maxSymbols, 32'i64)

func rankWords(maxSymbols: int64): int64 {.inline.} =
  ceilDivPositive(maxSymbols, QuadRankSuperBlockSize) *
    ViewRankMetadataWordsPerSuper

func maxSelectStorageWords(maxSymbols: int64): int64 =
  ## 4 symbolの実出現数が未確定なbuild前でも、32-bit sampleを別々の
  ## PackedArrayViewとして配置できる最小worst-case word数を返します。
  ##
  ## 1 wordは2 sample、1 sampleは1024 occurrenceなので、symbolごとの必要wordは
  ## ceil(count / 2048)。sum(count)=maxSymbols の制約下で最大値を求めます。
  if maxSymbols <= 0:
    return 0
  let maxPositiveSymbols = int(min(4'i64, maxSymbols))
  let occurrencesPerWord = QuadSelectSampleRate * 2'i64
  for positiveSymbols in 1..maxPositiveSymbols:
    let words = int64(positiveSymbols) +
      (maxSymbols - int64(positiveSymbols)) div occurrencesPerWord
    if words > result:
      result = words

func requiredQuadVectorViewBytes*(maxSymbols: int64): int =
  ## 1つの`QuadVectorView` backing領域に必要なbyte数を返します。
  ##
  ## payloadの後でrank metadataを64-byte境界へ揃え、その後へselect sampleの
  ## worst-case容量を置きます。先頭pointer自体も64-byte alignedである必要があります。
  validateSymbolCount(maxSymbols)
  let dataBytes = payloadWords(maxSymbols) * int64(sizeof(uint64))
  let rankOffset = alignUpPositive(dataBytes, int64(QuadVectorViewAlignment))
  let rankBytes = rankWords(maxSymbols) * int64(sizeof(uint64))
  let selectBytes = maxSelectStorageWords(maxSymbols) * int64(sizeof(uint64))
  let total = rankOffset + rankBytes + selectBytes
  if total > int64(int.high):
    raise newException(ValueError, "backing memory size exceeds int range")
  result = int(total)

func offsetPointer(base: pointer, offset: int): pointer {.inline.} =
  cast[pointer](cast[uint](base) + uint(offset))

func emptyPackedView(bitWidth: int): PackedArrayView {.inline.} =
  initPackedArrayView(nil, 0, 0, bitWidth)

func checkSymbol(symbol: int) {.inline.} =
  if symbol < 0 or symbol > 3:
    raise newException(ValueError, "symbol must be in 0..3")

func checkAccessIndex(qv: QuadVectorView, pos: int64) {.inline.} =
  if pos < 0 or pos >= qv.lenOfSymbols:
    raise newException(IndexDefect, "Index out of bounds")

func checkRankPosition(qv: QuadVectorView, pos: int64) {.inline.} =
  if pos < 0 or pos > qv.lenOfSymbols:
    raise newException(IndexDefect, "Index out of bounds")

func requireBuilt(qv: QuadVectorView) {.inline.} =
  if not qv.isCalced:
    raise newException(ValueError, "QuadVector rank/select dictionary is not built")

func rankSuperBitOffset(symbol: int): int {.inline.} =
  symbol * ViewRankSuperCounterWidth

func rankBlockBitOffset(blockIndex: int64, symbol: int): int {.inline.} =
  ViewRankSuperBitsPerRecord +
    (int(blockIndex - 1'i64) * 4 + symbol) * ViewRankBlockCounterWidth

func readRankField(qv: QuadVectorView, superBlock: int64,
                   bitOffset, width: int, mask: uint64): uint64 {.inline.} =
  let baseWord = int(superBlock * ViewRankMetadataWordsPerSuper)
  let wordOffset = bitOffset shr 6
  let bitInWord = bitOffset and 63
  result = qv.rankMetadata.data[baseWord + wordOffset] shr bitInWord
  if bitInWord + width > 64:
    result = result or
      (qv.rankMetadata.data[baseWord + wordOffset + 1] shl (64 - bitInWord))
  result = result and mask

func writeRankField(qv: var QuadVectorView, superBlock: int64,
                    bitOffset, width: int, mask, value: uint64) {.inline.} =
  doAssert (value and not mask) == 0'u64
  let baseWord = int(superBlock * ViewRankMetadataWordsPerSuper)
  let wordOffset = bitOffset shr 6
  let bitInWord = bitOffset and 63
  let lowWidth = min(width, 64 - bitInWord)
  let lowValueMask =
    if lowWidth == 64: uint64.high else: (1'u64 shl lowWidth) - 1'u64
  let targetLowMask = lowValueMask shl bitInWord
  let index = baseWord + wordOffset
  qv.rankMetadata.data[index] =
    (qv.rankMetadata.data[index] and not targetLowMask) or
    ((value and lowValueMask) shl bitInWord)

  if lowWidth < width:
    let highWidth = width - lowWidth
    let highMask = (1'u64 shl highWidth) - 1'u64
    qv.rankMetadata.data[index + 1] =
      (qv.rankMetadata.data[index + 1] and not highMask) or
      ((value shr lowWidth) and highMask)

func rankSuperAt(qv: QuadVectorView, superBlock: int64,
                 symbol: int): int64 {.inline.} =
  int64(qv.readRankField(superBlock, rankSuperBitOffset(symbol),
                         ViewRankSuperCounterWidth, ViewRankSuperCounterMask))

func rankBlockAt(qv: QuadVectorView, superBlock, blockIndex: int64,
                 symbol: int): int64 {.inline.} =
  int64(qv.readRankField(superBlock,
                         rankBlockBitOffset(blockIndex, symbol),
                         ViewRankBlockCounterWidth, ViewRankBlockCounterMask))

func setRankSuper(qv: var QuadVectorView, superBlock: int64,
                  symbol: int, value: int64) {.inline.} =
  qv.writeRankField(superBlock, rankSuperBitOffset(symbol),
                    ViewRankSuperCounterWidth, ViewRankSuperCounterMask,
                    uint64(value))

func setRankBlock(qv: var QuadVectorView, superBlock, blockIndex: int64,
                  symbol: int, value: int64) {.inline.} =
  qv.writeRankField(superBlock, rankBlockBitOffset(blockIndex, symbol),
                    ViewRankBlockCounterWidth, ViewRankBlockCounterMask,
                    uint64(value))

func symbolUnchecked(qv: QuadVectorView, pos: int64): uint8 {.inline.} =
  let wordIndex = int(pos shr 5)
  let shift = int((pos and 31'i64) shl 1)
  uint8((qv.data.data[wordIndex] shr shift) and 3'u64)

func matchingLaneMask(word: uint64, symbol: int): uint64 {.inline.} =
  let pattern = uint64(symbol) * ViewQuadLaneMask
  let different = word xor pattern
  result = (not (different or (different shr 1))) and ViewQuadLaneMask

func validLaneMask(symbolCount: int): uint64 {.inline.} =
  if symbolCount <= 0:
    0'u64
  elif symbolCount >= 32:
    ViewQuadLaneMask
  else:
    ViewQuadLaneMask and ((1'u64 shl (symbolCount * 2)) - 1'u64)

func addCounts(target: var array[4, int64], source: array[4, int64]) {.inline.} =
  for symbol in 0..3:
    target[symbol] += source[symbol]

func countSymbolsWord(word: uint64, symbolCount: int): array[4, int64] {.inline.} =
  let valid = validLaneMask(symbolCount)
  let low = word and valid
  let high = (word shr 1) and valid
  let both = low and high
  result[3] = int64(countSetBits(both))
  result[1] = int64(countSetBits(low and not high))
  result[2] = int64(countSetBits(high and not low))
  result[0] = int64(symbolCount) - result[1] - result[2] - result[3]

func countSymbolsRangeScalar(qv: QuadVectorView,
                             startPos, endPos: int64): array[4, int64] {.inline.} =
  if endPos <= startPos:
    return
  var wordIndex = int(startPos shr 5)
  var remaining = endPos - startPos
  while remaining >= 32:
    result.addCounts(countSymbolsWord(qv.data.data[wordIndex], 32))
    inc wordIndex
    remaining -= 32
  if remaining > 0:
    result.addCounts(countSymbolsWord(qv.data.data[wordIndex], int(remaining)))

func countSymbolRangeScalar(qv: QuadVectorView, symbol: int,
                            startPos, endPos: int64): int64 {.inline.} =
  if endPos <= startPos:
    return 0
  var wordIndex = int(startPos shr 5)
  var remaining = endPos - startPos
  while remaining >= 32:
    result += int64(countSetBits(matchingLaneMask(
      qv.data.data[wordIndex], symbol)))
    inc wordIndex
    remaining -= 32
  if remaining > 0:
    let mask = matchingLaneMask(qv.data.data[wordIndex], symbol) and
      validLaneMask(int(remaining))
    result += int64(countSetBits(mask))

func selectSymbolRangeScalar(qv: QuadVectorView, symbol: int,
                             startPos, endPos, occurrence: int64): int64 {.inline, used.} =
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

when defined(nbvsSimd):
  func countSymbolPacked128LanesAvx2(packed, repeatedPattern,
                                     nibbleMask, lookup, zero: M256i): M256i {.inline.} =
    let normalized = mm256_xor_si256(packed, repeatedPattern)
    let lo = mm256_and_si256(normalized, nibbleMask)
    let hi = mm256_and_si256(mm256_srli_epi16(normalized, 4), nibbleMask)
    let loCounts = mm256_shuffle_epi8(lookup, lo)
    let hiCounts = mm256_shuffle_epi8(lookup, hi)
    let byteCounts = mm256_add_epi8(loCounts, hiCounts)
    result = mm256_sad_epu8(byteCounts, zero)

  func reduceFourU64Lanes(value: M256i): int64 {.inline.} =
    var lanes: array[4, uint64]
    mm256_storeu_si256(cast[ptr M256i](addr lanes[0]), value)
    int64(lanes[0] + lanes[1] + lanes[2] + lanes[3])

  func countSymbolPacked128Avx2(packed: M256i, symbol: int,
                                nibbleMask, lookup, zero: M256i): int64 {.inline.} =
    let repeated = mm256_set1_epi8(cast[int8](uint8(symbol * 0x55)))
    result = reduceFourU64Lanes(countSymbolPacked128LanesAvx2(
      packed, repeated, nibbleMask, lookup, zero))

  func countSymbols128Avx2(qv: QuadVectorView,
                           wordIndex: int): array[4, int64] {.inline.} =
    let packed = mm256_loadu_si256(
      cast[ptr M256i](unsafeAddr qv.data.data[wordIndex]))
    let nibbleMask = mm256_set1_epi8(0x0f'i8)
    let lookup = mm256_loadu_si256(
      cast[ptr M256i](unsafeAddr ViewQuadZeroPairNibbleLookup[0]))
    let zero = mm256_set1_epi8(0'i8)
    result[1] = countSymbolPacked128Avx2(packed, 1, nibbleMask, lookup, zero)
    result[2] = countSymbolPacked128Avx2(packed, 2, nibbleMask, lookup, zero)
    result[3] = countSymbolPacked128Avx2(packed, 3, nibbleMask, lookup, zero)
    result[0] = 128'i64 - result[1] - result[2] - result[3]

  func selectSymbolRangeBmi2(qv: QuadVectorView, symbol: int,
                             startPos, endPos, occurrence: int64): int64 {.inline.} =
    var wanted = occurrence
    var wordPos = startPos
    var wordIndex = int(startPos shr 5)
    while wordPos < endPos:
      let symbolsInWord = int(min(32'i64, endPos - wordPos))
      let matches = matchingLaneMask(qv.data.data[wordIndex], symbol) and
        validLaneMask(symbolsInWord)
      let count = int64(countSetBits(matches))
      if wanted < count:
        let deposited = pdepU64(1'u64 shl int(wanted), matches)
        return wordPos + int64(countTrailingZeroBits(deposited) shr 1)
      wanted -= count
      wordPos += int64(symbolsInWord)
      inc wordIndex
    -1

  func countSymbolsRange(qv: QuadVectorView,
                         startPos, endPos: int64): array[4, int64] {.inline.} =
    if endPos <= startPos:
      return
    var symbolPos = startPos
    var wordIndex = int(startPos shr 5)
    while endPos - symbolPos >= 128:
      result.addCounts(qv.countSymbols128Avx2(wordIndex))
      symbolPos += 128
      wordIndex += 4
    if symbolPos < endPos:
      result.addCounts(qv.countSymbolsRangeScalar(symbolPos, endPos))

  func countSymbolRange(qv: QuadVectorView, symbol: int,
                        startPos, endPos: int64): int64 {.inline.} =
    if endPos <= startPos:
      return 0
    let repeated = mm256_set1_epi8(cast[int8](uint8(symbol * 0x55)))
    let nibbleMask = mm256_set1_epi8(0x0f'i8)
    let lookup = mm256_loadu_si256(
      cast[ptr M256i](unsafeAddr ViewQuadZeroPairNibbleLookup[0]))
    let zero = mm256_set1_epi8(0'i8)
    var accumulated = zero
    var symbolPos = startPos
    var wordIndex = int(startPos shr 5)
    while endPos - symbolPos >= 128:
      let packed = mm256_loadu_si256(
        cast[ptr M256i](unsafeAddr qv.data.data[wordIndex]))
      accumulated = mm256_add_epi64(accumulated,
        countSymbolPacked128LanesAvx2(
          packed, repeated, nibbleMask, lookup, zero))
      symbolPos += 128
      wordIndex += 4
    result = reduceFourU64Lanes(accumulated)
    result += qv.countSymbolRangeScalar(symbol, symbolPos, endPos)

  func selectSymbolRange(qv: QuadVectorView, symbol: int,
                         startPos, endPos, occurrence: int64): int64 {.inline.} =
    var wanted = occurrence
    var symbolPos = startPos
    var wordIndex = int(startPos shr 5)
    let repeated = mm256_set1_epi8(cast[int8](uint8(symbol * 0x55)))
    let nibbleMask = mm256_set1_epi8(0x0f'i8)
    let lookup = mm256_loadu_si256(
      cast[ptr M256i](unsafeAddr ViewQuadZeroPairNibbleLookup[0]))
    let zero = mm256_set1_epi8(0'i8)
    while endPos - symbolPos >= 128:
      let packed = mm256_loadu_si256(
        cast[ptr M256i](unsafeAddr qv.data.data[wordIndex]))
      let laneVector = countSymbolPacked128LanesAvx2(
        packed, repeated, nibbleMask, lookup, zero)
      var laneCounts: array[4, uint64]
      mm256_storeu_si256(cast[ptr M256i](addr laneCounts[0]), laneVector)
      let total = int64(laneCounts[0] + laneCounts[1] +
                        laneCounts[2] + laneCounts[3])
      if wanted < total:
        var localWanted = wanted
        for lane in 0..<4:
          let laneCount = int64(laneCounts[lane])
          if localWanted < laneCount:
            let matches = matchingLaneMask(
              qv.data.data[wordIndex + lane], symbol)
            let deposited = pdepU64(1'u64 shl int(localWanted), matches)
            return symbolPos + int64(lane * 32) +
              int64(countTrailingZeroBits(deposited) shr 1)
          localWanted -= laneCount
        return -1
      wanted -= total
      symbolPos += 128
      wordIndex += 4
    qv.selectSymbolRangeBmi2(symbol, symbolPos, endPos, wanted)
else:
  func countSymbolsRange(qv: QuadVectorView,
                         startPos, endPos: int64): array[4, int64] {.inline.} =
    qv.countSymbolsRangeScalar(startPos, endPos)

  func countSymbolRange(qv: QuadVectorView, symbol: int,
                        startPos, endPos: int64): int64 {.inline.} =
    qv.countSymbolRangeScalar(symbol, startPos, endPos)

  func selectSymbolRange(qv: QuadVectorView, symbol: int,
                         startPos, endPos, occurrence: int64): int64 {.inline.} =
    qv.selectSymbolRangeScalar(symbol, startPos, endPos, occurrence)

func bindSelectSamples(qv: var QuadVectorView) =
  var wordOffset = 0
  for symbol in 0..3:
    let sampleCount = ceilDivPositive(qv.totalCounts[symbol],
                                      QuadSelectSampleRate)
    let words = int(ceilDivPositive(sampleCount, 2'i64))
    if wordOffset > qv.selectStorageWords - words:
      raise newException(ValueError, "select sample backing memory is too small")
    if words == 0:
      qv.selectSamples[symbol] = emptyPackedView(ViewSelectSampleWidth)
    else:
      let memory = cast[pointer](addr qv.selectStorage[wordOffset])
      qv.selectSamples[symbol] = initPackedArrayView(
        memory, words * sizeof(uint64), sampleCount, ViewSelectSampleWidth)
    wordOffset += words
  qv.selectStorageUsedWords = wordOffset

func countAllSymbols(qv: QuadVectorView): array[4, int64] =
  if qv.lenOfSymbols <= 0:
    return
  var wordIndex = 0
  var remaining = qv.lenOfSymbols
  while remaining >= 32:
    result.addCounts(countSymbolsWord(qv.data.data[wordIndex], 32))
    inc wordIndex
    remaining -= 32
  if remaining > 0:
    result.addCounts(countSymbolsWord(qv.data.data[wordIndex], int(remaining)))

func initQuadVectorView*(memory: pointer, memorySize: int,
                         maxSymbols: int64,
                         built = false): QuadVectorView =
  ## 1つの外部連続領域から非所有QuadVector viewを作成します。
  ##
  ## `memory` は64-byte alignedである必要があります。mmapのpage-aligned addressは
  ## この条件を満たします。`built = true` ではpayloadからtotalCountsとsample
  ## descriptorを復元し、backing内の既存rank/select metadataを利用します。
  let required = requiredQuadVectorViewBytes(maxSymbols)
  if memorySize < 0 or memorySize < required:
    raise newException(ValueError, "backing memory is too small")
  if required > 0:
    if memory == nil:
      raise newException(ValueError, "backing memory must not be nil")
    if cast[uint](memory) mod uint(QuadVectorViewAlignment) != 0'u:
      raise newException(ValueError, "backing memory is not 64-byte aligned")

  result.maxOfSymbols = maxSymbols
  result.lenOfSymbols = maxSymbols
  result.superBlockCount = ceilDivPositive(maxSymbols, QuadRankSuperBlockSize)
  result.backingBytes = required

  let dataWords = payloadWords(maxSymbols)
  let dataBytes = int(dataWords * int64(sizeof(uint64)))
  if dataWords == 0:
    result.data = emptyPackedView(2)
  else:
    result.data = initPackedArrayView(memory, dataBytes, maxSymbols, 2)

  let rankOffset = int(alignUpPositive(int64(dataBytes),
                                       int64(QuadVectorViewAlignment)))
  let metadataWords = rankWords(maxSymbols)
  let metadataBytes = int(metadataWords * int64(sizeof(uint64)))
  if metadataWords == 0:
    result.rankMetadata = emptyPackedView(64)
  else:
    result.rankMetadata = initPackedArrayView(
      offsetPointer(memory, rankOffset), metadataBytes, metadataWords, 64)

  let selectOffset = rankOffset + metadataBytes
  result.selectStorageWords = int(maxSelectStorageWords(maxSymbols))
  if result.selectStorageWords > 0:
    result.selectStorage = cast[ptr UncheckedArray[uint64]](
      offsetPointer(memory, selectOffset))
  for symbol in 0..3:
    result.selectSamples[symbol] = emptyPackedView(ViewSelectSampleWidth)

  if built:
    result.totalCounts = result.countAllSymbols()
    result.bindSelectSamples()
    result.isCalced = true

func access*(qv: QuadVectorView, pos: int64): uint8 {.inline.} =
  qv.checkAccessIndex(pos)
  result = qv.symbolUnchecked(pos)

func `[]`*(qv: QuadVectorView, pos: int64): uint8 {.inline.} =
  qv.access(pos)

func setSymbol*(qv: var QuadVectorView, pos: int64, value: uint8) =
  qv.checkAccessIndex(pos)
  if value > 3'u8:
    raise newException(ValueError, "QuadVector value must be in 0..3")
  let wordIndex = int(pos shr 5)
  let shift = int((pos and 31'i64) shl 1)
  let mask = 3'u64 shl shift
  qv.data.data[wordIndex] =
    (qv.data.data[wordIndex] and not mask) or (uint64(value) shl shift)
  qv.isCalced = false

func `[]=`*(qv: var QuadVectorView, pos: int64, value: uint8) =
  qv.setSymbol(pos, value)

func clearSymbol*(qv: var QuadVectorView, pos: int64) =
  qv.setSymbol(pos, 0'u8)

func ensureRankStorage(qv: QuadVectorView) =
  let expectedWords = qv.superBlockCount * ViewRankMetadataWordsPerSuper
  if qv.rankMetadata.len != expectedWords or
      qv.rankMetadata.bitWidth != 64 or
      qv.rankMetadata.dataWords != int(expectedWords):
    raise newException(ValueError, "invalid rank metadata backing layout")

func superStartRank(qv: QuadVectorView, symbol: int,
                    superBlock: int64): int64 {.inline.} =
  if superBlock >= qv.superBlockCount:
    qv.totalCounts[symbol]
  else:
    qv.rankSuperAt(superBlock, symbol)

func build*(qv: var QuadVectorView) =
  ## 外部backing上へrank/select metadataを構築または再構築します。
  qv.ensureRankStorage()
  var absolute = [0'i64, 0'i64, 0'i64, 0'i64]

  for superBlock in 0'i64..<qv.superBlockCount:
    for symbol in 0..3:
      qv.setRankSuper(superBlock, symbol, absolute[symbol])

    var local = [0'i64, 0'i64, 0'i64, 0'i64]
    let superStart = superBlock shl ViewRankSuperBlockShift
    let superEnd = min(qv.lenOfSymbols,
                       superStart + QuadRankSuperBlockSize)
    var blockStart = superStart
    var blockIndex = 0'i64
    while blockStart < superEnd:
      if blockIndex > 0:
        for symbol in 0..3:
          qv.setRankBlock(superBlock, blockIndex, symbol, local[symbol])
      let blockEnd = min(superEnd, blockStart + QuadRankBlockSize)
      let counts = qv.countSymbolsRange(blockStart, blockEnd)
      local.addCounts(counts)
      absolute.addCounts(counts)
      inc blockIndex
      blockStart = blockEnd

  qv.totalCounts = absolute
  qv.bindSelectSamples()

  for symbol in 0..3:
    let sampleCount = qv.selectSamples[symbol].len
    if sampleCount == 0:
      continue
    var sampleIndex = 0'i64
    var targetOccurrence = 0'i64
    for superBlock in 0'i64..<qv.superBlockCount:
      let nextRank = qv.superStartRank(symbol, superBlock + 1)
      while sampleIndex < sampleCount and targetOccurrence < nextRank:
        qv.selectSamples[symbol].setUnchecked(
          int(sampleIndex), uint64(superBlock))
        inc sampleIndex
        targetOccurrence = sampleIndex * QuadSelectSampleRate

  qv.isCalced = true

func rankUnchecked*(qv: QuadVectorView, symbol: int,
                    pos: int64): int64 {.inline.} =
  if pos == qv.lenOfSymbols:
    return qv.totalCounts[symbol]
  let superBlock = pos shr ViewRankSuperBlockShift
  let offsetInSuper = pos and (QuadRankSuperBlockSize - 1'i64)
  let blockIndex = offsetInSuper shr ViewRankBlockShift
  result = qv.rankSuperAt(superBlock, symbol)
  if blockIndex > 0:
    result += qv.rankBlockAt(superBlock, blockIndex, symbol)
  let blockStart = pos and not (QuadRankBlockSize - 1'i64)
  result += qv.countSymbolRange(symbol, blockStart, pos)

func rank*(qv: QuadVectorView, symbol: int, pos: int64): int64 {.inline.} =
  checkSymbol(symbol)
  qv.checkRankPosition(pos)
  qv.requireBuilt()
  result = qv.rankUnchecked(symbol, pos)

func rankIncl*(qv: QuadVectorView, symbol: int,
               pos: int64): int64 {.inline.} =
  checkSymbol(symbol)
  qv.checkAccessIndex(pos)
  qv.requireBuilt()
  result = qv.rankUnchecked(symbol, pos + 1)

func select*(qv: QuadVectorView, symbol: int, k: int64): int64 =
  checkSymbol(symbol)
  qv.requireBuilt()
  if k < 0 or k >= qv.totalCounts[symbol]:
    return -1

  let sampleIndex = k div QuadSelectSampleRate
  let sampleBlock = int64(qv.selectSamples[symbol].getUnchecked(
    int(sampleIndex)))
  let sampleCount = qv.selectSamples[symbol].len
  var upperExclusive = qv.superBlockCount
  if sampleIndex + 1 < sampleCount:
    upperExclusive = min(upperExclusive,
      int64(qv.selectSamples[symbol].getUnchecked(
        int(sampleIndex + 1))) + 1'i64)

  var lo = sampleBlock
  var hi = upperExclusive
  while lo < hi:
    let mid = lo + ((hi - lo) shr 1)
    if qv.superStartRank(symbol, mid + 1) > k:
      hi = mid
    else:
      lo = mid + 1

  let superBlock = lo
  let superStartPos = superBlock shl ViewRankSuperBlockShift
  let superEndPos = min(qv.lenOfSymbols,
                        superStartPos + QuadRankSuperBlockSize)
  let superRank = qv.superStartRank(symbol, superBlock)
  let wantedInSuper = k - superRank
  let symbolsInSuper = superEndPos - superStartPos
  let blockCount = ceilDivPositive(symbolsInSuper, QuadRankBlockSize)

  var blockLo = 0'i64
  var blockHi = blockCount
  while blockLo + 1 < blockHi:
    let mid = blockLo + ((blockHi - blockLo) shr 1)
    let prefix = qv.rankBlockAt(superBlock, mid, symbol)
    if prefix <= wantedInSuper:
      blockLo = mid
    else:
      blockHi = mid

  let selectedBlock = blockLo
  let previous =
    if selectedBlock == 0: 0'i64
    else: qv.rankBlockAt(superBlock, selectedBlock, symbol)
  let blockStartPos = superStartPos +
    (selectedBlock shl ViewRankBlockShift)
  let blockEndPos = min(superEndPos, blockStartPos + QuadRankBlockSize)
  result = qv.selectSymbolRange(symbol, blockStartPos, blockEndPos,
                                wantedInSuper - previous)

template defineRankWrappers(name, symbolValue: untyped) =
  func name*(qv: QuadVectorView, pos: int64): int64 {.inline.} =
    qv.rank(symbolValue, pos)

template defineRankInclWrappers(name, symbolValue: untyped) =
  func name*(qv: QuadVectorView, pos: int64): int64 {.inline.} =
    qv.rankIncl(symbolValue, pos)

template defineSelectWrappers(name, symbolValue: untyped) =
  func name*(qv: QuadVectorView, k: int64): int64 {.inline.} =
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

func rawBytes*(qv: QuadVectorView): int64 =
  int64(qv.data.dataWords * sizeof(uint64))

func rankAuxiliaryBytes*(qv: QuadVectorView): int64 =
  int64(qv.rankMetadata.dataWords * sizeof(uint64))

func selectAuxiliaryBytes*(qv: QuadVectorView): int64 =
  for symbol in 0..3:
    result += int64(qv.selectSamples[symbol].dataWords * sizeof(uint64))

func auxiliaryBytes*(qv: QuadVectorView): int64 =
  qv.rankAuxiliaryBytes + qv.selectAuxiliaryBytes

func allocatedBytes*(qv: QuadVectorView): int64 =
  ## 実際にqueryで使用するpayload/rank/select領域の合計です。
  ## `backingBytes` は64-byte alignment paddingとselect worst-case予約を含みます。
  qv.rawBytes + qv.auxiliaryBytes

func `$`*(qv: QuadVectorView): string =
  result = newStringOfCap(int(min(qv.lenOfSymbols, int64(int.high))))
  for pos in 0'i64..<qv.lenOfSymbols:
    result.add char(ord('0') + int(qv.symbolUnchecked(pos)))
