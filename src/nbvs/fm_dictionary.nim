## BWTとWavelet Matrixを使用するself-index型文字列Dictionary。
##
## 文字列はUTF-8 byte列として処理され、入力順がDictionary IDになります。

import std/[algorithm, bitops, sets]
import packed_array, wavelet_matrix
import internal/[fm_symbols, suffix_array]

export fm_symbols

type
  DictionaryId* = uint32
    ## FmDictionary内の文字列を入力順で識別するIDです。

  FmInterval* = object
    ## FM-index検索結果の半開区間を表します。
    left*: int64
    right*: int64

  FmDictionary* = object
    ## 元文字列poolを保持せず、検索と復元を提供するDictionaryです。
    bwt*: WaveletMatrix ## BWT symbol列を保持する固定9-bit Wavelet Matrix。
    cTable*: PackedArray            ## symbol未満の総出現数を保持するC table。
    startAnchorToEncodedId*: PackedArray ## 開始anchorからencoded IDを得る配列。
    dictionaryIdToEndAnchor*: PackedArray ## IDから終了anchor ordinalを得る配列。
    dictionaryCount*: uint32        ## Dictionaryのエントリ数。
    maxEncodedStringLength*: uint32 ## 最大文字列長（UTF-8 byte数）。

func requiredBitWidth(maximum: uint64): int {.inline.} =
  if maximum == 0: 0 else: 64 - countLeadingZeroBits(maximum)

proc buildBwt(symbols: openArray[FmSymbol],
              suffixArray: openArray[uint32]): seq[FmSymbol] =
  result = newSeq[FmSymbol](symbols.len)
  for row, suffixStartValue in suffixArray:
    let suffixStart = int(suffixStartValue)
    let previous = if suffixStart == 0: symbols.high else: suffixStart - 1
    result[row] = symbols[previous]

proc genFmDictionary*(strings: openArray[string]): FmDictionary =
  ## distinctな文字列集合からFmDictionaryを構築します。
  ##
  ## 重複入力、または件数・連結symbol列長が `uint32` の範囲を超える場合は
  ## `ValueError` が発生します。SA-ISによる構築時間は`O(n)`、
  ## 構築時の追加領域は `O(n)` です。
  if uint64(strings.len) > uint64(uint32.high):
    raise newException(ValueError, "dictionary count exceeds uint32 limit")

  var seen = initHashSet[string]()
  var totalLength = 2'u64 # 先頭separatorと一意な全体終端。
  for value in strings:
    if value in seen:
      raise newException(ValueError, "duplicate dictionary string")
    seen.incl value
    totalLength += uint64(value.len) + 1'u64
    if totalLength > uint64(uint32.high):
      raise newException(ValueError, "concatenated symbols exceed uint32 limit")
    result.maxEncodedStringLength =
      max(result.maxEncodedStringLength, uint32(value.len))

  result.dictionaryCount = uint32(strings.len)
  let symbolCount = int(totalLength)
  var symbols = newSeqOfCap[FmSymbol](symbolCount)
  var startsAt = newSeq[int64](symbolCount)
  var endsAt = newSeq[int64](symbolCount)
  for index in 0..<symbolCount:
    startsAt[index] = -1
    endsAt[index] = -1

  symbols.add SeparatorSymbol
  if strings.len > 0:
    startsAt[0] = 0
  for dictionaryId, value in strings:
    for character in value:
      symbols.add encodeByte(byte(character))
    let separatorPosition = symbols.len
    symbols.add SeparatorSymbol
    endsAt[separatorPosition] = int64(dictionaryId)
    if dictionaryId + 1 < strings.len:
      startsAt[separatorPosition] = int64(dictionaryId + 1)
  symbols.add EndSymbol

  let suffixArray = buildSuffixArray(symbols)
  let bwtSymbols = buildBwt(symbols, suffixArray)
  var bwtValues = newSeq[uint64](bwtSymbols.len)
  var counts: array[AlphabetSize, uint64]
  for index, symbol in bwtSymbols:
    if int(symbol) >= AlphabetSize:
      raise newException(ValueError, "symbol exceeds 9-bit alphabet")
    bwtValues[index] = uint64(symbol)
    inc counts[int(symbol)]
  if counts[int(EndSymbol)] != 1:
    raise newException(ValueError, "BWT must contain exactly one end symbol")
  result.bwt = genWaveletMatrix(bwtValues, SymbolBitWidth)

  result.cTable = genPackedArray(AlphabetSize, requiredBitWidth(uint64(symbols.len)))
  var cumulative = 0'u64
  for symbol in 0..<AlphabetSize:
    result.cTable[symbol] = cumulative
    cumulative += counts[symbol]

  let separatorCount = strings.len + 1
  let anchorWidth = requiredBitWidth(uint64(strings.len))
  result.startAnchorToEncodedId =
    genPackedArray(int64(separatorCount), anchorWidth)
  result.dictionaryIdToEndAnchor =
    genPackedArray(int64(strings.len), requiredBitWidth(uint64(separatorCount - 1)))
  var endAnchorSet = newSeq[bool](strings.len)
  var separatorOrdinal = 0
  for row, symbol in bwtSymbols:
    if symbol != SeparatorSymbol:
      continue
    let suffixStart = int(suffixArray[row])
    let originalPosition = if suffixStart == 0: symbols.high else: suffixStart - 1
    let startId = startsAt[originalPosition]
    if startId >= 0:
      result.startAnchorToEncodedId[separatorOrdinal] = uint64(startId + 1)
    let endId = endsAt[originalPosition]
    if endId >= 0:
      result.dictionaryIdToEndAnchor[endId] = uint64(separatorOrdinal)
      endAnchorSet[int(endId)] = true
    inc separatorOrdinal
  if separatorOrdinal != separatorCount:
    raise newException(ValueError, "invalid separator count in BWT")
  for isSet in endAnchorSet:
    if not isSet:
      raise newException(ValueError, "incomplete dictionary end anchors")

