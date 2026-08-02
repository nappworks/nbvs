const
  AbsoluteRankBits* = 33
  RelativeRankBits* = 12
  AbsoluteRankMask* = (1'u64 shl AbsoluteRankBits) - 1
  RelativeRankMask* = (1'u64 shl RelativeRankBits) - 1

type
  RankPrefixEntry* = object
    ## 実験用の128-bit packed rank prefixです。
    lo*: uint64
    hi*: uint64

func setAbsoluteRank*(entry: var RankPrefixEntry, value: uint64) {.inline.} =
  ## 33-bitの絶対rankを格納します。
  doAssert value <= AbsoluteRankMask
  entry.lo = (entry.lo and not AbsoluteRankMask) or value

func absoluteRank*(entry: RankPrefixEntry): uint64 {.inline.} =
  ## 格納された絶対rankを返します。
  entry.lo and AbsoluteRankMask

func setRelativeRank*(entry: var RankPrefixEntry, subblock: int,
                      value: uint64) {.inline.} =
  ## `subblock` 1..7の12-bit相対rankを格納します。
  doAssert value <= RelativeRankMask
  case subblock
  of 1:
    entry.lo = (entry.lo and not (RelativeRankMask shl 33)) or (value shl 33)
  of 2:
    entry.lo = (entry.lo and not (RelativeRankMask shl 45)) or (value shl 45)
  of 3..7:
    let shift = (subblock - 3) * 12
    entry.hi = (entry.hi and not (RelativeRankMask shl shift)) or (value shl shift)
  else:
    raise newException(IndexDefect, "subblock out of bounds")

func relativeRank*(entry: RankPrefixEntry, subblock: int): uint64 {.inline.} =
  ## `subblock`先頭までの相対rankを返します。subblock 0は0です。
  case subblock
  of 0: 0
  of 1: (entry.lo shr 33) and RelativeRankMask
  of 2: (entry.lo shr 45) and RelativeRankMask
  of 3: entry.hi and RelativeRankMask
  of 4: (entry.hi shr 12) and RelativeRankMask
  of 5: (entry.hi shr 24) and RelativeRankMask
  of 6: (entry.hi shr 36) and RelativeRankMask
  of 7: (entry.hi shr 48) and RelativeRankMask
  else: raise newException(IndexDefect, "subblock out of bounds")
