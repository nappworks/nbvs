## rank/select をサポートする簡潔な Quad Vector 実装です。
##
## `QuadVector` は `0..3` のシンボルを 2-bit の `PackedArray` に格納します。
## `build` 後、rank は 4096 シンボルの superblock と、その中を 512 シンボル単位に
## 分割した block を使用します。select は各シンボルについて 1024 出現ごとに
## superblock id をサンプリングします。
##
## 補助構造の漸近的な容量増加は以下のとおりです。
##
## * rank: 2-bit payload の 6.25%
##   （各 4096-symbol superblock の rank metadata を 64-byte record にまとめ、
##    4 シンボル分の 44-bit superblock counter と、
##    4 シンボル分の 12-bit block prefix を 7 個保持）
## * select: payload の 1.5625%（1024 出現ごとに 32-bit superblock id を保持）
## * 合計: 7.8125%（object header と末尾の丸めによる増加は除く）
##
## Rank の意味は `SuccinctBitVector` と合わせています。
## `rank(symbol, pos)` は `[0, pos)` に含まれる `symbol` の個数を返します。
## Select は 0-based で、指定した出現が存在しない場合は `-1` を返します。
##
## portable backend は 64-bit SWAR mask と popcount / bit clearing を使用します。
## `-d:nbvsSimd` 指定時は block 内の rank/select と build 時の集計を
## AVX2/BMI2 実装へ切り替えます。public API、packed payload、rank/select metadata の
## 表現は両 backend で共通です。

import std/bitops
import ./packed_array

when defined(nbvsSimd):
  when defined(gcc) or defined(clang):
    # inline展開先を含む全C生成単位で命令セットを有効にする必要があります。
    {.passC: "-mavx2".}
    {.passC: "-mbmi2".}
  when defined(vcc):
    {.passC: "/arch:AVX2".}

  import ./internal/x86_intrinsics

