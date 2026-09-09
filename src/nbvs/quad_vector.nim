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
##   （各 4096-symbol superblock に 44-bit superblock counter と、
##    4 シンボル分の 12-bit block prefix を 7 個保持）
## * select: payload の 1.5625%（1024 出現ごとに 32-bit superblock id を保持）
## * 合計: 7.8125%（object header と末尾の丸めによる増加は除く）
##
## Rank の意味は `SuccinctBitVector` と合わせています。
## `rank(symbol, pos)` は `[0, pos)` に含まれる `symbol` の個数を返します。
## Select は 0-based で、指定した出現が存在しない場合は `-1` を返します。
##
## portable backend は 64-bit SWAR mask と popcount / bit clearing を使用します。
## `-d:nbvsSimd` 指定時は block 内の rank/select を AVX2/BMI2 実装へ切り替えます。
## public API、packed payload、rank/select metadata の表現は両 backend で共通です。

import std/bitops
import ./packed_array

when defined(nbvsSimd):
  when defined(gcc) or defined(clang):
    {.localPassc: "-mavx2".}
    {.localPassc: "-mbmi2".}
  when defined(vcc):
    {.localPassc: "/arch:AVX2".}

  import ./internal/x86_intrinsics

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

when defined(nbvsSimd):
  const
    # 4-bit nibble 内に含まれる値 0 の 2-bit lane 数です。
    # packed data を対象シンボルの反復パターンと XOR すると、一致 lane が 0 になるため、
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

    ## 各 4096-symbol superblock の先頭時点における 4 個の 44-bit 絶対累積値です。
    rankSuperPrefix*: PackedArray
    ## 各 superblock 内で、先頭 block を除く 7 block × 4 symbol の 12-bit 局所累積値です。
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

func rankSuperIndex(superBlock, symbol: int64): int64 {.inline.} =
  superBlock * 4'i64 + symbol

