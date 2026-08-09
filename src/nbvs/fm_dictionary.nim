## BWTとWavelet Matrixを使用するself-index型文字列Dictionary。
##
## 文字列はUTF-8 byte列として処理され、入力順がDictionary IDになります。

import std/[algorithm, bitops, sets]
import bit_vector, packed_array, succinct_bit_vector, succinct_radix_trie,
  wavelet_matrix, run_length_bwt
import internal/[fm_symbols, suffix_array]

export fm_symbols
export succinct_radix_trie

type
  DictionaryId* = uint32
    ## FmDictionary内の文字列を入力順で識別するIDです。

  FmBackendPreference* = enum
    ## FM-indexのBWT表現を指定します。
    fbpAuto, fbpWavelet, fbpRunLength

  FmBackendKind* = enum
    ## 構築済みFmDictionaryが使用するBWT表現です。
    fbWavelet, fbRunLength

  FmInterval* = object
    ## FM-index検索結果の半開区間を表します。
    left*: int64
    right*: int64

  FmDictionaryBuildOptions* = object
    ## FmDictionaryの構築方法を指定します。
    validateDistinct*: bool ## 入力文字列の重複を構築前に検査します。
    fmBackend*: FmBackendPreference ## BWT表現。Autoは推定容量から選択します。

  FmDictionaryStats* = object
    ## BWTの圧縮性と選択済みFM backendの統計です。
    fmBackendKind*: FmBackendKind
    bwtLength*, runCount*: int64
    runRatio*, averageRunLength*: float
    maximumRunLength*: int64
    estimatedWaveletBytes*, estimatedRleBytes*: int64
    actualWaveletBytes*, actualRleBytes*: int64
    waveletEstimateErrorRatio*, rleEstimateErrorRatio*: float

  FmDictionaryMemoryUsage* = object
    ## FmDictionaryの論理的な格納容量内訳をbyte単位で表します。
    radixTrieBytes*: int64
    fmBackendKind*: FmBackendKind
    fmTotalBytes*, bwtBytes*: int64
    runSymbolsBytes*, runBoundaryBytes*, runPrefixBytes*: int64
    cTableBytes*, anchorBytes*, totalBytes*: int64

  FmDictionary* = object
    ## FM-indexとRadix Trieを組み合わせて検索と復元を提供するDictionaryです。
    bwt*: WaveletMatrix ## BWT symbol列を保持する固定9-bit Wavelet Matrix。
    runLengthBwt*: RunLengthBwt ## RLE選択時のBWT。Wavelet選択時は空です。
    backendKind*: FmBackendKind ## 実際に選択されたBWT表現。
    bwtRunCount*: uint32 ## BWTのrun数。
    maximumBwtRunLength*: uint32 ## BWTの最大run長。
    estimatedWaveletBytes*: uint64 ## 構築前に推定したWavelet容量。
    estimatedRunLengthBytes*: uint64 ## 構築前に推定したRLE容量。
    cTable*: PackedArray            ## symbol未満の総出現数を保持するC table。
    startAnchorToEncodedId*: PackedArray ## 開始anchorからencoded IDを得る配列。
    dictionaryIdToEndAnchor*: PackedArray ## IDから終了anchor ordinalを得る配列。
    dictionaryCount*: uint32        ## Dictionaryのエントリ数。
    maxEncodedStringLength*: uint32 ## 最大文字列長（UTF-8 byte数）。
    radixTrie*: SuccinctRadixTrie   ## exact、prefix、ID復元用の補助索引。

  FmQueryWorkspace* = object
    ## substring検索の集約領域をクエリ間で再利用します。
    counts: seq[uint32]
    generations: seq[uint32]
    currentGeneration: uint32
    touchedIds: seq[DictionaryId]

  LfStepResult = object
    symbol: FmSymbol
    nextRow: int64

const DefaultFmDictionaryBuildOptions* =
  FmDictionaryBuildOptions(validateDistinct: true, fmBackend: fbpAuto)
  ## 後方互換な既定の構築オプションです。