const
  QuadRankBlockSize* = 512'i64
  QuadRankSuperBlockSize* = 4096'i64
  QuadBlocksPerSuperBlock* = 8'i64
  QuadSelectSampleRate* = 1024'i64
  MaxQuadVectorSymbols* = (1'i64 shl 43) - 1'i64

  QuadRankBlockShift = 9
  QuadRankSuperBlockShift = 12
  RankSuperCounterWidth = 44
  RankBlockCounterWidth = 12
  SelectSampleWidth = 32
  RankSuperBitsPerRecord = 4 * RankSuperCounterWidth
  RankMetadataWordsPerSuper = 8'i64
  RankMetadataBitsPerSuper = RankMetadataWordsPerSuper * 64'i64
  RankSuperCounterMask = (1'u64 shl RankSuperCounterWidth) - 1'u64
  RankBlockCounterMask = (1'u64 shl RankBlockCounterWidth) - 1'u64
  QuadLaneMask = 0x5555_5555_5555_5555'u64

when defined(nbvsSimd):
  const
    # 4-bit nibble 内に含まれる値 0 の 2-bit lane 数です。
    # packed data を対象シンボルの反復パターンと XOR すると一致 lane が 0 になるため、
    # 4 シンボルすべてを同じ lookup table で処理できます。
    QuadZeroPairNibbleLookup = [
      2'i8, 1'i8, 1'i8, 1'i8, 1'i8, 0'i8, 0'i8, 0'i8,
      1'i8, 0'i8, 0'i8, 0'i8, 1'i8, 0'i8, 0'i8, 0'i8,
      2'i8, 1'i8, 1'i8, 1'i8, 1'i8, 0'i8, 0'i8, 0'i8,
      1'i8, 0'i8, 0'i8, 0'i8, 1'i8, 0'i8, 0'i8, 0'i8
    ]

type
  QuadVector* = object
    ## 2-bit シンボルを保持する可変長ベクタです。変更後は rank/select 前に `build` が必要です。
    maxOfSymbols*: int64
    lenOfSymbols*: int64
    data*: PackedArray

    isCalced*: bool
    totalCounts*: array[4, int64]
    superBlockCount*: int64

    ## 各4096-symbol superblockのrank情報を8 word / 64 byteにまとめたPackedArrayです。
    ## record先頭に4個の44-bit絶対累積値、その後に7 block × 4 symbolの
    ## 12-bit局所累積値を保持します。
    rankMetadata*: PackedArray

    ## 後方互換のためfield名を残しています。現行実装では空で、自動生成・利用しません。
    rankSuperPrefix*: PackedArray
    rankBlockPrefix*: PackedArray

    ## 各シンボルについて 1024 出現ごとに保持する sampled superblock id です。
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

func rankSuperBitOffset(symbol: int): int {.inline.} =
  symbol * RankSuperCounterWidth

func rankBlockBitOffset(blockIndex: int64, symbol: int): int {.inline.} =
  ## `blockIndex` は 1..7 で、その block の先頭位置までの prefix を保持します。
  RankSuperBitsPerRecord +
    (int(blockIndex - 1'i64) * 4 + symbol) * RankBlockCounterWidth

func readRankField(qv: QuadVector, superBlock: int64,
                   bitOffset, width: int, mask: uint64): uint64 {.inline.} =
  ## 64-byte record内の固定幅fieldを直接読みます。PackedArrayの汎用bit-width分岐を避けます。
  let baseWord = int(superBlock * RankMetadataWordsPerSuper)
  let wordOffset = bitOffset shr 6
  let bitInWord = bitOffset and 63
  result = qv.rankMetadata.data[baseWord + wordOffset] shr bitInWord
  if bitInWord + width > 64:
    result = result or
      (qv.rankMetadata.data[baseWord + wordOffset + 1] shl (64 - bitInWord))
  result = result and mask

func writeRankField(qv: var QuadVector, superBlock: int64,
                    bitOffset, width: int, mask, value: uint64) {.inline.} =
  ## build時に64-byte record内の固定幅fieldへ直接書き込みます。
  doAssert (value and not mask) == 0'u64
  let baseWord = int(superBlock * RankMetadataWordsPerSuper)
  let wordOffset = bitOffset shr 6
  let bitInWord = bitOffset and 63
  let lowWidth = min(width, 64 - bitInWord)
  let lowValueMask = if lowWidth == 64: uint64.high else: (1'u64 shl lowWidth) - 1'u64
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

func rankSuperAt(qv: QuadVector, superBlock: int64,
                 symbol: int): int64 {.inline.} =
  int64(qv.readRankField(superBlock, rankSuperBitOffset(symbol),
                          RankSuperCounterWidth, RankSuperCounterMask))

func rankBlockAt(qv: QuadVector, superBlock, blockIndex: int64,
                 symbol: int): int64 {.inline.} =
  int64(qv.readRankField(superBlock,
                          rankBlockBitOffset(blockIndex, symbol),
                          RankBlockCounterWidth, RankBlockCounterMask))

func setRankSuper(qv: var QuadVector, superBlock: int64,
                  symbol: int, value: int64) {.inline.} =
  qv.writeRankField(superBlock, rankSuperBitOffset(symbol),
                    RankSuperCounterWidth, RankSuperCounterMask, uint64(value))

func setRankBlock(qv: var QuadVector, superBlock, blockIndex: int64,
                  symbol: int, value: int64) {.inline.} =
  qv.writeRankField(superBlock, rankBlockBitOffset(blockIndex, symbol),
                    RankBlockCounterWidth, RankBlockCounterMask, uint64(value))

func symbolUnchecked(qv: QuadVector, pos: int64): uint8 {.inline.} =
  ## 2-bit 固定幅であることを利用し、PackedArray の境界検査を省いて直接読み出します。
  let wordIndex = int(pos shr 5)
  let shift = int((pos and 31'i64) shl 1)
  uint8((qv.data.data[wordIndex] shr shift) and 3'u64)

func matchingLaneMask(word: uint64, symbol: int): uint64 {.inline.} =
  ## 一致した 2-bit lane ごとに bit 0,2,...,62 の位置へ 1 を立てます。
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

func addCounts(target: var array[4, int64], source: array[4, int64]) {.inline.} =
  for symbol in 0..3:
    target[symbol] += source[symbol]

func countSymbolsWord(word: uint64, symbolCount: int): array[4, int64] {.inline.} =
  ## 1つの 64-bit word に packed された最大32シンボルを3回のpopcountで4値集計します。
  let valid = validLaneMask(symbolCount)
  let low = word and valid
  let high = (word shr 1) and valid
  let both = low and high

  result[3] = int64(countSetBits(both))
  result[1] = int64(countSetBits(low and not high))
  result[2] = int64(countSetBits(high and not low))
  result[0] = int64(symbolCount) - result[1] - result[2] - result[3]

func countSymbolsRangeScalar(qv: QuadVector,
                             startPos, endPos: int64): array[4, int64] {.inline.} =
  ## build 用に4シンボルを同時集計します。`startPos` は word 境界に揃っている必要があります。
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

func countSymbolRangeScalar(qv: QuadVector, symbol: int,
                            startPos, endPos: int64): int64 {.inline.} =
  ## portable な SWAR/popcount 実装です。`startPos` は word 境界に揃っている必要があります。
  if endPos <= startPos:
    return 0

  var wordIndex = int(startPos shr 5)
  var remaining = endPos - startPos
  while remaining >= 32:
    result += int64(countSetBits(
      matchingLaneMask(qv.data.data[wordIndex], symbol)))
    inc wordIndex
    remaining -= 32

  if remaining > 0:
    let mask = matchingLaneMask(qv.data.data[wordIndex], symbol) and
      validLaneMask(int(remaining))
    result += int64(countSetBits(mask))

func selectSymbolRangeScalar(qv: QuadVector, symbol: int,
                             startPos, endPos, occurrence: int64): int64 {.inline, used.} =
  ## SWAR の一致 mask と bit clearing を使う portable な word scan です。
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
    ## 128 packed symbolを4つの64-bit wordごとの一致数へ変換します。
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
    ## すでにload済みの128 packed symbolから対象シンボル数を数えます。
    let repeated = mm256_set1_epi8(cast[int8](uint8(symbol * 0x55)))
    result = reduceFourU64Lanes(countSymbolPacked128LanesAvx2(
      packed, repeated, nibbleMask, lookup, zero))

  func countSymbols128Avx2(qv: QuadVector,
                           wordIndex: int): array[4, int64] {.inline.} =
    ## build 用に1回の256-bit loadから4シンボルをまとめて集計します。
    ## lookup/maskを3シンボルで共有し、0は全128から差し引いて求めます。
    let packed = mm256_loadu_si256(
      cast[ptr M256i](unsafeAddr qv.data.data[wordIndex]))
    let nibbleMask = mm256_set1_epi8(0x0f'i8)
    let lookup = mm256_loadu_si256(
      cast[ptr M256i](unsafeAddr QuadZeroPairNibbleLookup[0]))
    let zero = mm256_set1_epi8(0'i8)
    result[1] = countSymbolPacked128Avx2(packed, 1, nibbleMask, lookup, zero)
    result[2] = countSymbolPacked128Avx2(packed, 2, nibbleMask, lookup, zero)
    result[3] = countSymbolPacked128Avx2(packed, 3, nibbleMask, lookup, zero)
    result[0] = 128'i64 - result[1] - result[2] - result[3]

  func selectSymbolRangeBmi2(qv: QuadVector, symbol: int,
                             startPos, endPos, occurrence: int64): int64 {.inline.} =
    ## 短いtailを64-bit word単位で走査し、BMI2 PDEPで対象laneを選択します。
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

  func countSymbolsRange(qv: QuadVector,
                         startPos, endPos: int64): array[4, int64] {.inline.} =
    ## AVX2 で128シンボルずつ4値集計し、最後の短いtailだけscalarで処理します。
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

  func countSymbolRange(qv: QuadVector, symbol: int,
                        startPos, endPos: int64): int64 {.inline.} =
    ## 128-symbol chunkの64-bit lane countをvector accumulatorへ加算し、
    ## stackへのstore/horizontal reductionは最後の1回だけ行います。
    if endPos <= startPos:
      return 0

    let repeated = mm256_set1_epi8(cast[int8](uint8(symbol * 0x55)))
    let nibbleMask = mm256_set1_epi8(0x0f'i8)
    let lookup = mm256_loadu_si256(
      cast[ptr M256i](unsafeAddr QuadZeroPairNibbleLookup[0]))
    let zero = mm256_set1_epi8(0'i8)
    var accumulated = zero
    var symbolPos = startPos
    var wordIndex = int(startPos shr 5)

    while endPos - symbolPos >= 128:
      let packed = mm256_loadu_si256(
        cast[ptr M256i](unsafeAddr qv.data.data[wordIndex]))
      accumulated = mm256_add_epi64(accumulated,
        countSymbolPacked128LanesAvx2(packed, repeated, nibbleMask, lookup, zero))
      symbolPos += 128
      wordIndex += 4

    result = reduceFourU64Lanes(accumulated)
    result += qv.countSymbolRangeScalar(symbol, symbolPos, endPos)

  func selectSymbolRange(qv: QuadVector, symbol: int,
                         startPos, endPos, occurrence: int64): int64 {.inline.} =
    ## AVX2で128-symbol chunkを数え、命中chunkでは同じ4 wordを再走査せず、
    ## SADで得たword別countから対象wordを選んでBMI2 PDEPを1回だけ適用します。
    var wanted = occurrence
    var symbolPos = startPos
    var wordIndex = int(startPos shr 5)
    let repeated = mm256_set1_epi8(cast[int8](uint8(symbol * 0x55)))
    let nibbleMask = mm256_set1_epi8(0x0f'i8)
    let lookup = mm256_loadu_si256(
      cast[ptr M256i](unsafeAddr QuadZeroPairNibbleLookup[0]))
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
            let matches = matchingLaneMask(qv.data.data[wordIndex + lane], symbol)
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
  func countSymbolsRange(qv: QuadVector,
                         startPos, endPos: int64): array[4, int64] {.inline.} =
    qv.countSymbolsRangeScalar(startPos, endPos)

  func countSymbolRange(qv: QuadVector, symbol: int,
                        startPos, endPos: int64): int64 {.inline.} =
    qv.countSymbolRangeScalar(symbol, startPos, endPos)

  func selectSymbolRange(qv: QuadVector, symbol: int,
                         startPos, endPos, occurrence: int64): int64 {.inline.} =
    qv.selectSymbolRangeScalar(symbol, startPos, endPos, occurrence)

func genQuadVector*(maxSymbols: int64): QuadVector =
  ## `maxSymbols` 個のシンボルを 0 で初期化した可変 QuadVector を作成します。
  if maxSymbols < 0:
    raise newException(ValueError, "maxSymbols must be non-negative")
  if maxSymbols > MaxQuadVectorSymbols:
    raise newException(ValueError, "maxSymbols exceeds QuadVector limit")

  result.maxOfSymbols = maxSymbols
  result.lenOfSymbols = maxSymbols
  result.data = genPackedArray(maxSymbols, 2)
  result.superBlockCount = ceilDivPositive(maxSymbols, QuadRankSuperBlockSize)
  result.rankMetadata = genPackedArray(
    result.superBlockCount * RankMetadataWordsPerSuper, 64)
  # 旧fieldは互換用に残すだけで、現行metadata容量には含めません。
  result.rankSuperPrefix = genPackedArray(0, RankSuperCounterWidth)
  result.rankBlockPrefix = genPackedArray(0, RankBlockCounterWidth)
  for symbol in 0..3:
    result.selectSamples[symbol] = genPackedArray(0, SelectSampleWidth)

func access*(qv: QuadVector, pos: int64): uint8 {.inline.} =
  ## `pos` に格納されているシンボルを返します。
  qv.checkAccessIndex(pos)
  result = qv.symbolUnchecked(pos)

func `[]`*(qv: QuadVector, pos: int64): uint8 {.inline.} =
  ## `access` の別名です。
  qv.access(pos)

func setSymbol*(qv: var QuadVector, pos: int64, value: uint8) =
  ## `pos` に `0..3` のシンボルを格納し、rank/select metadata を無効化します。
  qv.checkAccessIndex(pos)
  if value > 3'u8:
    raise newException(ValueError, "QuadVector value must be in 0..3")

  let wordIndex = int(pos shr 5)
  let shift = int((pos and 31'i64) shl 1)
  let mask = 3'u64 shl shift
  qv.data.data[wordIndex] =
    (qv.data.data[wordIndex] and not mask) or (uint64(value) shl shift)
  qv.isCalced = false

func `[]=`*(qv: var QuadVector, pos: int64, value: uint8) =
  ## `setSymbol` の別名です。
  qv.setSymbol(pos, value)

func clearSymbol*(qv: var QuadVector, pos: int64) =
  ## `pos` のシンボルを 0 に設定し、rank/select metadata を無効化します。
  qv.setSymbol(pos, 0'u8)

func ensureRankStorage(qv: var QuadVector) =
  ## vector長が不変な通常のrebuildでは64-byte metadata recordを再利用します。
  let metadataWords = qv.superBlockCount * RankMetadataWordsPerSuper
  if qv.rankMetadata.len != metadataWords or qv.rankMetadata.bitWidth != 64:
    qv.rankMetadata = genPackedArray(metadataWords, 64)

func ensureSelectStorage(qv: var QuadVector, symbol: int, sampleCount: int64) =
  ## 出現数が同じrebuildではselect sampleの既存storageを再利用します。
  if qv.selectSamples[symbol].len != sampleCount:
    qv.selectSamples[symbol] = genPackedArray(sampleCount, SelectSampleWidth)

func superStartRank(qv: QuadVector, symbol: int,
                    superBlock: int64): int64 {.inline.} =
  if superBlock >= qv.superBlockCount:
    qv.totalCounts[symbol]
  else:
    qv.rankSuperAt(superBlock, symbol)

func build*(qv: var QuadVector) =
  ## packed rank/select dictionaryを構築または再構築します。
  ##
  ## raw payloadは512-symbol block単位で1回だけ走査します。各blockで4シンボルを
  ## 同時集計し、rank metadataと総出現数を同じpassで構築します。select sampleは
  ## その後にsuperblock累積値だけを走査して生成するため、payloadを2回読みません。
  qv.ensureRankStorage()

  var absolute = [0'i64, 0'i64, 0'i64, 0'i64]

  for superBlock in 0'i64..<qv.superBlockCount:
    for symbol in 0..3:
      qv.setRankSuper(superBlock, symbol, absolute[symbol])

    var local = [0'i64, 0'i64, 0'i64, 0'i64]
    let superStart = superBlock shl QuadRankSuperBlockShift
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

  # sample k は「k*1024番目の出現を含むsuperblock」を指します。
  # superblock prefixだけを前向きに走査し、raw payloadの再走査を避けます。
  for symbol in 0..3:
    let sampleCount = ceilDivPositive(qv.totalCounts[symbol],
                                      QuadSelectSampleRate)
    qv.ensureSelectStorage(symbol, sampleCount)
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

func rankUnchecked*(qv: QuadVector, symbol: int, pos: int64): int64 {.inline.} =
  ## 境界検査を行わない rank です。
  ## metadata が build 済みで、`symbol in 0..3` かつ `0 <= pos <= len` である必要があります。
  if pos == qv.lenOfSymbols:
    return qv.totalCounts[symbol]

  let superBlock = pos shr QuadRankSuperBlockShift
  let offsetInSuper = pos and (QuadRankSuperBlockSize - 1'i64)
  let blockIndex = offsetInSuper shr QuadRankBlockShift

  result = qv.rankSuperAt(superBlock, symbol)
  if blockIndex > 0:
    result += qv.rankBlockAt(superBlock, blockIndex, symbol)

  let blockStart = pos and not (QuadRankBlockSize - 1'i64)
  result += qv.countSymbolRange(symbol, blockStart, pos)

func rank*(qv: QuadVector, symbol: int, pos: int64): int64 {.inline.} =
  ## `[0, pos)` に含まれる `symbol` の個数を返します。
  checkSymbol(symbol)
  qv.checkRankPosition(pos)
  qv.requireBuilt()
  result = qv.rankUnchecked(symbol, pos)

func rankIncl*(qv: QuadVector, symbol: int, pos: int64): int64 {.inline.} =
  ## `[0, pos]` に含まれる `symbol` の個数を返します。
  checkSymbol(symbol)
  qv.checkAccessIndex(pos)
  qv.requireBuilt()
  result = qv.rankUnchecked(symbol, pos + 1)

func select*(qv: QuadVector, symbol: int, k: int64): int64 =
  ## 0-basedで`k`番目に出現する`symbol`の位置を返します。存在しない場合は`-1`です。
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
      int64(qv.selectSamples[symbol].getUnchecked(int(sampleIndex + 1))) + 1'i64)

  # sampleが示す範囲内だけを二分探索します。uniform分布では通常ごく狭い範囲です。
  var lo = sampleBlock
  var hi = upperExclusive
  while lo < hi:
    let mid = lo + ((hi - lo) shr 1)
    if qv.superStartRank(symbol, mid + 1) > k:
      hi = mid
    else:
      lo = mid + 1

  let superBlock = lo
  let superStartPos = superBlock shl QuadRankSuperBlockShift
  let superEndPos = min(qv.lenOfSymbols,
                        superStartPos + QuadRankSuperBlockSize)
  let superRank = qv.superStartRank(symbol, superBlock)
  let wantedInSuper = k - superRank
  let symbolsInSuper = superEndPos - superStartPos
  let blockCount = ceilDivPositive(symbolsInSuper, QuadRankBlockSize)

  # 512-symbol blockもprefixに対するupper-boundで選び、最大8 blockの線形走査を避けます。
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
    if selectedBlock == 0:
      0'i64
    else:
      qv.rankBlockAt(superBlock, selectedBlock, symbol)
  let blockStartPos = superStartPos + (selectedBlock shl QuadRankBlockShift)
  let blockEndPos = min(superEndPos, blockStartPos + QuadRankBlockSize)
  result = qv.selectSymbolRange(symbol, blockStartPos, blockEndPos,
                                wantedInSuper - previous)

template defineRankWrappers(name, symbolValue: untyped) =
  func name*(qv: QuadVector, pos: int64): int64 {.inline.} =
    qv.rank(symbolValue, pos)

template defineRankInclWrappers(name, symbolValue: untyped) =
  func name*(qv: QuadVector, pos: int64): int64 {.inline.} =
    qv.rankIncl(symbolValue, pos)

template defineSelectWrappers(name, symbolValue: untyped) =
  func name*(qv: QuadVector, k: int64): int64 {.inline.} =
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
  ## 2-bit payload storage に確保されている byte 数を返します。
  int64(qv.data.data.len * sizeof(uint64))

func rankAuxiliaryBytes*(qv: QuadVector): int64 =
  ## rank dictionary に確保されている byte 数を返します。
  int64(qv.rankMetadata.data.len * sizeof(uint64))

func selectAuxiliaryBytes*(qv: QuadVector): int64 =
  ## select sample に確保されている byte 数を返します。
  for symbol in 0..3:
    result += int64(qv.selectSamples[symbol].data.len * sizeof(uint64))

func auxiliaryBytes*(qv: QuadVector): int64 =
  qv.rankAuxiliaryBytes + qv.selectAuxiliaryBytes

func allocatedBytes*(qv: QuadVector): int64 =
  ## Nim object/seq header を除いた packed storage の確保 byte 数を返します。
  qv.rawBytes + qv.auxiliaryBytes

func `$`*(qv: QuadVector): string =
  ## シンボル列を `0`..`3` の数字からなる文字列として返します。
  result = newStringOfCap(int(min(qv.lenOfSymbols, int64(int.high))))
  for pos in 0'i64..<qv.lenOfSymbols:
    result.add char(ord('0') + int(qv.symbolUnchecked(pos)))
