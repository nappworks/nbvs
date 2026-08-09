## portable scalar backendと任意のAVX2/BMI2 backendを持つsuccinct bit vectorです。
##
## `SuccinctBitVector` supports constant-time `access`, fast `rank`, and fast
## `select` over a mutable bit vector after `build` has created the rank/select
## dictionary.
##
## Semantics:
##
## * `rank1(pos)` returns the number of `1` bits in `[0, pos)`.
## * `rank0(pos)` returns the number of `0` bits in `[0, pos)`.
## * `select1(k)` and `select0(k)` are 0-based and return `-1` when `k` is out
##   of range.
## * `rank1Incl(pos)` and `rank0Incl(pos)` use the closed interval `[0, pos]`.
##
## デフォルトではportable scalar実装を使用します。`nbvsSimd` をdefineすると、
## 512-bit blockのpopcount/select scanにAVX2を使用し、64-bit word内の
## selectにBMI2の `PDEP` を使用します。
import std/bitops

when defined(nbvsSimd):
  {.pragma: selectInline, inline.}
else:
  {.pragma: selectInline.}

when defined(nbvsSimd):
  when defined(gcc) or defined(clang):
    {.localPassc: "-mavx2".}
    {.localPassc: "-mbmi2".}

  when defined(vcc):
    {.localPassc: "/arch:AVX2".}

  import ./internal/x86_intrinsics

const
  L1* = 512'i64
  L2* = 8192'i64
  L3* = 65536'i64
  L4* = 524288'i64
  L5* = 4194304'i64
  L6* = 33554432'i64
  L7* = 268435456'i64
  L8* = 2147483648'i64

when defined(nbvsSimd):
  const
    PopcountNibbleLookup = [
      0'i8, 1'i8, 1'i8, 2'i8,
      1'i8, 2'i8, 2'i8, 3'i8,
      1'i8, 2'i8, 2'i8, 3'i8,
      2'i8, 3'i8, 3'i8, 4'i8,

      0'i8, 1'i8, 1'i8, 2'i8,
      1'i8, 2'i8, 2'i8, 3'i8,
      1'i8, 2'i8, 2'i8, 3'i8,
      2'i8, 3'i8, 3'i8, 4'i8
    ]
    LowNibbleMaskBytes = [
      0x0f'i8, 0x0f'i8, 0x0f'i8, 0x0f'i8,
      0x0f'i8, 0x0f'i8, 0x0f'i8, 0x0f'i8,
      0x0f'i8, 0x0f'i8, 0x0f'i8, 0x0f'i8,
      0x0f'i8, 0x0f'i8, 0x0f'i8, 0x0f'i8,
      0x0f'i8, 0x0f'i8, 0x0f'i8, 0x0f'i8,
      0x0f'i8, 0x0f'i8, 0x0f'i8, 0x0f'i8,
      0x0f'i8, 0x0f'i8, 0x0f'i8, 0x0f'i8,
      0x0f'i8, 0x0f'i8, 0x0f'i8, 0x0f'i8
    ]
    L1ZeroOffsetsI16 = [
      0'i16, 512'i16, 1024'i16, 1536'i16,
      2048'i16, 2560'i16, 3072'i16, 3584'i16,
      4096'i16, 4608'i16, 5120'i16, 5632'i16,
      6144'i16, 6656'i16, 7168'i16, 7680'i16
    ]
    L2ZeroOffsetsI32 = [
      0'i32, 8192'i32, 16384'i32, 24576'i32,
      32768'i32, 40960'i32, 49152'i32, 57344'i32
    ]
    L3ZeroOffsetsI32 = [
      0'i32, 65536'i32, 131072'i32, 196608'i32,
      262144'i32, 327680'i32, 393216'i32, 458752'i32
    ]
    L4ZeroOffsetsI32 = [
      0'i32, 524288'i32, 1048576'i32, 1572864'i32,
      2097152'i32, 2621440'i32, 3145728'i32, 3670016'i32
    ]
    L5ZeroOffsetsI32 = [
      0'i32, 4194304'i32, 8388608'i32, 12582912'i32,
      16777216'i32, 20971520'i32, 25165824'i32, 29360128'i32
    ]
    L6ZeroOffsetsI32 = [
      0'i32, 33554432'i32, 67108864'i32, 100663296'i32,
      134217728'i32, 167772160'i32, 201326592'i32, 234881024'i32
    ]
    L7ZeroOffsetsI32 = [
      0'i32, 268435456'i32, 536870912'i32, 805306368'i32,
      1073741824'i32, 1342177280'i32, 1610612736'i32, 1879048192'i32
    ]

type
  SuccinctBitVector* = object
    ## Rank/select-capable bit vector.
    maxOfBits*: int64 ## Maximum number of addressable bits.
    lenOfBits*: int64 ## Logical bit length.

    data*: seq[uint64] ## Raw little-endian word storage. Exposed for diagnostics and tests.
    dataWords*: int ## Number of logical words used by `lenOfBits`.

    level*: int8 ## Highest StartPrefix level used for this vector length.
    isCalced*: bool ## Whether the rank/select dictionary has been built.
    totalOnes*: int64 ## Total number of one bits after `build`.
    totalZeros*: int64 ## Total number of zero bits after `build`.

    # Absolute one-bit count at the start of each 1024-bit pair of blocks.
    # Together with the StartPrefix hierarchy this stays below 7% of raw data.
    # Vectors whose absolute count may not fit uint32 use the hierarchy only.
    blockPairPrefix*: seq[uint32]

    # 512-bit block内で、2 wordごとのone-bit累積数をpackして保持する。
    # rank query時のpopcountを最大1 wordへ抑えるための補助領域。
    wordPairPrefix*: seq[uint32] ## Scalar rank用のpacked word-pair prefix。

    level1Len*: int
    level2Len*: int
    level3Len*: int
    level4Len*: int
    level5Len*: int
    level6Len*: int
    level7Len*: int
    level8Len*: int

    # Select prefixes in depth-first subtree order. Every node occupies one
    # 32-byte AVX2-sized slot: 16 x int16 at level 1, 8 x int32 at levels
    # 2..7, or 4 x int64 at level 8. This replaces the former per-level seqs
    # without increasing the padded prefix memory.
    selectStorage*: seq[uint64]

const
  SelectNodeWords = 4
  SelectFullSubtreeWords = [
    0,                         # unused level 0
    SelectNodeWords,           # level 1
    SelectNodeWords + 8 * 4,   # level 2
    SelectNodeWords + 8 * 36,
    SelectNodeWords + 8 * 292,
    SelectNodeWords + 8 * 2340,
    SelectNodeWords + 8 * 18724,
    SelectNodeWords + 8 * 149796,
    SelectNodeWords + 4 * 1198372
  ]