func requiredBitWidth(maximum: uint64): int {.inline.} =
  if maximum == 0: 0 else: 64 - countLeadingZeroBits(maximum)

func estimateWaveletMatrixBytes(length: int64): int64 =
  int64(SymbolBitWidth) * estimateSuccinctBitVectorBytes(length) +
    int64(SymbolBitWidth * sizeof(int64))

func succinctBytes(bits: SuccinctBitVector): int64

func bwtLength(dict: FmDictionary): int64 {.inline.} =
  if dict.backendKind == fbRunLength: dict.runLengthBwt.n else: dict.bwt.n

func bwtRankPair(dict: FmDictionary, symbol: FmSymbol, left,
                 right: int64): tuple[leftRank, rightRank: int64] {.inline.} =
  if dict.backendKind == fbRunLength:
    dict.runLengthBwt.rankPair(symbol, left, right)
  else:
    dict.bwt.rankPair(uint64(symbol), left, right)

func bwtAccessRank(dict: FmDictionary,
                   position: int64): tuple[value: uint64,
                     rankBefore: int64] {.inline.} =
  if dict.backendKind == fbRunLength:
    dict.runLengthBwt.accessRank(position)
  else:
    dict.bwt.accessRank(position)

func bwtSelect(dict: FmDictionary, symbol: FmSymbol,
               ordinal: int64): int64 {.inline.} =
  if dict.backendKind == fbRunLength:
    dict.runLengthBwt.select(symbol, ordinal)
  else:
    dict.bwt.select(uint64(symbol), ordinal)

