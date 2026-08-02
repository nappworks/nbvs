import packed_prefix_entry

for value in [0'u64, 1, 4095, 4096, (1'u64 shl 32) - 1,
              1'u64 shl 32, AbsoluteRankMask]:
  var entry: RankPrefixEntry
  entry.setAbsoluteRank(value)
  doAssert entry.absoluteRank == value

var entry: RankPrefixEntry
entry.setAbsoluteRank(1'u64 shl 32)
for subblock in 1..7:
  for value in [0'u64, 1, 511, 512, 1023, 2047, 3584, 4095]:
    let absolute = entry.absoluteRank
    entry.setRelativeRank(subblock, value)
    doAssert entry.relativeRank(subblock) == value
    doAssert entry.absoluteRank == absolute

doAssert entry.relativeRank(0) == 0
doAssert (entry.lo shr 57) == 0
doAssert (entry.hi shr 60) == 0
echo "OK packed prefix entry"