func len*(dict: FmDictionary): int {.inline.} =
  ## Dictionaryのエントリ数を返します。
  int(dict.dictionaryCount)

func backwardStep(dict: FmDictionary, symbol: FmSymbol,
                  interval: FmInterval): FmInterval {.inline.} =
  let base = int64(dict.cTable.getUnchecked(int(symbol)))
  result.left = base + dict.bwt.rank(uint64(symbol), interval.left)
  result.right = base + dict.bwt.rank(uint64(symbol), interval.right)

func backwardSearch(dict: FmDictionary,
                    pattern: openArray[FmSymbol]): FmInterval =
  result = FmInterval(left: 0, right: dict.bwt.n)
  if pattern.len == 0:
    return
  for index in countdown(pattern.high, 0):
    result = dict.backwardStep(pattern[index], result)
    if result.left >= result.right:
      return

func lf(dict: FmDictionary, row: int64): int64 {.inline.} =
  let item = dict.bwt.accessRank(row)
  int64(dict.cTable.getUnchecked(int(item.value))) + item.rankBefore

func idAtStartAnchor(dict: FmDictionary, row: int64): int64 {.inline.} =
  if dict.bwt.access(row) != uint64(SeparatorSymbol):
    return -1
  let ordinal = dict.bwt.rank(uint64(SeparatorSymbol), row)
  let encodedId = dict.startAnchorToEncodedId.getUnchecked(int(ordinal))
  if encodedId == 0: -1 else: int64(encodedId - 1)

func dictionaryIdFromMatchRow(dict: FmDictionary, initialRow: int64): int64 =
  var row = initialRow
  var steps = 0'u32
  while true:
    let symbol = FmSymbol(dict.bwt.access(row))
    if symbol == SeparatorSymbol:
      return dict.idAtStartAnchor(row)
    if symbol == EndSymbol:
      return -1
    row = dict.lf(row)
    inc steps
    if steps > dict.maxEncodedStringLength:
      raise newException(ValueError, "invalid FM Dictionary anchor chain")

func findExact*(dict: FmDictionary, value: string): int64 =
  ## 完全一致するDictionary IDを返し、存在しない場合は `-1` を返します。
  var pattern = encodeString(value)
  pattern.add SeparatorSymbol
  let interval = dict.backwardSearch(pattern)
  for row in interval.left..<interval.right:
    let dictionaryId = dict.idAtStartAnchor(row)
    if dictionaryId >= 0:
      return dictionaryId
  -1

func contains*(dict: FmDictionary, value: string): bool =
  ## 完全一致する文字列が存在するかを返します。
  dict.findExact(value) >= 0

proc allIds(dict: FmDictionary): seq[DictionaryId] =
  result = newSeq[DictionaryId](dict.len)
  for index in 0..<result.len:
    result[index] = DictionaryId(index)

proc sortedUnique(values: var seq[DictionaryId]) =
  values.sort()
  var outputLength = 0
  for value in values:
    if outputLength == 0 or values[outputLength - 1] != value:
      values[outputLength] = value
      inc outputLength
  values.setLen(outputLength)