proc genFmDictionary*(strings: openArray[string],
                      options = DefaultFmDictionaryBuildOptions): FmDictionary =
  ## distinctな文字列集合からFmDictionaryを構築します。
  ##
  ## `validateDistinct`が有効な場合の重複入力、または件数・連結symbol列長が
  ## `uint32`の範囲を超える場合は`ValueError`が発生します。
  ## SA-ISによる構築時間は`O(n)`、構築時の追加領域は`O(n)`です。
  if uint64(strings.len) > uint64(uint32.high):
    raise newException(ValueError, "dictionary count exceeds uint32 limit")

  var seen = initHashSet[string]()
  var totalLength = 2'u64
  for value in strings:
    if options.validateDistinct:
      if value in seen:
        raise newException(ValueError, "duplicate dictionary string")
      seen.incl value
    totalLength += uint64(value.len) + 1'u64
    if totalLength > uint64(uint32.high):
      raise newException(ValueError, "concatenated symbols exceed uint32 limit")
    result.maxEncodedStringLength =
      max(result.maxEncodedStringLength, uint32(value.len))
  seen = default(HashSet[string])

  result.dictionaryCount = uint32(strings.len)
  result.radixTrie = genSuccinctRadixTrie(strings)
  let symbolCount = int(totalLength)
  var symbols = newSeq[FmSymbol](symbolCount)
  var separatorPositions = genSuccinctBitVector(int64(symbolCount))
  var position = 0
  symbols[position] = SeparatorSymbol
  separatorPositions.setBit(int64(position))
  inc position
  for value in strings:
    for character in value:
      symbols[position] = encodeByte(byte(character))
      inc position
    symbols[position] = SeparatorSymbol
    separatorPositions.setBit(int64(position))
    inc position
  symbols[position] = EndSymbol
  inc position
  doAssert position == symbolCount
  separatorPositions.build()

  var suffixArray = buildSuffixArray(symbols)
  var bwtSymbols = newSeq[FmSymbol](symbolCount)
  var counts: array[AlphabetSize, uint64]
  var previousBwtSymbol = FmSymbol.high
  var currentRunLength = 0'u32
  for row, suffixStartValue in suffixArray:
    let suffixStart = int(suffixStartValue)
    let previous = if suffixStart == 0: symbols.high else: suffixStart - 1
    let symbol = symbols[previous]
    bwtSymbols[row] = symbol
    inc counts[int(symbol)]
    if row == 0 or symbol != previousBwtSymbol:
      inc result.bwtRunCount
      currentRunLength = 1
      previousBwtSymbol = symbol
    else:
      inc currentRunLength
    result.maximumBwtRunLength = max(result.maximumBwtRunLength,
      currentRunLength)
  if counts[int(EndSymbol)] != 1:
    raise newException(ValueError, "BWT must contain exactly one end symbol")

  result.cTable = genPackedArray(AlphabetSize,
    requiredBitWidth(uint64(symbolCount)))
  var cumulative = 0'u64
  for symbol in 0..<AlphabetSize:
    result.cTable[symbol] = cumulative
    cumulative += counts[symbol]

  let separatorCount = strings.len + 1
  result.startAnchorToEncodedId = genPackedArray(int64(separatorCount),
    requiredBitWidth(uint64(strings.len)))
  result.dictionaryIdToEndAnchor = genPackedArray(int64(strings.len),
    requiredBitWidth(uint64(separatorCount - 1)))
  var endAnchorSet = genBitVector(strings.len)
  var separatorOrdinal = 0
  for row, symbol in bwtSymbols:
    if symbol != SeparatorSymbol:
      continue
    let suffixStart = int(suffixArray[row])
    let originalPosition = if suffixStart == 0: symbols.high else: suffixStart - 1
    let separatorIndex =
      int(separatorPositions.rank1(int64(originalPosition)))
    if separatorIndex < strings.len:
      result.startAnchorToEncodedId[separatorOrdinal] =
        uint64(separatorIndex + 1)
    if separatorIndex > 0:
      let endId = separatorIndex - 1
      result.dictionaryIdToEndAnchor[endId] = uint64(separatorOrdinal)
      endAnchorSet.setBit(endId)
    inc separatorOrdinal
  if separatorOrdinal != separatorCount:
    raise newException(ValueError, "invalid separator count in BWT")
  for dictionaryId in 0..<strings.len:
    if not endAnchorSet[dictionaryId]:
      raise newException(ValueError, "incomplete dictionary end anchors")

  endAnchorSet = default(BitVector)
  symbols = @[]
  suffixArray = @[]
  separatorPositions = default(SuccinctBitVector)
  # 推定値だけで選択し、完成後に両表現を保持しない。
  let n = uint64(symbolCount)
  let runs = uint64(result.bwtRunCount)
  result.estimatedWaveletBytes = uint64(estimateWaveletMatrixBytes(
    int64(n)))
  result.estimatedRunLengthBytes = uint64(estimatedMemoryUsage(
    int64(n), int64(runs)))
  let useRunLength = case options.fmBackend
    of fbpWavelet: false
    of fbpRunLength: true
    of fbpAuto:
      result.estimatedRunLengthBytes * 100 <=
        result.estimatedWaveletBytes * 85 and runs * 5 <= n
  if useRunLength:
    result.backendKind = fbRunLength
    result.runLengthBwt = genRunLengthBwt(bwtSymbols)
  else:
    result.backendKind = fbWavelet
    result.bwt = genWaveletMatrix(bwtSymbols, SymbolBitWidth)

func len*(dict: FmDictionary): int {.inline.} =
  ## Dictionaryのエントリ数を返します。
  int(dict.dictionaryCount)

func stats*(dict: FmDictionary): FmDictionaryStats =
  ## 選択済みbackendとBWT run統計を返します。
  result.fmBackendKind = dict.backendKind
  result.bwtLength = dict.bwtLength
  result.runCount = int64(dict.bwtRunCount)
  if result.bwtLength > 0:
    result.runRatio = result.runCount.float / result.bwtLength.float
  if result.runCount > 0:
    result.averageRunLength = result.bwtLength.float / result.runCount.float
  result.maximumRunLength = int64(dict.maximumBwtRunLength)
  result.estimatedWaveletBytes = int64(dict.estimatedWaveletBytes)
  result.estimatedRleBytes = int64(dict.estimatedRunLengthBytes)
  if dict.backendKind == fbWavelet:
    for level in dict.bwt.levels:
      result.actualWaveletBytes += succinctBytes(level)
    result.actualWaveletBytes += int64(dict.bwt.zeroCounts.len * sizeof(int64))
    if result.estimatedWaveletBytes > 0:
      result.waveletEstimateErrorRatio = result.actualWaveletBytes.float /
        result.estimatedWaveletBytes.float
  else:
    result.actualRleBytes = dict.runLengthBwt.memoryUsage
    if result.estimatedRleBytes > 0:
      result.rleEstimateErrorRatio = result.actualRleBytes.float /
        result.estimatedRleBytes.float

