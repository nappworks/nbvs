import std/random
import nbvs/run_length_bwt
import nbvs/internal/fm_symbols

proc verify(values: seq[FmSymbol]) =
  let bwt = genRunLengthBwt(values)
  for position, expected in values:
    doAssert bwt.access(int64(position)) == expected
    let item = bwt.accessRank(int64(position))
    doAssert bwt.accessRankUnchecked(int64(position)) == item
    doAssert item.value == uint64(expected)
    var expectedRank = 0'i64
    for index in 0..<position:
      if values[index] == expected:
        inc expectedRank
    doAssert item.rankBefore == expectedRank
  for symbolValue in 0..<AlphabetSize:
    let symbol = FmSymbol(symbolValue)
    var positions: seq[int64]
    for position in 0..values.len:
      var expectedRank = 0'i64
      for index in 0..<position:
        if values[index] == symbol:
          inc expectedRank
      doAssert bwt.rank(symbol, int64(position)) == expectedRank
      if position < values.len and values[position] == symbol:
        positions.add int64(position)
    for ordinal, expectedPosition in positions:
      doAssert bwt.select(symbol, int64(ordinal)) == expectedPosition
    doAssert bwt.select(symbol, int64(positions.len)) == -1
  let pairSymbols = [EndSymbol, SeparatorSymbol, encodeByte(0), encodeByte(255)]
  for symbol in pairSymbols:
    for left in 0..values.len:
      for right in left..values.len:
        var leftRank, rightRank: int64
        for position, value in values:
          if value == symbol:
            if position < left: inc leftRank
            if position < right: inc rightRank
        doAssert bwt.rankPair(symbol, int64(left), int64(right)) ==
          (leftRank: leftRank, rightRank: rightRank)

proc verifyExhaustive(values: seq[FmSymbol]) =
  let bwt = genRunLengthBwt(values)
  for symbolValue in 0..2:
    let symbol = FmSymbol(symbolValue)
    for left in 0..values.len:
      for right in left..values.len:
        var expectedLeft, expectedRight: int64
        for position, value in values:
          if value == symbol:
            if position < left: inc expectedLeft
            if position < right: inc expectedRight
        doAssert bwt.rankPair(symbol, int64(left), int64(right)) ==
          (leftRank: expectedLeft, rightRank: expectedRight)

for length in 0..8:
  var combinationCount = 1
  for _ in 0..<length:
    combinationCount *= 3
  for encoded in 0..<combinationCount:
    var value = encoded
    var symbols = newSeq[FmSymbol](length)
    for position in 0..<length:
      symbols[position] = FmSymbol(value mod 3)
      value = value div 3
    verifyExhaustive(symbols)

verify(@[])
verify(@[EndSymbol])
verify(@[SeparatorSymbol, SeparatorSymbol, encodeByte(0), encodeByte(0),
  encodeByte(255), SeparatorSymbol])

var rng = initRand(0x524c4257)
for trial in 0..<100:
  var values = newSeq[FmSymbol](rng.rand(128))
  for value in values.mitems:
    value = FmSymbol(rng.rand(AlphabetSize - 1))
  verify(values)