func levelBlockSize(level: int): int64 {.inline.} =
  case level
  of 1: L1
  of 2: L2
  of 3: L3
  of 4: L4
  of 5: L5
  of 6: L6
  of 7: L7
  else: L8

func levelFanout(level: int): int {.inline.} =
  if level == 1: 16
  elif level == 8: 4
  else: 8

func selectNodeWordOffset(sbv: SuccinctBitVector, wantedLevel, entryIdx: int): int =
  ## Locates a level entry in the depth-first Select tree.
  let bitStart = int64(entryIdx) * levelBlockSize(wantedLevel)
  var currentLevel = int(sbv.level)
  var nodeWord = 0
  while currentLevel > wantedLevel:
    let lane = int((bitStart div levelBlockSize(currentLevel)) mod
                   int64(levelFanout(currentLevel)))
    dec currentLevel
    nodeWord += SelectNodeWords + lane * SelectFullSubtreeWords[currentLevel]
  result = nodeWord

func level1Ptr(sbv: SuccinctBitVector, entryIdx: int): ptr int16 {.inline.} =
  let nodeWord = sbv.selectNodeWordOffset(1, entryIdx)
  result = cast[ptr int16](unsafeAddr sbv.selectStorage[nodeWord])

func levelI32Ptr(sbv: SuccinctBitVector, level, entryIdx: int): ptr int32 {.inline.} =
  let nodeWord = sbv.selectNodeWordOffset(level, entryIdx)
  result = cast[ptr int32](unsafeAddr sbv.selectStorage[nodeWord])

func level8Ptr(sbv: SuccinctBitVector): ptr int64 {.inline.} =
  cast[ptr int64](unsafeAddr sbv.selectStorage[0])

func level1At(sbv: SuccinctBitVector, idx: int): int16 {.inline.} =
  cast[ptr UncheckedArray[int16]](sbv.level1Ptr(idx))[idx and 15]

func levelI32At(sbv: SuccinctBitVector, level, idx: int): int32 {.inline.} =
  cast[ptr UncheckedArray[int32]](sbv.levelI32Ptr(level, idx))[idx and 7]

func level8At(sbv: SuccinctBitVector, idx: int): int64 {.inline.} =
  cast[ptr UncheckedArray[int64]](sbv.level8Ptr())[idx]

func setLevelI32(sbv: var SuccinctBitVector, level, idx: int, value: int32) {.inline.} =
  cast[ptr UncheckedArray[int32]](sbv.levelI32Ptr(level, idx))[idx and 7] = value

func setLevel8(sbv: var SuccinctBitVector, idx: int, value: int64) {.inline.} =
  cast[ptr UncheckedArray[int64]](sbv.level8Ptr())[idx] = value

func ceilDiv*[T: SomeInteger](x, y: T): T =
  ## Returns `ceil(x / y)` for integer values. Returns `0` when `x <= 0`.
  if x <= 0:
    return 0
  result = (x + y - 1) div y

func alignUp*(x, a: int64): int64 =
  ## Rounds `x` up to the nearest multiple of `a`.
  if x <= 0:
    return 0
  result = ceilDiv(x, a) * a

func calcLevel*(maxBits: int64): int8 =
  ## Returns the StartPrefix level needed for `maxBits`, or `-1` when unsupported.
  case maxBits
  of 0'i64..512'i64:
    0
  of 513'i64..8192'i64:
    1
  of 8193'i64..65536'i64:
    2
  of 65537'i64..524288'i64:
    3
  of 524289'i64..4194304'i64:
    4
  of 4194305'i64..33554432'i64:
    5
  of 33554433'i64..268435456'i64:
    6
  of 268435457'i64..2147483648'i64:
    7
  of 2147483649'i64..8589934592'i64:
    8
  else:
    -1