func succinctBytes(bits: SuccinctBitVector): int64 =
  int64(bits.data.len * sizeof(uint64) +
    bits.blockPairPrefix.len * sizeof(uint32) +
    bits.wordPairPrefix.len * sizeof(uint32) +
    bits.selectStorage.len * sizeof(uint64))

func memoryUsage*(dict: FmDictionary): FmDictionaryMemoryUsage =
  ## Trie、FM backend、anchorを含む論理的な格納容量を返します。
  result.fmBackendKind = dict.backendKind
  result.radixTrieBytes = dict.radixTrie.memoryUsage.totalBytes
  result.cTableBytes = int64(dict.cTable.data.len * sizeof(uint64))
  result.anchorBytes = int64((dict.startAnchorToEncodedId.data.len +
    dict.dictionaryIdToEndAnchor.data.len) * sizeof(uint64))
  if dict.backendKind == fbWavelet:
    for level in dict.bwt.levels:
      result.bwtBytes += succinctBytes(level)
    result.bwtBytes += int64(dict.bwt.zeroCounts.len * sizeof(int64))
  else:
    result.runSymbolsBytes = int64(dict.runLengthBwt.runSymbols.len *
      sizeof(FmSymbol))
    result.runBoundaryBytes = succinctBytes(dict.runLengthBwt.runStarts)
    result.runPrefixBytes = int64(dict.runLengthBwt.symbolPrefixes.len *
      sizeof(uint32) + sizeof(dict.runLengthBwt.symbolOffsets))
    for level in dict.runLengthBwt.runSymbolIndex.levels:
      result.bwtBytes += succinctBytes(level)
    result.bwtBytes += int64(dict.runLengthBwt.runSymbolIndex.zeroCounts.len *
      sizeof(int64))
  result.fmTotalBytes = result.bwtBytes + result.runSymbolsBytes +
    result.runBoundaryBytes + result.runPrefixBytes + result.cTableBytes +
    result.anchorBytes
  result.totalBytes = result.radixTrieBytes + result.fmTotalBytes

func backwardStep(dict: FmDictionary, symbol: FmSymbol,
                  interval: FmInterval): FmInterval {.inline.} =
  let base = int64(dict.cTable.getUnchecked(int(symbol)))
  let ranks = dict.bwtRankPair(symbol, interval.left, interval.right)
  result.left = base + ranks.leftRank
  result.right = base + ranks.rightRank

func backwardSearchBytes(dict: FmDictionary, pattern: string): FmInterval =
  result = FmInterval(left: 0, right: dict.bwtLength)
  if pattern.len == 0:
    return
  for index in countdown(pattern.high, 0):
    result = dict.backwardStep(encodeByte(byte(pattern[index])), result)
    if result.left >= result.right:
      return

func backwardSearchExact(dict: FmDictionary, value: string): FmInterval =
  result = FmInterval(left: 0, right: dict.bwtLength)
  result = dict.backwardStep(SeparatorSymbol, result)
  for index in countdown(value.high, 0):
    result = dict.backwardStep(encodeByte(byte(value[index])), result)
    if result.left >= result.right:
      return
  result = dict.backwardStep(SeparatorSymbol, result)

func backwardSearchPrefix(dict: FmDictionary, prefix: string): FmInterval =
  result = dict.backwardSearchBytes(prefix)
  if result.left < result.right:
    result = dict.backwardStep(SeparatorSymbol, result)

func backwardSearchSuffix(dict: FmDictionary, suffix: string): FmInterval =
  result = FmInterval(left: 0, right: dict.bwtLength)
  result = dict.backwardStep(SeparatorSymbol, result)
  for index in countdown(suffix.high, 0):
    result = dict.backwardStep(encodeByte(byte(suffix[index])), result)
    if result.left >= result.right:
      return