func rankBlockIndex(superBlock, block, symbol: int64): int64 {.inline.} =
  ## `block` は 1..7 で、その block の先頭位置までの prefix を保持します。
  superBlock * RankBlockPrefixesPerSuper + (block - 1'i64) * 4'i64 + symbol

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
                             startPos, endPos, occurrence: int64): int64 {.inline.} =
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
  func countSymbol128Avx2(qv: QuadVector, symbol, wordIndex: int): int64 {.inline.} =
    ## AVX2 を使い、packed された 128 シンボル（32 byte）内の対象シンボル数を数えます。
    let packed = mm256_loadu_si256(
      cast[ptr M256i](unsafeAddr qv.data.data[wordIndex]))
    let repeated = cast[int8](uint8(symbol * 0x55))
    let normalized = mm256_xor_si256(packed, mm256_set1_epi8(repeated))
    let nibbleMask = mm256_set1_epi8(0x0f'i8)
    let lookup = mm256_loadu_si256(
      cast[ptr M256i](unsafeAddr QuadZeroPairNibbleLookup[0]))

    let lo = mm256_and_si256(normalized, nibbleMask)
    let hi = mm256_and_si256(mm256_srli_epi16(normalized, 4), nibbleMask)
    let loCounts = mm256_shuffle_epi8(lookup, lo)
    let hiCounts = mm256_shuffle_epi8(lookup, hi)
    let byteCounts = mm256_add_epi8(loCounts, hiCounts)
    let sums = mm256_sad_epu8(byteCounts, mm256_set1_epi8(0'i8))

    var laneSums: array[4, uint64]
    mm256_storeu_si256(cast[ptr M256i](addr laneSums[0]), sums)
    result = int64(laneSums[0] + laneSums[1] + laneSums[2] + laneSums[3])

  func selectSymbolRangeBmi2(qv: QuadVector, symbol: int,
                             startPos, endPos, occurrence: int64): int64 {.inline.} =
    ## AVX2 で探索範囲を狭めた後、BMI2 を使って対象 occurrence の位置を求めます。
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

  func countSymbolRange(qv: QuadVector, symbol: int,
                        startPos, endPos: int64): int64 {.inline.} =
    ## AVX2 で 128 シンボルずつ走査し、最後の短い tail は scalar SWAR で処理します。
    if endPos <= startPos:
      return 0

    var wordPos = startPos
    var wordIndex = int(startPos shr 5)
    while endPos - wordPos >= 128:
      result += qv.countSymbol128Avx2(symbol, wordIndex)
      wordPos += 128
      wordIndex += 4

    result += qv.countSymbolRangeScalar(symbol, wordPos, endPos)

  func selectSymbolRange(qv: QuadVector, symbol: int,
                         startPos, endPos, occurrence: int64): int64 {.inline.} =
    ## AVX2 で 128-symbol chunk を飛ばし、最後の一致 lane を BMI2 PDEP で選択します。
    var wanted = occurrence
    var wordPos = startPos
    var wordIndex = int(startPos shr 5)

    while endPos - wordPos >= 128:
      let count = qv.countSymbol128Avx2(symbol, wordIndex)
      if wanted < count:
        return qv.selectSymbolRangeBmi2(symbol, wordPos, wordPos + 128, wanted)
      wanted -= count
      wordPos += 128
      wordIndex += 4

    qv.selectSymbolRangeBmi2(symbol, wordPos, endPos, wanted)
else:
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
  result.rankSuperPrefix = genPackedArray(result.superBlockCount * 4'i64,
                                           RankSuperCounterWidth)
  result.rankBlockPrefix = genPackedArray(
    result.superBlockCount * RankBlockPrefixesPerSuper,
    RankBlockCounterWidth)
  for symbol in 0..3:
    result.selectSamples[symbol] = genPackedArray(0, SelectSampleWidth)

func access*(qv: QuadVector, pos: int64): uint8 =
  ## `pos` に格納されているシンボルを返します。
  qv.checkAccessIndex(pos)
  result = uint8(qv.data[pos])

func `[]`*(qv: QuadVector, pos: int64): uint8 =
  ## `access` の別名です。
  qv.access(pos)

func setSymbol*(qv: var QuadVector, pos: int64, value: uint8) =
  ## `pos` に `0..3` のシンボルを格納し、rank/select metadata を無効化します。
  qv.checkAccessIndex(pos)
  if value > 3'u8:
    raise newException(ValueError, "QuadVector value must be in 0..3")
  qv.data[pos] = uint64(value)
  qv.isCalced = false

func `[]=`*(qv: var QuadVector, pos: int64, value: uint8) =
  ## `setSymbol` の別名です。
  qv.setSymbol(pos, value)

func clearSymbol*(qv: var QuadVector, pos: int64) =
  ## `pos` のシンボルを 0 に設定し、rank/select metadata を無効化します。
  qv.setSymbol(pos, 0'u8)

func build*(qv: var QuadVector) =
  ## scalar/SIMD backend で共通の packed rank/select dictionary を構築または再構築します。
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
  ## 境界検査を行わない rank です。
  ## metadata が build 済みで、`symbol in 0..3` かつ `0 <= pos <= len` である必要があります。
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
  ## `[0, pos)` に含まれる `symbol` の個数を返します。
  checkSymbol(symbol)
  qv.checkRankPosition(pos)
  qv.requireBuilt()
  result = qv.rankUnchecked(symbol, pos)

func rankIncl*(qv: QuadVector, symbol: int, pos: int64): int64 =
  ## `[0, pos]` に含まれる `symbol` の個数を返します。
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
  ## 0-based で `k` 番目に出現する `symbol` の位置を返します。存在しない場合は `-1` です。
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
  ## 2-bit payload storage に確保されている byte 数を返します。
  int64(qv.data.data.len * sizeof(uint64))

func rankAuxiliaryBytes*(qv: QuadVector): int64 =
  ## rank dictionary に確保されている byte 数を返します。
  int64((qv.rankSuperPrefix.data.len + qv.rankBlockPrefix.data.len) *
        sizeof(uint64))

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
    result.add char(ord('0') + int(qv.data[pos]))
