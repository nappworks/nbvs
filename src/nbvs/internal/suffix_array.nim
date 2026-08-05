## FmDictionary構築用の省メモリSA-IS Suffix Array。

import ../bit_vector
import ./fm_symbols

const InvalidSaIndex = uint32.high

proc classifyTypes[Symbol: SomeUnsignedInt](symbols: openArray[Symbol]): tuple[
    isSType, isLms: BitVector] =
  let length = symbols.len
  result.isSType = genBitVector(length)
  result.isLms = genBitVector(length)
  result.isSType.setBit(length - 1)
  for index in countdown(length - 2, 0):
    if symbols[index] < symbols[index + 1] or
        (symbols[index] == symbols[index + 1] and result.isSType[index + 1]):
      result.isSType.setBit(index)
  for index in 1..<length:
    if result.isSType[index] and not result.isSType[index - 1]:
      result.isLms.setBit(index)

proc bucketSizes[Symbol: SomeUnsignedInt](symbols: openArray[Symbol],
    alphabetSize: int): seq[int] =
  result = newSeq[int](alphabetSize)
  for symbol in symbols:
    inc result[int(symbol)]

proc bucketHeads(sizes: openArray[int]): seq[int] =
  result = newSeq[int](sizes.len)
  var position = 0
  for symbol, size in sizes:
    result[symbol] = position
    position += size

proc bucketTails(sizes: openArray[int]): seq[int] =
  result = newSeq[int](sizes.len)
  var position = 0
  for symbol, size in sizes:
    position += size
    result[symbol] = position

proc induce[Symbol: SomeUnsignedInt](symbols: openArray[Symbol], alphabetSize: int,
            isSType: BitVector, orderedLms: openArray[uint32]): seq[uint32] =
  let sizes = bucketSizes(symbols, alphabetSize)
  result = newSeq[uint32](symbols.len)
  for value in result.mitems:
    value = InvalidSaIndex

  var tails = bucketTails(sizes)
  for index in countdown(orderedLms.high, 0):
    let suffix = orderedLms[index]
    let symbol = int(symbols[int(suffix)])
    dec tails[symbol]
    result[tails[symbol]] = suffix

  var heads = bucketHeads(sizes)
  for index in 0..<result.len:
    let suffix = result[index]
    if suffix == InvalidSaIndex or suffix == 0:
      continue
    let previous = int(suffix) - 1
    if not isSType[previous]:
      let symbol = int(symbols[previous])
      result[heads[symbol]] = uint32(previous)
      inc heads[symbol]

  tails = bucketTails(sizes)
  for index in countdown(result.high, 0):
    let suffix = result[index]
    if suffix == InvalidSaIndex or suffix == 0:
      continue
    let previous = int(suffix) - 1
    if isSType[previous]:
      let symbol = int(symbols[previous])
      dec tails[symbol]
      result[tails[symbol]] = uint32(previous)

func lmsSubstringsEqual[Symbol: SomeUnsignedInt](symbols: openArray[Symbol],
                        isSType, isLms: BitVector,
                        leftValue, rightValue: uint32): bool =
  let left = int(leftValue)
  let right = int(rightValue)
  if left == right:
    return true
  var offset = 0
  while true:
    let leftPosition = left + offset
    let rightPosition = right + offset
    if symbols[leftPosition] != symbols[rightPosition] or
        isSType[leftPosition] != isSType[rightPosition]:
      return false
    if offset > 0:
      let leftEnds = isLms[leftPosition]
      let rightEnds = isLms[rightPosition]
      if leftEnds or rightEnds:
        return leftEnds and rightEnds
    inc offset

proc sais[Symbol: SomeUnsignedInt](symbols: openArray[Symbol],
                                  alphabetSize: int): seq[uint32] =
  let length = symbols.len
  if length == 1:
    return @[0'u32]

  let types = classifyTypes(symbols)
  var lmsPositions: seq[uint32]
  for index in 1..<length:
    if types.isLms[index]:
      lmsPositions.add uint32(index)

  var suffixArray = induce(symbols, alphabetSize, types.isSType, lmsPositions)
  var sortedLms = newSeqOfCap[uint32](lmsPositions.len)
  for suffix in suffixArray:
    if suffix != InvalidSaIndex and types.isLms[int(suffix)]:
      sortedLms.add suffix

  for value in suffixArray.mitems:
    value = InvalidSaIndex
  var name = 0'u32
  var previous = InvalidSaIndex
  for suffix in sortedLms:
    if previous != InvalidSaIndex and
        not lmsSubstringsEqual(symbols, types.isSType, types.isLms,
                               previous, suffix):
      inc name
    suffixArray[int(suffix)] = name
    previous = suffix
  let nameCount = int(name) + 1

  var reduced = newSeq[uint32](lmsPositions.len)
  for index, suffix in lmsPositions:
    reduced[index] = suffixArray[int(suffix)]

  var reducedSuffixArray: seq[uint32]
  if nameCount == lmsPositions.len:
    reducedSuffixArray = newSeq[uint32](lmsPositions.len)
    for index, reducedSymbol in reduced:
      reducedSuffixArray[int(reducedSymbol)] = uint32(index)
  else:
    reducedSuffixArray = sais(reduced, nameCount)

  var orderedLms = newSeq[uint32](lmsPositions.len)
  for index, reducedIndex in reducedSuffixArray:
    orderedLms[index] = lmsPositions[int(reducedIndex)]
  result = induce(symbols, alphabetSize, types.isSType, orderedLms)

proc buildSuffixArray*(symbols: openArray[FmSymbol]): seq[uint32] =
  ## 一意な最小終端symbolを含むsymbol列をSA-ISで整列します。
  ##
  ## L/S型とLMS位置は`BitVector`で各要素1 bitに圧縮します。
  ## 時間計算量は `O(n)`、追加領域は `O(n)` です。
  let length = symbols.len
  if length == 0:
    return @[]
  if uint64(length) > uint64(uint32.high):
    raise newException(ValueError, "symbol sequence exceeds uint32 suffix array limit")
  if symbols[^1] != EndSymbol:
    raise newException(ValueError, "suffix array input must end with EndSymbol")

  var endSymbolCount = 0
  for symbol in symbols:
    if int(symbol) >= AlphabetSize:
      raise newException(ValueError, "symbol exceeds FM alphabet")
    if symbol == EndSymbol:
      inc endSymbolCount
  if endSymbolCount != 1:
    raise newException(ValueError, "suffix array input requires one EndSymbol")
  result = sais(symbols, AlphabetSize)