func lfStep(dict: FmDictionary, row: int64): LfStepResult {.inline.} =
  let item = dict.bwtAccessRank(row)
  result.symbol = FmSymbol(item.value)
  result.nextRow = int64(dict.cTable.getUnchecked(int(item.value))) +
    item.rankBefore

func lf(dict: FmDictionary, row: int64): int64 {.inline.} =
  dict.lfStep(row).nextRow

func idFromSeparatorFRow(dict: FmDictionary, row: int64): int64 {.inline.} =
  let separatorBase =
    int64(dict.cTable.getUnchecked(int(SeparatorSymbol)))
  let ordinal = row - separatorBase
  if ordinal < 0 or ordinal >= dict.startAnchorToEncodedId.len:
    return -1
  let encodedId = dict.startAnchorToEncodedId.getUnchecked(int(ordinal))
  if encodedId == 0: -1 else: int64(encodedId - 1)

func dictionaryIdFromMatchRow(dict: FmDictionary, initialRow: int64): int64 =
  var row = initialRow
  var steps = 0'u32
  while true:
    let step = dict.lfStep(row)
    if step.symbol == SeparatorSymbol:
      let ordinal = step.nextRow -
        int64(dict.cTable.getUnchecked(int(SeparatorSymbol)))
      if ordinal < 0 or ordinal >= dict.startAnchorToEncodedId.len:
        return -1
      let encodedId = dict.startAnchorToEncodedId.getUnchecked(int(ordinal))
      return if encodedId == 0: -1 else: int64(encodedId - 1)
    if step.symbol == EndSymbol:
      return -1
    row = step.nextRow
    inc steps
    if steps > dict.maxEncodedStringLength:
      raise newException(ValueError, "invalid FM Dictionary anchor chain")

func findExactFm*(dict: FmDictionary, value: string): int64 =
  ## FM-indexで完全一致するDictionary IDを返します。
  let interval = dict.backwardSearchExact(value)
  for row in interval.left..<interval.right:
    let dictionaryId = dict.idFromSeparatorFRow(row)
    if dictionaryId >= 0:
      return dictionaryId
  -1

func findExactRadix*(dict: FmDictionary, value: string): int64 =
  ## Radix Trieで完全一致するDictionary IDを返します。
  dict.radixTrie.findExact(value)

func findExact*(dict: FmDictionary, value: string): int64 =
  ## 完全一致するDictionary IDをRadix Trieで検索します。
  dict.findExactRadix(value)

func contains*(dict: FmDictionary, value: string): bool =
  ## 完全一致する文字列が存在するかを返します。
  dict.findExact(value) >= 0

proc allIds(dict: FmDictionary): seq[DictionaryId] =
  result = newSeq[DictionaryId](dict.len)
  for index in 0..<result.len:
    result[index] = DictionaryId(index)

proc findPrefixIntoFm*(dict: FmDictionary, prefix: string,
                       output: var seq[DictionaryId]) =
  ## FM-indexで前方一致するIDを昇順で `output` へ格納します。
  output.setLen(0)
  if prefix.len == 0:
    for dictionaryId in 0..<dict.len:
      output.add DictionaryId(dictionaryId)
    return
  let interval = dict.backwardSearchPrefix(prefix)
  for row in interval.left..<interval.right:
    let dictionaryId = dict.idFromSeparatorFRow(row)
    if dictionaryId >= 0:
      output.add DictionaryId(dictionaryId)
  output.sort()

proc findPrefixIntoRadix*(dict: FmDictionary, prefix: string,
                          output: var seq[DictionaryId]) =
  ## Radix Trieで前方一致するIDを昇順で `output` へ格納します。
  dict.radixTrie.findPrefixInto(prefix, output)

proc initPrefixQueryWorkspace*(dict: FmDictionary): PrefixQueryWorkspace =
  ## `dict`向けprefix workspaceを初期化します。
  initPrefixQueryWorkspace(dict.len)