func resetLevelPadding(sbv: var SuccinctBitVector) =
  # 論理entryはbuildで必ず上書きされるため、select走査が読む末尾paddingだけを
  # sentinelへ戻し、再build時の全tree初期化を避ける。
  if sbv.level >= 1:
    let paddedLen = int(alignUp(int64(sbv.level1Len), 16'i64))
    if sbv.level1Len < paddedLen:
      let i = sbv.level1Len
      let nodeWord = sbv.selectNodeWordOffset(1, i)
      let values = cast[ptr UncheckedArray[int16]](
        unsafeAddr sbv.selectStorage[nodeWord])
      for j in (i and 15)..<16:
        values[j] = int16.high
  if sbv.level >= 2:
    for level in 2..min(int(sbv.level), 7):
      let logicalLen = case level
        of 2: sbv.level2Len
        of 3: sbv.level3Len
        of 4: sbv.level4Len
        of 5: sbv.level5Len
        of 6: sbv.level6Len
        else: sbv.level7Len
      let paddedLen = int(alignUp(int64(logicalLen), 8'i64))
      for i in logicalLen..<paddedLen:
        sbv.setLevelI32(level, i, int32.high)
  if sbv.level >= 8:
    for i in sbv.level8Len..<4:
      sbv.setLevel8(i, int64.high)

func genSuccinctBitVector*(maxBits: int64): SuccinctBitVector =
  ## Creates a mutable succinct bit vector with `maxBits` addressable bits.
  if maxBits < 0:
    raise newException(ValueError, "maxBits must be non-negative")

  let lv = calcLevel(maxBits)
  if lv < 0:
    raise newException(ValueError, "maxBits exceeds 8,589,934,592 bits")

  result.maxOfBits = maxBits
  result.lenOfBits = maxBits
  result.level = lv
  result.isCalced = false
  result.totalOnes = 0
  result.totalZeros = maxBits

  result.dataWords = int(ceilDiv(maxBits, 64'i64))
  result.data = newSeq[uint64](int(alignUp(int64(result.dataWords), 8'i64)))
  when not defined(nbvsSimd):
    result.wordPairPrefix = newSeq[uint32](int(ceilDiv(maxBits, L1)))
  when defined(nbvsSimd):
    if maxBits > L5 and maxBits <= int64(uint32.high):
      result.blockPairPrefix = newSeq[uint32](int(ceilDiv(maxBits, L1 * 2)))

  result.level1Len = int(ceilDiv(maxBits, L1))
  result.level2Len = int(ceilDiv(maxBits, L2))
  result.level3Len = int(ceilDiv(maxBits, L3))
  result.level4Len = int(ceilDiv(maxBits, L4))
  result.level5Len = int(ceilDiv(maxBits, L5))
  result.level6Len = int(ceilDiv(maxBits, L6))
  result.level7Len = int(ceilDiv(maxBits, L7))
  result.level8Len = int(ceilDiv(maxBits, L8))

  if lv >= 1:
    var nodeCount = ceilDiv(result.level1Len, 16)
    if lv >= 2: nodeCount += ceilDiv(result.level2Len, 8)
    if lv >= 3: nodeCount += ceilDiv(result.level3Len, 8)
    if lv >= 4: nodeCount += ceilDiv(result.level4Len, 8)
    if lv >= 5: nodeCount += ceilDiv(result.level5Len, 8)
    if lv >= 6: nodeCount += ceilDiv(result.level6Len, 8)
    if lv >= 7: nodeCount += ceilDiv(result.level7Len, 8)
    if lv >= 8: inc nodeCount
    result.selectStorage = newSeq[uint64](nodeCount * SelectNodeWords)

  result.resetLevelPadding()

func estimateSuccinctBitVectorBytes*(bitLength: int64): int64 =
  ## 指定bit長の`SuccinctBitVector`が保持する配列容量をbyte単位で推定します。
  ##
  ## 現在のscalar/SIMD backendが`genSuccinctBitVector`で確保するraw data、
  ## rank補助配列、select treeを同じpadding規則で計算します。
  if bitLength < 0:
    raise newException(ValueError, "bitLength must be non-negative")
  let level = calcLevel(bitLength)
  if level < 0:
    raise newException(ValueError, "bitLength exceeds supported range")
  let dataWords = alignUp(ceilDiv(bitLength, 64'i64), 8'i64)
  result = dataWords * int64(sizeof(uint64))
  when not defined(nbvsSimd):
    result += ceilDiv(bitLength, L1) * int64(sizeof(uint32))
  when defined(nbvsSimd):
    if bitLength > L5 and bitLength <= int64(uint32.high):
      result += ceilDiv(bitLength, L1 * 2) * int64(sizeof(uint32))

  if level >= 1:
    let level1Len = ceilDiv(bitLength, L1)
    let level2Len = ceilDiv(bitLength, L2)
    let level3Len = ceilDiv(bitLength, L3)
    let level4Len = ceilDiv(bitLength, L4)
    let level5Len = ceilDiv(bitLength, L5)
    let level6Len = ceilDiv(bitLength, L6)
    let level7Len = ceilDiv(bitLength, L7)
    var nodeCount = ceilDiv(level1Len, 16)
    if level >= 2: nodeCount += ceilDiv(level2Len, 8)
    if level >= 3: nodeCount += ceilDiv(level3Len, 8)
    if level >= 4: nodeCount += ceilDiv(level4Len, 8)
    if level >= 5: nodeCount += ceilDiv(level5Len, 8)
    if level >= 6: nodeCount += ceilDiv(level6Len, 8)
    if level >= 7: nodeCount += ceilDiv(level7Len, 8)
    if level >= 8: inc nodeCount
    result += nodeCount * SelectNodeWords.int64 * int64(sizeof(uint64))

func checkPos(sbv: SuccinctBitVector, pos: int64) =
  if pos < 0 or pos >= sbv.lenOfBits:
    raise newException(IndexDefect, "Index out of bounds")

func access*(sbv: SuccinctBitVector, pos: int64): bool =
  ## Returns the bit at `pos`.
  sbv.checkPos(pos)
  let wordIdx = int(pos div 64)
  let bitIdx = int(pos mod 64)
  result = sbv.data[wordIdx].testBit(bitIdx)

func `[]`*(sbv: SuccinctBitVector, pos: int64): bool =
  ## Alias for `access(sbv, pos)`.
  result = sbv.access(pos)

func setBit*(sbv: var SuccinctBitVector, pos: int64) =
  ## Sets the bit at `pos` to `1` and marks the dictionary stale.
  sbv.checkPos(pos)
  let wordIdx = int(pos div 64)
  let bitIdx = int(pos mod 64)
  sbv.data[wordIdx].setBit(bitIdx)
  sbv.isCalced = false

func clearBit*(sbv: var SuccinctBitVector, pos: int64) =
  ## Clears the bit at `pos` to `0` and marks the dictionary stale.
  sbv.checkPos(pos)
  let wordIdx = int(pos div 64)
  let bitIdx = int(pos mod 64)
  sbv.data[wordIdx].clearBit(bitIdx)
  sbv.isCalced = false

func `[]=`*(sbv: var SuccinctBitVector, pos: int64, b: bool) =
  ## Writes a boolean bit at `pos`.
  if b:
    sbv.setBit(pos)
  else:
    sbv.clearBit(pos)

func `$`*(sbv: SuccinctBitVector): string =
  ## Returns the logical bit string from index `0` to `lenOfBits - 1`.
  for i in 0'i64..<sbv.lenOfBits:
    result.add(if sbv[i]: "1" else: "0")

func logicalLevel1*(sbv: SuccinctBitVector): seq[int16] =
  ## Returns the logical, unpadded level-1 StartPrefix array.
  if sbv.level >= 1:
    result = newSeq[int16](sbv.level1Len)
    for i in 0..<result.len: result[i] = sbv.level1At(i)

func logicalLevel2*(sbv: SuccinctBitVector): seq[int32] =
  ## Returns the logical, unpadded level-2 StartPrefix array.
  if sbv.level >= 2:
    result = newSeq[int32](sbv.level2Len)
    for i in 0..<result.len: result[i] = sbv.levelI32At(2, i)

func logicalLevel3*(sbv: SuccinctBitVector): seq[int32] =
  ## Returns the logical, unpadded level-3 StartPrefix array.
  if sbv.level >= 3:
    result = newSeq[int32](sbv.level3Len)
    for i in 0..<result.len: result[i] = sbv.levelI32At(3, i)

func logicalLevel4*(sbv: SuccinctBitVector): seq[int32] =
  ## Returns the logical, unpadded level-4 StartPrefix array.
  if sbv.level >= 4:
    result = newSeq[int32](sbv.level4Len)
    for i in 0..<result.len: result[i] = sbv.levelI32At(4, i)

func logicalLevel5*(sbv: SuccinctBitVector): seq[int32] =
  ## Returns the logical, unpadded level-5 StartPrefix array.
  if sbv.level >= 5:
    result = newSeq[int32](sbv.level5Len)
    for i in 0..<result.len: result[i] = sbv.levelI32At(5, i)

func logicalLevel6*(sbv: SuccinctBitVector): seq[int32] =
  ## Returns the logical, unpadded level-6 StartPrefix array.
  if sbv.level >= 6:
    result = newSeq[int32](sbv.level6Len)
    for i in 0..<result.len: result[i] = sbv.levelI32At(6, i)

func logicalLevel7*(sbv: SuccinctBitVector): seq[int32] =
  ## Returns the logical, unpadded level-7 StartPrefix array.
  if sbv.level >= 7:
    result = newSeq[int32](sbv.level7Len)
    for i in 0..<result.len: result[i] = sbv.levelI32At(7, i)

func logicalLevel8*(sbv: SuccinctBitVector): seq[int64] =
  ## Returns the logical, unpadded level-8 StartPrefix array.
  if sbv.level >= 8:
    result = newSeq[int64](sbv.level8Len)
    for i in 0..<result.len: result[i] = sbv.level8At(i)

when defined(nbvsSimd):
  func popcount64Lanes256*(x: M256i): M256i =
    ## Computes popcount for four 64-bit lanes in a 256-bit vector.
    let lookup = mm256_loadu_si256(cast[ptr M256i](unsafeAddr PopcountNibbleLookup[0]))
    let lowMask = mm256_loadu_si256(cast[ptr M256i](unsafeAddr LowNibbleMaskBytes[0]))

    let lo = mm256_and_si256(x, lowMask)
    let hi = mm256_and_si256(mm256_srli_epi16(x, 4), lowMask)

    let pcLo = mm256_shuffle_epi8(lookup, lo)
    let pcHi = mm256_shuffle_epi8(lookup, hi)
    let pcBytes = mm256_add_epi8(pcLo, pcHi)

    let zero = mm256_xor_si256(x, x)
    result = mm256_sad_epu8(pcBytes, zero)

func popcount512At*(sbv: SuccinctBitVector, baseBit: int64): int64 =
  ## Returns the number of one bits in the 512-bit block starting at `baseBit`.
  when defined(nbvsSimd):
    let startWord = int(baseBit div 64)
    let v0 = mm256_loadu_si256(cast[ptr M256i](addr sbv.data[startWord]))
    let v1 = mm256_loadu_si256(cast[ptr M256i](addr sbv.data[startWord + 4]))

    let pc0 = popcount64Lanes256(v0)
    let pc1 = popcount64Lanes256(v1)

    var c0 {.align: 32.}: array[4, uint64]
    var c1 {.align: 32.}: array[4, uint64]

    mm256_storeu_si256(cast[ptr M256i](addr c0[0]), pc0)
    mm256_storeu_si256(cast[ptr M256i](addr c1[0]), pc1)

    result = int64(c0[0] + c0[1] + c0[2] + c0[3] +
                   c1[0] + c1[1] + c1[2] + c1[3])
  else:
    let startWord = int(baseBit div 64)
    for j in 0..<8:
      result += int64(countSetBits(sbv.data[startWord + j]))

func buildWordPairPrefix(sbv: var SuccinctBitVector,
                         baseBit: int64): int64 =
  let startWord = int(baseBit shr 6)
  var counts: array[8, uint32]
  for i in 0..<8:
    counts[i] = uint32(countSetBits(sbv.data[startWord + i]))

  let prefix2 = counts[0] + counts[1]
  let prefix4 = prefix2 + counts[2] + counts[3]
  let prefix6 = prefix4 + counts[4] + counts[5]
  sbv.wordPairPrefix[int(baseBit shr 9)] =
    prefix2 or (prefix4 shl 8) or (prefix6 shl 17)
  for count in counts:
    result += int64(count)

func build*(sbv: var SuccinctBitVector) =
  ## Builds or rebuilds the rank/select dictionary.
  sbv.resetLevelPadding()

  template buildForLevel(maxLevel: static[int]) =
    var total = 0'i64
    var bitPos = 0'i64
    when maxLevel >= 1:
      var p1 = 0
      var base2 = 0'i64
      var level1NodeWord = 0
    when maxLevel >= 2:
      var p2 = 0
      var blockInL2 = 0
      var base3 = 0'i64
    when maxLevel >= 3:
      var p3 = 0
      var blockInL3 = 0
      var base4 = 0'i64
    when maxLevel >= 4:
      var p4 = 0
      var blockInL4 = 0
      var base5 = 0'i64
    when maxLevel >= 5:
      var p5 = 0
      var blockInL5 = 0
      var base6 = 0'i64
    when maxLevel >= 6:
      var p6 = 0
      var blockInL6 = 0
      var base7 = 0'i64
    when maxLevel >= 7:
      var p7 = 0
      var blockInL7 = 0
      var base8 = 0'i64
    when maxLevel >= 8:
      var p8 = 0
      var blockInL8 = 0

    while bitPos < sbv.lenOfBits:
      if sbv.blockPairPrefix.len > 0 and (bitPos and 1023'i64) == 0:
        sbv.blockPairPrefix[int(bitPos shr 10)] = uint32(total)

      when maxLevel >= 8:
        if blockInL8 == 0:
          sbv.setLevel8(p8, total)
          base8 = total

      when maxLevel >= 7:
        if blockInL7 == 0:
          sbv.setLevelI32(7, p7, int32(total - base8))
          base7 = total

      when maxLevel >= 6:
        if blockInL6 == 0:
          sbv.setLevelI32(6, p6, int32(total - base7))
          base6 = total

      when maxLevel >= 5:
        if blockInL5 == 0:
          sbv.setLevelI32(5, p5, int32(total - base6))
          base5 = total

      when maxLevel >= 4:
        if blockInL4 == 0:
          sbv.setLevelI32(4, p4, int32(total - base5))
          base4 = total

      when maxLevel >= 3:
        if blockInL3 == 0:
          sbv.setLevelI32(3, p3, int32(total - base4))
          base3 = total

      when maxLevel >= 2:
        if blockInL2 == 0:
          sbv.setLevelI32(2, p2, int32(total - base3))
          base2 = total

      when maxLevel >= 1:
        if (p1 and 15) == 0:
          level1NodeWord = sbv.selectNodeWordOffset(1, p1)
        cast[ptr UncheckedArray[int16]](
          unsafeAddr sbv.selectStorage[level1NodeWord])[p1 and 15] =
            int16(total - base2)

      when defined(nbvsSimd):
        total += sbv.popcount512At(bitPos)
      else:
        total += sbv.buildWordPairPrefix(bitPos)
      bitPos += L1

      when maxLevel >= 1:
        inc p1

      when maxLevel >= 2:
        inc blockInL2
        if blockInL2 == 16:
          blockInL2 = 0
          inc p2

      when maxLevel >= 3:
        inc blockInL3
        if blockInL3 == 128:
          blockInL3 = 0
          inc p3

      when maxLevel >= 4:
        inc blockInL4
        if blockInL4 == 1024:
          blockInL4 = 0
          inc p4

      when maxLevel >= 5:
        inc blockInL5
        if blockInL5 == 8192:
          blockInL5 = 0
          inc p5

      when maxLevel >= 6:
        inc blockInL6
        if blockInL6 == 65536:
          blockInL6 = 0
          inc p6

      when maxLevel >= 7:
        inc blockInL7
        if blockInL7 == 524288:
          blockInL7 = 0
          inc p7

      when maxLevel >= 8:
        inc blockInL8
        if blockInL8 == 4194304:
          blockInL8 = 0
          inc p8

    sbv.totalOnes = total
    sbv.totalZeros = sbv.lenOfBits - total
    sbv.isCalced = true

  case int(sbv.level)
  of 0: buildForLevel(0)
  of 1: buildForLevel(1)
  of 2: buildForLevel(2)
  of 3: buildForLevel(3)
  of 4: buildForLevel(4)
  of 5: buildForLevel(5)
  of 6: buildForLevel(6)
  of 7: buildForLevel(7)
  else: buildForLevel(8)

func rankIn512Block*(sbv: SuccinctBitVector, pos: int64): int64 =
  ## Returns the number of one bits before `pos` within its 512-bit block.
  if pos < 0 or pos > sbv.lenOfBits:
    raise newException(IndexDefect, "Index out of bounds")

  let startWord = int((pos shr 9) shl 3)
  let inBlock = int(pos and (L1 - 1))
  let wordOffset = inBlock shr 6
  let bitOffset = inBlock and 63
  when defined(nbvsSimd):
    for wordIndex in 0..<wordOffset:
      result += int64(countSetBits(sbv.data[startWord + wordIndex]))
  else:
    let packed = sbv.wordPairPrefix[int(pos shr 9)]
    case wordOffset
    of 0:
      discard
    of 1:
      result = int64(countSetBits(sbv.data[startWord]))
    of 2:
      result = int64(packed and 0xff'u32)
    of 3:
      result = int64(packed and 0xff'u32) +
        int64(countSetBits(sbv.data[startWord + 2]))
    of 4:
      result = int64((packed shr 8) and 0x1ff'u32)
    of 5:
      result = int64((packed shr 8) and 0x1ff'u32) +
        int64(countSetBits(sbv.data[startWord + 4]))
    of 6:
      result = int64((packed shr 17) and 0x1ff'u32)
    else:
      result = int64((packed shr 17) and 0x1ff'u32) +
        int64(countSetBits(sbv.data[startWord + 6]))

  if bitOffset > 0:
    let partialMask = (1'u64 shl bitOffset) - 1'u64
    result += int64(countSetBits(
      sbv.data[startWord + wordOffset] and partialMask))

func rank1Unchecked*(sbv: SuccinctBitVector, pos: int64): int64 =
  ## 検査なしで半開区間 `[0, pos)` のone bit数を返します。
  ##
  ## `build` 済みであり、`0 <= pos <= lenOfBits` を満たす場合だけ
  ## 使用できます。通常は安全な `rank1` を使用してください。
  if pos == 0:
    return 0
  if pos == sbv.lenOfBits:
    return sbv.totalOnes

  if sbv.blockPairPrefix.len > 0:
    let blockIdx = int(pos shr 9)
    result = int64(sbv.blockPairPrefix[blockIdx shr 1])
    if (blockIdx and 1) != 0:
      result += sbv.popcount512At(int64(blockIdx - 1) * L1)
    result += sbv.rankIn512Block(pos)
    return

  template rankFromSelectTree(maxLevel: static[int]) =
    var nodeWord = 0
    template addI32Level(levelNum: static[int], shift: static[int]) =
      when maxLevel >= levelNum:
        let lane = int((pos shr shift) and 7)
        let vals = cast[ptr UncheckedArray[int32]](unsafeAddr sbv.selectStorage[nodeWord])
        result += int64(vals[lane])
        nodeWord += SelectNodeWords + lane * SelectFullSubtreeWords[levelNum - 1]

    when maxLevel >= 8:
      let lane8 = int((pos shr 31) and 3)
      let vals8 = cast[ptr UncheckedArray[int64]](unsafeAddr sbv.selectStorage[nodeWord])
      result += vals8[lane8]
      nodeWord += SelectNodeWords + lane8 * SelectFullSubtreeWords[7]
    addI32Level(7, 28)
    addI32Level(6, 25)
    addI32Level(5, 22)
    addI32Level(4, 19)
    addI32Level(3, 16)
    addI32Level(2, 13)
    when maxLevel >= 1:
      let lane1 = int((pos shr 9) and 15)
      let vals1 = cast[ptr UncheckedArray[int16]](unsafeAddr sbv.selectStorage[nodeWord])
      result += int64(vals1[lane1])

  case int(sbv.level)
  of 0: discard
  of 1: rankFromSelectTree(1)
  of 2: rankFromSelectTree(2)
  of 3: rankFromSelectTree(3)
  of 4: rankFromSelectTree(4)
  of 5: rankFromSelectTree(5)
  of 6: rankFromSelectTree(6)
  of 7: rankFromSelectTree(7)
  else: rankFromSelectTree(8)
  result += sbv.rankIn512Block(pos)

func rank1*(sbv: SuccinctBitVector, pos: int64): int64 {.inline.} =
  ## Returns the number of one bits in the half-open range `[0, pos)`.
  if not sbv.isCalced:
    raise newException(ValueError, "rank dictionary is not built")
  if pos < 0 or pos > sbv.lenOfBits:
    raise newException(IndexDefect, "Index out of bounds")
  result = sbv.rank1Unchecked(pos)

func rank0*(sbv: SuccinctBitVector, pos: int64): int64 =
  ## Returns the number of zero bits in the half-open range `[0, pos)`.
  result = pos - sbv.rank1(pos)

func rank1Incl*(sbv: SuccinctBitVector, pos: int64): int64 =
  ## Returns the number of one bits in the closed range `[0, pos]`.
  sbv.checkPos(pos)
  result = sbv.rank1(pos + 1)

func rank0Incl*(sbv: SuccinctBitVector, pos: int64): int64 =
  ## Returns the number of zero bits in the closed range `[0, pos]`.
  sbv.checkPos(pos)
  result = sbv.rank0(pos + 1)

when defined(nbvsSimd):
  func highestSetBitIndex32(mask: int32): int =
    let m = uint32(mask)
    result = 31 - countLeadingZeroBits(m)

  func validMaskI16Lanes(validCount: int): int32 {.inline.} =
    if validCount >= 16:
      return 0x55555555'i32
    var m = 0'i32
    for i in 0..<validCount:
      m = m or (1'i32 shl (i * 2))
    result = m

  func validMaskI32Lanes(validCount: int): int32 {.inline.} =
    if validCount >= 8:
      return 0xff'i32
    result = (1'i32 shl validCount) - 1'i32

func selectChildOnesL1x16*(p: ptr int16, target: int16, validCount = 16): int =
  ## Selects the child block containing a one-bit target from 16 int16 prefixes.
  when defined(nbvsSimd):
    let vals = mm256_loadu_si256(cast[ptr M256i](p))
    let t = mm256_set1_epi16(target)
    let cmp = mm256_cmpgt_epi16(t, vals)
    let byteMask = mm256_movemask_epi8(cmp)
    let laneMask = (byteMask and 0x55555555'i32) and validMaskI16Lanes(validCount)
    result = highestSetBitIndex32(laneMask) div 2
  else:
    let vals = cast[ptr UncheckedArray[int16]](p)
    result = 0
    for i in 0..<validCount:
      if vals[i] < target:
        result = i

func selectChildOnesI32x8*(p: ptr int32, target: int32, validCount = 8): int =
  ## Selects the child block containing a one-bit target from 8 int32 prefixes.
  when defined(nbvsSimd):
    let vals = mm256_loadu_si256(cast[ptr M256i](p))
    let t = mm256_set1_epi32(target)
    let cmp = mm256_cmpgt_epi32(t, vals)
    let mask = (mm256_movemask_ps(mm256_castsi256_ps(cmp)) and 0xff) and
               validMaskI32Lanes(validCount)
    result = highestSetBitIndex32(mask)
  else:
    let vals = cast[ptr UncheckedArray[int32]](p)
    result = 0
    for i in 0..<validCount:
      if vals[i] < target:
        result = i

func selectChildOnesL7x8*(p: ptr int32, target: int64, validCount = 8): int =
  ## Level-7 variant of child selection for one-bit targets.
  if target > int64(int32.high):
    return validCount - 1
  result = selectChildOnesI32x8(p, int32(target), validCount)

func selectChildZerosL1x16*(p: ptr int16, target: int16, validCount = 16): int =
  ## Selects the child block containing a zero-bit target from 16 int16 one-prefixes.
  when defined(nbvsSimd):
    let oneVals = mm256_loadu_si256(cast[ptr M256i](p))
    let offsets = mm256_loadu_si256(cast[ptr M256i](unsafeAddr L1ZeroOffsetsI16[0]))
    let zeroVals = mm256_sub_epi16(offsets, oneVals)
    let t = mm256_set1_epi16(target)
    let cmp = mm256_cmpgt_epi16(t, zeroVals)
    let byteMask = mm256_movemask_epi8(cmp)
    let laneMask = (byteMask and 0x55555555'i32) and validMaskI16Lanes(validCount)
    result = highestSetBitIndex32(laneMask) div 2
  else:
    let vals = cast[ptr UncheckedArray[int16]](p)
    result = 0
    for i in 0..<validCount:
      let zerosBeforeChild = int16(i * int(L1) - int(vals[i]))
      if zerosBeforeChild < target:
        result = i

when defined(nbvsSimd):
  func offsetVecI32x8(childSize: int32): M256i =
    case childSize
    of int32(L2):
      result = mm256_loadu_si256(cast[ptr M256i](unsafeAddr L2ZeroOffsetsI32[0]))
    of int32(L3):
      result = mm256_loadu_si256(cast[ptr M256i](unsafeAddr L3ZeroOffsetsI32[0]))
    of int32(L4):
      result = mm256_loadu_si256(cast[ptr M256i](unsafeAddr L4ZeroOffsetsI32[0]))
    of int32(L5):
      result = mm256_loadu_si256(cast[ptr M256i](unsafeAddr L5ZeroOffsetsI32[0]))
    of int32(L6):
      result = mm256_loadu_si256(cast[ptr M256i](unsafeAddr L6ZeroOffsetsI32[0]))
    of int32(L7):
      result = mm256_loadu_si256(cast[ptr M256i](unsafeAddr L7ZeroOffsetsI32[0]))
    else:
      result = mm256_setr_epi32(
        0'i32,
        childSize,
        childSize * 2,
        childSize * 3,
        childSize * 4,
        childSize * 5,
        childSize * 6,
        childSize * 7
      )

func selectChildZerosI32x8*(p: ptr int32, target: int32, childSize: int32, validCount = 8): int =
  ## Selects the child block containing a zero-bit target from 8 int32 one-prefixes.
  when defined(nbvsSimd):
    let oneVals = mm256_loadu_si256(cast[ptr M256i](p))
    let offsets = offsetVecI32x8(childSize)
    let zeroVals = mm256_sub_epi32(offsets, oneVals)
    let t = mm256_set1_epi32(target)
    let cmp = mm256_cmpgt_epi32(t, zeroVals)
    let mask = (mm256_movemask_ps(mm256_castsi256_ps(cmp)) and 0xff) and
               validMaskI32Lanes(validCount)
    result = highestSetBitIndex32(mask)
  else:
    let vals = cast[ptr UncheckedArray[int32]](p)
    result = 0
    for i in 0..<validCount:
      let zerosBeforeChild = int32(i) * childSize - vals[i]
      if zerosBeforeChild < target:
        result = i

when defined(nbvsSimd):
  # levelをコンパイル時に固定し、zero offset選択の実行時分岐をホットパスから除く。
  # 各配列は8個のint32を持つため、unalignedな256-bit loadでも範囲内に収まる。
  template selectChildZerosForLevel(levelNum: static[int], p: ptr int32,
                                    target: int32, validCount: int): int =
    block:
      let oneVals = mm256_loadu_si256(cast[ptr M256i](p))
      let offsets =
        when levelNum == 2:
          mm256_loadu_si256(cast[ptr M256i](unsafeAddr L2ZeroOffsetsI32[0]))
        elif levelNum == 3:
          mm256_loadu_si256(cast[ptr M256i](unsafeAddr L3ZeroOffsetsI32[0]))
        elif levelNum == 4:
          mm256_loadu_si256(cast[ptr M256i](unsafeAddr L4ZeroOffsetsI32[0]))
        elif levelNum == 5:
          mm256_loadu_si256(cast[ptr M256i](unsafeAddr L5ZeroOffsetsI32[0]))
        elif levelNum == 6:
          mm256_loadu_si256(cast[ptr M256i](unsafeAddr L6ZeroOffsetsI32[0]))
        else:
          mm256_loadu_si256(cast[ptr M256i](unsafeAddr L7ZeroOffsetsI32[0]))
      let zeroVals = mm256_sub_epi32(offsets, oneVals)
      let targets = mm256_set1_epi32(target)
      let compared = mm256_cmpgt_epi32(targets, zeroVals)
      let mask = (mm256_movemask_ps(mm256_castsi256_ps(compared)) and 0xff) and
                 validMaskI32Lanes(validCount)
      highestSetBitIndex32(mask)

func selectChildZerosL7x8*(p: ptr int32, target: int64, validCount = 8): int =
  ## Level-7 variant of child selection for zero-bit targets.
  if target > int64(int32.high):
    return validCount - 1
  result = selectChildZerosI32x8(p, int32(target), int32(L7), validCount)

func selectLevel8OnesX4*(level8: seq[int64], target: int64): int =
  ## Selects a level-8 child for a one-bit target.
  result = 0
  if level8.len > 1 and level8[1] < target: result = 1
  if level8.len > 2 and level8[2] < target: result = 2
  if level8.len > 3 and level8[3] < target: result = 3

func selectLevel8ZerosX4*(level8: seq[int64], target: int64): int =
  ## Selects a level-8 child for a zero-bit target.
  result = 0
  if level8.len > 1 and (1'i64 * L8 - level8[1]) < target: result = 1
  if level8.len > 2 and (2'i64 * L8 - level8[2]) < target: result = 2
  if level8.len > 3 and (3'i64 * L8 - level8[3]) < target: result = 3

func selectInWord64ByClearing*(x: uint64, target: int): int =
  ## Portable fallback for comparison/testing.
  var y = x
  var t = target
  while t > 1:
    y = y and (y - 1)
    dec t
  result = countTrailingZeroBits(y)

func selectInWord64Pdep*(x: uint64, target: int): int =
  ## Selects the 1-indexed `target` set bit in `x`.
  ##
  ## `nbvsSimd` がdefineされている場合はBMI2のPDEPを使用し、それ以外では
  ## portableなbit-clearing実装を使用します。
  when defined(nbvsSimd):
    let one = 1'u64 shl (target - 1)
    let deposited = pdepU64(one, x)
    result = countTrailingZeroBits(deposited)
  else:
    result = selectInWord64ByClearing(x, target)

func selectWordIn512OnesAvx2*(sbv: SuccinctBitVector, baseBit: int64, target: int): tuple[wordOffset: int, rest: int] {.selectInline.} =
  ## Finds the word and residual target for one-bit select within a 512-bit block.
  var t = target
  let startWord = int(baseBit shr 6)
  for j in 0..<8:
    let pc = countSetBits(sbv.data[startWord + j])
    if t > pc:
      t -= pc
    else:
      result.wordOffset = j
      result.rest = t
      return

func selectIn512OnesAvx2*(sbv: SuccinctBitVector, baseBit: int64, target: int): int64 {.selectInline.} =
  ## Selects a one bit within a 512-bit block.
  let selected = sbv.selectWordIn512OnesAvx2(baseBit, target)
  let wordIdx = int(baseBit shr 6) + selected.wordOffset
  let bit = selectInWord64Pdep(sbv.data[wordIdx], selected.rest)
  result = int64(wordIdx) * 64 + int64(bit)

func validMaskForWord(sbv: SuccinctBitVector, wordIdx: int): uint64 {.selectInline.} =
  if wordIdx < 0 or wordIdx >= sbv.dataWords:
    return 0'u64
  let bitStart = int64(wordIdx) * 64
  let remain = sbv.lenOfBits - bitStart
  if remain >= 64:
    uint64.high
  elif remain <= 0:
    0'u64
  else:
    (1'u64 shl int(remain)) - 1'u64

func selectIn512ZerosTail*(sbv: SuccinctBitVector, baseBit: int64, target: int): int64 {.selectInline.} =
  ## Selects a zero bit in a possibly partial trailing 512-bit block.
  var t = target
  let startWord = int(baseBit shr 6)

  for j in 0..<8:
    let wordIdx = startWord + j
    if wordIdx >= sbv.dataWords:
      return -1

    let zeroWord = (not sbv.data[wordIdx]) and sbv.validMaskForWord(wordIdx)
    let pc = countSetBits(zeroWord)

    if t > pc:
      t -= pc
    else:
      let bit = selectInWord64Pdep(zeroWord, t)
      return int64(wordIdx) * 64 + int64(bit)

  result = -1

func selectWordIn512ZerosAvx2*(sbv: SuccinctBitVector, baseBit: int64, target: int): tuple[wordOffset: int, rest: int] {.selectInline.} =
  ## Finds the word and residual target for zero-bit select within a full 512-bit block.
  var t = target
  let startWord = int(baseBit shr 6)
  for j in 0..<8:
    let pc = 64 - countSetBits(sbv.data[startWord + j])
    if t > pc:
      t -= pc
    else:
      result.wordOffset = j
      result.rest = t
      return

func selectIn512ZerosAvx2*(sbv: SuccinctBitVector, baseBit: int64, target: int): int64 {.selectInline.} =
  ## Selects a zero bit within a 512-bit block.
  if baseBit + L1 > sbv.lenOfBits:
    return sbv.selectIn512ZerosTail(baseBit, target)

  let selected = sbv.selectWordIn512ZerosAvx2(baseBit, target)
  let wordIdx = int(baseBit shr 6) + selected.wordOffset
  let zeroWord = not sbv.data[wordIdx]
  let bit = selectInWord64Pdep(zeroWord, selected.rest)
  result = int64(wordIdx) * 64 + int64(bit)

template validChildren(remaining: int64, blockSize: static[int64],
                       shift, fanout: static[int]): int =
  # blockSizeは2の累乗に限定されており、除算を同値なshiftへ置換できる。
  if remaining >= blockSize * int64(fanout):
    fanout
  else:
    int((remaining + blockSize - 1) shr shift)

func select1*(sbv: SuccinctBitVector, k: int64): int64 =
  ## Returns the position of the 0-based `k`-th one bit, or `-1` when out of range.
  if not sbv.isCalced:
    raise newException(ValueError, "rank dictionary is not built")
  if k < 0 or k >= sbv.totalOnes:
    return -1

  var target = k + 1
  var baseBit = 0'i64
  var nodeWord = 0

  if sbv.level >= 8:
    let vals = cast[ptr UncheckedArray[int64]](unsafeAddr sbv.selectStorage[nodeWord])
    var local = 0
    if sbv.level8Len > 1 and vals[1] < target: local = 1
    if sbv.level8Len > 2 and vals[2] < target: local = 2
    if sbv.level8Len > 3 and vals[3] < target: local = 3
    target -= vals[local]
    baseBit += int64(local) * L8
    nodeWord += SelectNodeWords + local * SelectFullSubtreeWords[7]

  if sbv.level >= 7:
    let vals = cast[ptr UncheckedArray[int32]](unsafeAddr sbv.selectStorage[nodeWord])
    let local = selectChildOnesL7x8(addr vals[0], target)
    target -= int64(vals[local])
    baseBit += int64(local) * L7
    nodeWord += SelectNodeWords + local * SelectFullSubtreeWords[6]

  template descendOnes(levelNum: static[int], blockSize: int64) =
    if sbv.level >= levelNum:
      let vals = cast[ptr UncheckedArray[int32]](unsafeAddr sbv.selectStorage[nodeWord])
      let local = selectChildOnesI32x8(addr vals[0], int32(target))
      target -= int64(vals[local])
      baseBit += int64(local) * blockSize
      nodeWord += SelectNodeWords + local * SelectFullSubtreeWords[levelNum - 1]

  descendOnes(6, L6)
  descendOnes(5, L5)
  descendOnes(4, L4)
  descendOnes(3, L3)
  descendOnes(2, L2)

  if sbv.level >= 1:
    let vals = cast[ptr UncheckedArray[int16]](unsafeAddr sbv.selectStorage[nodeWord])
    let local = selectChildOnesL1x16(addr vals[0], int16(target))
    target -= int64(vals[local])
    baseBit += int64(local) * L1

  result = sbv.selectIn512OnesAvx2(baseBit, int(target))

func select0*(sbv: SuccinctBitVector, k: int64): int64 =
  ## Returns the position of the 0-based `k`-th zero bit, or `-1` when out of range.
  if not sbv.isCalced:
    raise newException(ValueError, "rank dictionary is not built")
  if k < 0 or k >= sbv.totalZeros:
    return -1

  var target = k + 1
  var baseBit = 0'i64
  var nodeWord = 0

  if sbv.level >= 8:
    let vals = cast[ptr UncheckedArray[int64]](unsafeAddr sbv.selectStorage[nodeWord])
    var local = 0
    if sbv.level8Len > 1 and (L8 - vals[1]) < target: local = 1
    if sbv.level8Len > 2 and (2'i64 * L8 - vals[2]) < target: local = 2
    if sbv.level8Len > 3 and (3'i64 * L8 - vals[3]) < target: local = 3
    let prevZeros = int64(local) * L8 - vals[local]
    target -= prevZeros
    baseBit += int64(local) * L8
    nodeWord += SelectNodeWords + local * SelectFullSubtreeWords[7]

  if sbv.level >= 7:
    let vals = cast[ptr UncheckedArray[int32]](unsafeAddr sbv.selectStorage[nodeWord])
    let valid =
      when defined(nbvsSimd):
        validChildren(sbv.lenOfBits - baseBit, L7, 28, 8)
      else:
        int(min(8'i64, ceilDiv(sbv.lenOfBits - baseBit, L7)))
    let local =
      when defined(nbvsSimd):
        if target > int64(int32.high):
          valid - 1
        else:
          selectChildZerosForLevel(7, addr vals[0], int32(target), valid)
      else:
        selectChildZerosL7x8(addr vals[0], target, valid)
    let prevZeros = int64(local) * L7 - int64(vals[local])
    target -= prevZeros
    baseBit += int64(local) * L7
    nodeWord += SelectNodeWords + local * SelectFullSubtreeWords[6]

  template descendZeros(levelNum: static[int], blockSize: static[int64],
                        shift: static[int]) =
    if sbv.level >= levelNum:
      let vals = cast[ptr UncheckedArray[int32]](unsafeAddr sbv.selectStorage[nodeWord])
      let valid =
        when defined(nbvsSimd):
          validChildren(sbv.lenOfBits - baseBit, blockSize, shift, 8)
        else:
          int(min(8'i64, ceilDiv(sbv.lenOfBits - baseBit, blockSize)))
      let local =
        when defined(nbvsSimd):
          selectChildZerosForLevel(levelNum, addr vals[0], int32(target), valid)
        else:
          selectChildZerosI32x8(addr vals[0], int32(target), int32(blockSize), valid)
      let prevZeros = int64(local) * blockSize - int64(vals[local])
      target -= prevZeros
      baseBit += int64(local) * blockSize
      nodeWord += SelectNodeWords + local * SelectFullSubtreeWords[levelNum - 1]

  descendZeros(6, L6, 25)
  descendZeros(5, L5, 22)
  descendZeros(4, L4, 19)
  descendZeros(3, L3, 16)
  descendZeros(2, L2, 13)

  if sbv.level >= 1:
    let vals = cast[ptr UncheckedArray[int16]](unsafeAddr sbv.selectStorage[nodeWord])
    let valid =
      when defined(nbvsSimd):
        validChildren(sbv.lenOfBits - baseBit, L1, 9, 16)
      else:
        int(min(16'i64, ceilDiv(sbv.lenOfBits - baseBit, L1)))
    let local = selectChildZerosL1x16(addr vals[0], int16(target), valid)
    let prevZeros = int64(local) * L1 - int64(vals[local])
    target -= prevZeros
    baseBit += int64(local) * L1

  result = sbv.selectIn512ZerosAvx2(baseBit, int(target))

func select1Nth*(sbv: SuccinctBitVector, nth: int64): int64 =
  ## Returns the position of the 1-based `nth` one bit, or `-1` when out of range.
  if nth <= 0: -1 else: sbv.select1(nth - 1)

func select0Nth*(sbv: SuccinctBitVector, nth: int64): int64 =
  ## Returns the position of the 1-based `nth` zero bit, or `-1` when out of range.
  if nth <= 0: -1 else: sbv.select0(nth - 1)
