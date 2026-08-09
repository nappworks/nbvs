## Run-length encoded BWT向けのrank/select索引。

import succinct_bit_vector, wavelet_matrix
import internal/fm_symbols

type
  RunLengthBwt* = object
    ## 同値symbolの連続区間をrunとして保持するBWT表現です。
    n*: int64
    runSymbols*: seq[FmSymbol]
    runLengths*: seq[uint32]
    runStarts*: SuccinctBitVector
    runSymbolIndex*: WaveletMatrix
    symbolOffsets*: array[AlphabetSize + 1, uint32]
    symbolPrefixes*: seq[uint32]

func runCount*(bwt: RunLengthBwt): int {.inline.} =
  ## run数を返します。
  bwt.runSymbols.len

proc genRunLengthBwt*(values: openArray[FmSymbol]): RunLengthBwt =
  ## symbol列からrun-length BWT索引を構築します。
  result.n = int64(values.len)
  result.runStarts = genSuccinctBitVector(result.n)
  if values.len == 0:
    result.runStarts.build()
    return

  var runSymbolValues: seq[uint16]
  var counts: array[AlphabetSize, uint32]
  var start = 0
  while start < values.len:
    let symbol = values[start]
    var finish = start + 1
    while finish < values.len and values[finish] == symbol:
      inc finish
    result.runStarts.setBit(int64(start))
    result.runSymbols.add symbol
    runSymbolValues.add uint16(symbol)
    result.runLengths.add uint32(finish - start)
    inc counts[int(symbol)]
    start = finish
  result.runStarts.build()
  result.runSymbolIndex = genWaveletMatrix(runSymbolValues, SymbolBitWidth)

  var prefixSize = 0'u32
  for symbol in 0..<AlphabetSize:
    result.symbolOffsets[symbol] = prefixSize
    prefixSize += counts[symbol] + 1
  result.symbolOffsets[AlphabetSize] = prefixSize
  result.symbolPrefixes = newSeq[uint32](int(prefixSize))
  var seen: array[AlphabetSize, uint32]
  var totals: array[AlphabetSize, uint32]
  for run, symbol in result.runSymbols:
    let symbolIndex = int(symbol)
    totals[symbolIndex] += result.runLengths[run]
    inc seen[symbolIndex]
    result.symbolPrefixes[int(result.symbolOffsets[symbolIndex] +
      seen[symbolIndex])] = totals[symbolIndex]

func checkIndex(bwt: RunLengthBwt, position: int64) {.inline.} =
  if position < 0 or position >= bwt.n:
    raise newException(IndexDefect, "index out of bounds")

func checkPosition(bwt: RunLengthBwt, position: int64) {.inline.} =
  if position < 0 or position > bwt.n:
    raise newException(IndexDefect, "position out of bounds")

func prefixBeforeRun(bwt: RunLengthBwt, symbol: FmSymbol,
                     run: int): int64 {.inline.} =
  let ordinal = bwt.runSymbolIndex.rank(uint64(symbol), int64(run))
  int64(bwt.symbolPrefixes[int(bwt.symbolOffsets[int(symbol)]) + int(ordinal)])

func accessRank*(bwt: RunLengthBwt,
                 position: int64): tuple[value: uint64, rankBefore: int64] =
  ## `position`のsymbolと同じsymbolの`[0, position)`での出現数を返します。
  bwt.checkIndex(position)
  let run = int(bwt.runStarts.rank1(position + 1) - 1)
  let symbol = bwt.runSymbols[run]
  let runStart = bwt.runStarts.select1(int64(run))
  result.value = uint64(symbol)
  result.rankBefore = bwt.prefixBeforeRun(symbol, run) + position - runStart

func access*(bwt: RunLengthBwt, position: int64): FmSymbol =
  ## `position`のsymbolを返します。
  FmSymbol(bwt.accessRank(position).value)

func rank*(bwt: RunLengthBwt, symbol: FmSymbol, position: int64): int64 =
  ## `symbol`の`[0, position)`における出現数を返します。
  bwt.checkPosition(position)
  if position == 0 or bwt.n == 0:
    return 0
  if position == bwt.n:
    let last = int(bwt.symbolOffsets[int(symbol) + 1])
    return int64(bwt.symbolPrefixes[last - 1])
  let run = int(bwt.runStarts.rank1(position + 1) - 1)
  result = bwt.prefixBeforeRun(symbol, run)
  if bwt.runSymbols[run] == symbol:
    result += position - bwt.runStarts.select1(int64(run))

func rankPair*(bwt: RunLengthBwt, symbol: FmSymbol, left,
               right: int64): tuple[leftRank, rightRank: int64] =
  ## `symbol`の`[0, left)`と`[0, right)`におけるrankを返します。
  if left < 0 or left > right or right > bwt.n:
    raise newException(IndexDefect, "range out of bounds")
  result.leftRank = bwt.rank(symbol, left)
  result.rightRank = bwt.rank(symbol, right)

func select*(bwt: RunLengthBwt, symbol: FmSymbol, ordinal: int64): int64 =
  ## 0-basedの`ordinal`番目の出現位置を返し、存在しなければ`-1`を返します。
  if ordinal < 0 or bwt.n == 0:
    return -1
  let first = int(bwt.symbolOffsets[int(symbol)])
  let last = int(bwt.symbolOffsets[int(symbol) + 1])
  if ordinal >= int64(bwt.symbolPrefixes[last - 1]):
    return -1
  var low = first
  var high = last - 1
  while low < high:
    let middle = (low + high) shr 1
    if int64(bwt.symbolPrefixes[middle + 1]) <= ordinal:
      low = middle + 1
    else:
      high = middle
  let symbolRunOrdinal = low - first
  let run = bwt.runSymbolIndex.select(uint64(symbol), int64(symbolRunOrdinal))
  bwt.runStarts.select1(run) + ordinal - int64(bwt.symbolPrefixes[low])

func memoryUsage*(bwt: RunLengthBwt): int64 =
  ## 論理的な格納容量の概算をbyte単位で返します。
  result = int64(bwt.runSymbols.len * sizeof(FmSymbol) +
    bwt.runLengths.len * sizeof(uint32) +
    bwt.symbolPrefixes.len * sizeof(uint32) + sizeof(bwt.symbolOffsets))
  result += int64(bwt.runStarts.data.len * sizeof(uint64) +
    bwt.runStarts.blockPairPrefix.len * sizeof(uint32) +
    bwt.runStarts.wordPairPrefix.len * sizeof(uint32) +
    bwt.runStarts.selectStorage.len * sizeof(uint64))
  for level in bwt.runSymbolIndex.levels:
    result += int64(level.data.len * sizeof(uint64) +
      level.blockPairPrefix.len * sizeof(uint32) +
      level.wordPairPrefix.len * sizeof(uint32) +
      level.selectStorage.len * sizeof(uint64))