proc findPrefixIntoRadix*(dict: FmDictionary, prefix: string,
                          workspace: var PrefixQueryWorkspace,
                          output: var seq[DictionaryId]) =
  ## bitmap workspaceを再利用して前方一致IDを昇順で格納します。
  dict.radixTrie.findPrefixInto(prefix, workspace, output)

proc findPrefixInto*(dict: FmDictionary, prefix: string,
                     workspace: var PrefixQueryWorkspace,
                     output: var seq[DictionaryId]) =
  ## bitmap workspaceを再利用して前方一致IDを昇順で格納します。
  dict.findPrefixIntoRadix(prefix, workspace, output)

proc findPrefixInto*(dict: FmDictionary, prefix: string,
                     output: var seq[DictionaryId]) =
  ## 前方一致するIDを既存の `output` 容量を再利用して昇順で格納します。
  dict.findPrefixIntoRadix(prefix, output)

proc findPrefix*(dict: FmDictionary, prefix: string): seq[DictionaryId] =
  ## byte単位で前方一致するDictionary IDを昇順で返します。
  dict.findPrefixInto(prefix, result)

proc findSuffix*(dict: FmDictionary, suffix: string): seq[DictionaryId] =
  ## byte単位で後方一致するDictionary IDを昇順で返します。
  if suffix.len == 0:
    return dict.allIds()
  let interval = dict.backwardSearchSuffix(suffix)
  result = newSeqOfCap[DictionaryId](int(interval.right - interval.left))
  for row in interval.left..<interval.right:
    let dictionaryId = dict.dictionaryIdFromMatchRow(row)
    if dictionaryId >= 0:
      result.add DictionaryId(dictionaryId)
  result.sort()

proc initFmQueryWorkspace*(dictionaryCount: int): FmQueryWorkspace =
  ## 指定件数のDictionary向けworkspaceを初期化します。
  if dictionaryCount < 0:
    raise newException(ValueError, "dictionary count must be non-negative")
  result.counts = newSeq[uint32](dictionaryCount)
  result.generations = newSeq[uint32](dictionaryCount)

proc initFmQueryWorkspace*(dict: FmDictionary): FmQueryWorkspace =
  ## `dict`向けworkspaceを初期化します。
  initFmQueryWorkspace(dict.len)

proc beginQuery(workspace: var FmQueryWorkspace, dictionaryCount: int) =
  if workspace.counts.len != dictionaryCount or
      workspace.generations.len != dictionaryCount:
    workspace = initFmQueryWorkspace(dictionaryCount)
  inc workspace.currentGeneration
  workspace.touchedIds.setLen(0)
  if workspace.currentGeneration == 0:
    workspace.generations.fill(0)
    workspace.currentGeneration = 1

proc recordMatch(workspace: var FmQueryWorkspace, id: DictionaryId,
                 countOccurrences: bool) {.inline.} =
  let index = int(id)
  if workspace.generations[index] != workspace.currentGeneration:
    workspace.generations[index] = workspace.currentGeneration
    workspace.counts[index] = 1
    workspace.touchedIds.add id
  elif countOccurrences:
    inc workspace.counts[index]

proc collectMatches(dict: FmDictionary, pattern: string,
                    workspace: var FmQueryWorkspace,
                    countOccurrences: bool) =
  workspace.beginQuery(dict.len)
  let interval = dict.backwardSearchBytes(pattern)
  for row in interval.left..<interval.right:
    let dictionaryId = dict.dictionaryIdFromMatchRow(row)
    if dictionaryId >= 0:
      workspace.recordMatch(DictionaryId(dictionaryId), countOccurrences)
  workspace.touchedIds.sort()

