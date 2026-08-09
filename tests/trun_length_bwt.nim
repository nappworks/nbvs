import std/random
import nbvs/run_length_bwt
import nbvs/internal/fm_symbols

proc verify(values: seq[FmSymbol]) =
  let bwt = genRunLengthBwt(values)
  for position, expected in values:
    doAssert bwt.access(int64(position)) == expected
    let item = bwt.accessRank(int64(position))
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