proc findPrefix*(dict: FmDictionary, prefix: string): seq[DictionaryId] =
  ## byte単位で前方一致するDictionary IDを昇順で返します。
  if prefix.len == 0:
    return dict.allIds()
  let interval = dict.backwardSearch(encodeString(prefix))
  for row in interval.left..<interval.right:
    let dictionaryId = dict.idAtStartAnchor(row)
    if dictionaryId >= 0:
      result.add DictionaryId(dictionaryId)
  result.sortedUnique()

proc collectMatchIds(dict: FmDictionary, pattern: seq[FmSymbol],
                     withOccurrences: bool): seq[tuple[id: DictionaryId,
                                                        occurrences: uint32]] =
  let interval = dict.backwardSearch(pattern)
  var matchedIds = newSeqOfCap[DictionaryId](int(interval.right -
      interval.left))
  for row in interval.left..<interval.right:
    let dictionaryId = dict.dictionaryIdFromMatchRow(row)
    if dictionaryId >= 0:
      matchedIds.add DictionaryId(dictionaryId)
  matchedIds.sort()
  var index = 0
  while index < matchedIds.len:
    let dictionaryId = matchedIds[index]
    var nextIndex = index + 1
    while nextIndex < matchedIds.len and matchedIds[nextIndex] == dictionaryId:
      inc nextIndex
    result.add (id: dictionaryId,
                occurrences: if withOccurrences: uint32(nextIndex -
                    index) else: 1'u32)
    index = nextIndex

proc findSuffix*(dict: FmDictionary, suffix: string): seq[DictionaryId] =
  ## byte単位で後方一致するDictionary IDを昇順で返します。
  if suffix.len == 0:
    return dict.allIds()
  var pattern = encodeString(suffix)
  pattern.add SeparatorSymbol
  for item in dict.collectMatchIds(pattern, false):
    result.add item.id

proc getString*(dict: FmDictionary, id: DictionaryId): string

proc findSubstringOccurrences*(dict: FmDictionary,
                               pattern: string): seq[tuple[
                                 id: DictionaryId, occurrences: uint32]] =
  ## byte単位の部分一致について、IDごとの出現回数を昇順で返します。
  ##
  ## 空patternは各byte境界に一致するため、各文字列についてbyte長+1回とします。
  if pattern.len == 0:
    for dictionaryId in 0..<dict.len:
      let value = dict.getString(DictionaryId(dictionaryId))
      result.add (id: DictionaryId(dictionaryId),
                  occurrences: uint32(value.len + 1))
    return
  result = dict.collectMatchIds(encodeString(pattern), true)

proc findSubstring*(dict: FmDictionary,
                    pattern: string): seq[DictionaryId] =
  ## byte単位で部分一致するDictionary IDを重複なしの昇順で返します。
  if pattern.len == 0:
    return dict.allIds()
  for item in dict.collectMatchIds(encodeString(pattern), false):
    result.add item.id

proc getString*(dict: FmDictionary, id: DictionaryId): string =
  ## Dictionary IDから元の文字列を復元します。
  ##
  ## IDが範囲外の場合は `IndexDefect`、内部anchorが破損している場合は
  ## `ValueError` が発生します。
  if id >= dict.dictionaryCount:
    raise newException(IndexDefect, "dictionary ID out of range")
  let endAnchorOrdinal = int64(
    dict.dictionaryIdToEndAnchor.getUnchecked(int(id)))
  var row = dict.bwt.select(uint64(SeparatorSymbol), endAnchorOrdinal)
  if row < 0:
    raise newException(ValueError, "invalid dictionary end anchor")
  row = dict.lf(row)
  var reversed = newSeqOfCap[byte](int(dict.maxEncodedStringLength))
  var steps = 0'u32
  while true:
    let symbol = FmSymbol(dict.bwt.access(row))
    if symbol == SeparatorSymbol:
      break
    if symbol == EndSymbol:
      raise newException(ValueError, "unexpected end symbol")
    reversed.add decodeByte(symbol)
    row = dict.lf(row)
    inc steps
    if steps > dict.maxEncodedStringLength:
      raise newException(ValueError, "invalid FM Dictionary string chain")
  result = newString(reversed.len)
  for index in 0..<reversed.len:
    result[index] = char(reversed[reversed.high - index])

iterator items*(dict: FmDictionary): string =
  ## 文字列をDictionary ID順に復元して列挙します。
  for dictionaryId in 0..<dict.len:
    yield dict.getString(DictionaryId(dictionaryId))