proc getStringIntoFm*(dict: FmDictionary, id: DictionaryId,
                      output: var string) =
  ## FM-indexのLF traversalで復元した文字列を `output` へ格納します。
  ##
  ## 既存の文字列capacityを再利用します。IDが範囲外の場合は`IndexDefect`、
  ## 内部anchorが破損している場合は`ValueError`が発生します。
  if id >= dict.dictionaryCount:
    raise newException(IndexDefect, "dictionary ID out of range")
  output.setLen(0)
  let endAnchorOrdinal = int64(
    dict.dictionaryIdToEndAnchor.getUnchecked(int(id)))
  let anchorRow = dict.bwtSelect(SeparatorSymbol, endAnchorOrdinal)
  if anchorRow < 0:
    raise newException(ValueError, "invalid dictionary end anchor")
  var row = dict.lf(anchorRow)
  var steps = 0'u32
  while true:
    let step = dict.lfStep(row)
    if step.symbol == SeparatorSymbol:
      break
    if step.symbol == EndSymbol:
      raise newException(ValueError, "unexpected end symbol")
    output.add char(decodeByte(step.symbol))
    row = step.nextRow
    inc steps
    if steps > dict.maxEncodedStringLength:
      raise newException(ValueError, "invalid FM Dictionary string chain")
  for index in 0..<output.len div 2:
    swap(output[index], output[output.high - index])

proc getStringIntoRadix*(dict: FmDictionary, id: DictionaryId,
                         output: var string) =
  ## Radix Trieで復元した文字列を `output` へ格納します。
  dict.radixTrie.getStringInto(id, output)

proc getStringInto*(dict: FmDictionary, id: DictionaryId,
                    output: var string) =
  ## Dictionary IDから復元した文字列を `output` へ格納します。
  dict.getStringIntoRadix(id, output)

proc getString*(dict: FmDictionary, id: DictionaryId): string =
  ## Dictionary IDから元の文字列を復元します。
  dict.getStringInto(id, result)

proc findSubstringInto*(dict: FmDictionary, pattern: string,
                        workspace: var FmQueryWorkspace,
                        output: var seq[DictionaryId]) =
  ## workspaceと`output`を再利用して部分一致するIDを昇順で格納します。
  output.setLen(0)
  if pattern.len == 0:
    for dictionaryId in 0..<dict.len:
      output.add DictionaryId(dictionaryId)
    return
  dict.collectMatches(pattern, workspace, false)
  for dictionaryId in workspace.touchedIds:
    output.add dictionaryId

proc findSubstring*(dict: FmDictionary, pattern: string,
                    workspace: var FmQueryWorkspace): seq[DictionaryId] =
  ## workspaceを再利用して部分一致するIDを重複なしの昇順で返します。
  dict.findSubstringInto(pattern, workspace, result)

proc findSubstring*(dict: FmDictionary,
                    pattern: string): seq[DictionaryId] =
  ## byte単位で部分一致するDictionary IDを重複なしの昇順で返します。
  var workspace = initFmQueryWorkspace(dict)
  result = dict.findSubstring(pattern, workspace)

proc findSubstringOccurrences*(dict: FmDictionary, pattern: string,
    workspace: var FmQueryWorkspace): seq[tuple[
      id: DictionaryId, occurrences: uint32]] =
  ## workspaceを再利用し、IDごとの部分一致回数を昇順で返します。
  if pattern.len == 0:
    for dictionaryId in 0..<dict.len:
      var value: string
      dict.getStringInto(DictionaryId(dictionaryId), value)
      result.add (id: DictionaryId(dictionaryId),
                  occurrences: uint32(value.len + 1))
    return
  dict.collectMatches(pattern, workspace, true)
  result = newSeqOfCap[tuple[id: DictionaryId, occurrences: uint32]](
    workspace.touchedIds.len)
  for dictionaryId in workspace.touchedIds:
    result.add (id: dictionaryId,
      occurrences: workspace.counts[int(dictionaryId)])

proc findSubstringOccurrences*(dict: FmDictionary,
                               pattern: string): seq[tuple[
                                 id: DictionaryId, occurrences: uint32]] =
  ## byte単位の部分一致について、IDごとの出現回数を昇順で返します。
  var workspace = initFmQueryWorkspace(dict)
  result = dict.findSubstringOccurrences(pattern, workspace)

iterator items*(dict: FmDictionary): string =
  ## 文字列をDictionary ID順に復元して列挙します。
  for dictionaryId in 0..<dict.len:
    yield dict.getString(DictionaryId(dictionaryId))
