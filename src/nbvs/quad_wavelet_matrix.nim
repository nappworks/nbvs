## 4-way Wavelet Matrix for unsigned 64-bit integer sequences.
##
## 1 levelで2 bitを処理するため、Binary Wavelet Matrixの半分のlevel数で
## access/rank/selectを辿ります。routing metadataは32 level分を固定配列へ
## inline保持し、query中のlevel descriptor参照を連続化します。
##
## `QuadWaveletMatrixView` は全levelの`QuadVectorView`を1つの64-byte aligned
## external memoryへ連続配置でき、mmapのclose/reopenにも対応します。

import std/bitops
import ./[packed_array, quad_vector, quad_vector_view]

const
  MaxQuadWaveletLevels* = 32
  QuadWaveletRouteWidth = 4
  QuadWaveletRouteBytesPerLevel = QuadWaveletRouteWidth * sizeof(int64)

type
  QuadWaveletMatrix* = object
    ## Heap-owned 4-way Wavelet Matrixです。
    n*: int64
    bitWidth*: int
    levelCount*: int
    ## 最大32 levelなのでdescriptor自体は固定配列にし、level seqの間接参照を避けます。
    levels*: array[MaxQuadWaveletLevels, QuadVector]
    ## 各levelの4 bucket開始位置です。全体で最大1024 byteなのでL1 cache常駐を狙います。
    bucketStarts*: array[MaxQuadWaveletLevels, array[4, int64]]

  QuadWaveletMatrixView* = object
    ## 1つのcaller-owned / mmap領域を参照する非所有4-way Wavelet Matrixです。
    n*: int64
    bitWidth*: int
    levelCount*: int
    levels*: array[MaxQuadWaveletLevels, QuadVectorView]
    bucketStarts*: array[MaxQuadWaveletLevels, array[4, int64]]
    routeStorage*: ptr UncheckedArray[int64]
    backingBytes*: int

func ceilDivPositive(x, y: int64): int64 {.inline.} =
  if x <= 0: 0 else: (x + y - 1) div y

func alignUpPositive(x, alignment: int64): int64 {.inline.} =
  if x <= 0: 0 else: ceilDivPositive(x, alignment) * alignment

func valueBitWidth(x: uint64): int {.inline.} =
  if x == 0: 1 else: 64 - countLeadingZeroBits(x)

func quadLevelCount(bitWidth: int): int {.inline.} =
  (bitWidth + 1) shr 1

func levelShift[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, level: int): int {.inline.} =
  ## 奇数bit幅では先頭に0 bitを補った偶数幅として2 bitずつ処理します。
  ((wm.levelCount - level - 1) shl 1)

func validateMetadata(n: int64, bitWidth: int) =
  if n < 0:
    raise newException(ValueError, "n must be non-negative")
  if bitWidth < 0 or bitWidth > 64:
    raise newException(ValueError, "bitWidth must be in 0..64")

func valueFits(bitWidth: int, value: uint64): bool {.inline.} =
  if bitWidth == 0:
    value == 0'u64
  elif bitWidth == 64:
    true
  else:
    (value shr bitWidth) == 0'u64

func startsFromCounts(counts: array[4, int64]): array[4, int64] {.inline.} =
  result[0] = 0
  result[1] = counts[0]
  result[2] = counts[0] + counts[1]
  result[3] = counts[0] + counts[1] + counts[2]

func countsFromStarts(starts: array[4, int64], n: int64):
    array[4, int64] {.inline.} =
  result[0] = starts[1]
  result[1] = starts[2] - starts[1]
  result[2] = starts[3] - starts[2]
  result[3] = n - starts[3]

func symbolUnchecked[V: QuadVector | QuadVectorView](qv: V,
                                                     pos: int64): int {.inline.} =
  let wordIndex = int(pos shr 5)
  let shift = int((pos and 31'i64) shl 1)
  int((qv.data.data[wordIndex] shr shift) and 3'u64)

proc writeLevelPayload[V: QuadVector | QuadVectorView, Value: SomeUnsignedInt](
    qv: var V, values: openArray[Value], shift: int) =
  ## setSymbolを1件ずつ呼ばず、32 symbol単位で2-bit payloadを直接構築します。
  let wordCount = (values.len + 31) shr 5
  for wordIndex in 0..<wordCount:
    let start = wordIndex shl 5
    let count = min(32, values.len - start)
    var word = 0'u64
    for lane in 0..<count:
      let symbol = (uint64(values[start + lane]) shr shift) and 3'u64
      word = word or (symbol shl (lane shl 1))
    qv.data.data[wordIndex] = word
  qv.isCalced = false

proc validateValues[Value: SomeUnsignedInt](values: openArray[Value],
                                            bitWidth: int) =
  validateMetadata(int64(values.len), bitWidth)
  for value in values:
    if not valueFits(bitWidth, uint64(value)):
      raise newException(ValueError, "value exceeds bitWidth")

proc buildOwned[Value: SomeUnsignedInt](result: var QuadWaveletMatrix,
                                        values: openArray[Value],
                                        bitWidth: int) =
  validateValues(values, bitWidth)
  result.n = int64(values.len)
  result.bitWidth = bitWidth
  result.levelCount = quadLevelCount(bitWidth)
  if values.len == 0 or result.levelCount == 0:
    return

  var current = newSeq[Value](values.len)
  for i, value in values:
    current[i] = value
  var next = newSeq[Value](values.len)

  for level in 0..<result.levelCount:
    let shift = result.levelShift(level)
    result.levels[level] = genQuadVector(result.n)
    result.levels[level].writeLevelPayload(current, shift)
    result.levels[level].build()
    result.bucketStarts[level] = startsFromCounts(
      result.levels[level].totalCounts)

    var nextPos = result.bucketStarts[level]
    for value in current:
      let symbol = int((uint64(value) shr shift) and 3'u64)
      next[int(nextPos[symbol])] = value
      inc nextPos[symbol]
    swap(current, next)

func genQuadWaveletMatrix*(xs: openArray[uint64]): QuadWaveletMatrix =
  ## 入力の最大値から有効bit幅を決定してQWMを構築します。
  if xs.len == 0:
    return
  var maximum = 0'u64
  for value in xs:
    if value > maximum:
      maximum = value
  result.buildOwned(xs, valueBitWidth(maximum))

func genQuadWaveletMatrix*[Value: SomeUnsignedInt](values: openArray[Value],
    bitWidth: int): QuadWaveletMatrix =
  ## 明示した固定bit幅でQWMを構築します。
  result.buildOwned(values, bitWidth)

func requiredQuadWaveletMatrixViewBytes*(n: int64, bitWidth: int): int =
  ## routing tableと全QuadVectorView levelを1つのmmap領域へ置くためのbyte数です。
  validateMetadata(n, bitWidth)
  let levelCount = quadLevelCount(bitWidth)
  if levelCount == 0:
    return 0
  let routeBytes = int64(levelCount * QuadWaveletRouteBytesPerLevel)
  var offset = alignUpPositive(routeBytes, int64(QuadVectorViewAlignment))
  let levelBytes = int64(requiredQuadVectorViewBytes(n))
  for level in 0..<levelCount:
    offset = alignUpPositive(offset, int64(QuadVectorViewAlignment))
    offset += levelBytes
  if offset > int64(int.high):
    raise newException(ValueError, "backing memory size exceeds int range")
  result = int(offset)

func offsetPointer(base: pointer, offset: int): pointer {.inline.} =
  cast[pointer](cast[uint](base) + uint(offset))

func validateRoute(starts: array[4, int64], n: int64) =
  if starts[0] != 0 or starts[1] < 0 or starts[1] > starts[2] or
      starts[2] > starts[3] or starts[3] > n:
    raise newException(ValueError, "invalid Quad Wavelet routing metadata")

func bindPersistedLevel(qv: var QuadVectorView,
                        counts: array[4, int64]) =
  ## QWM routing tableから復元したcountを使って、payload全走査なしにbuilt QV Viewを開きます。
  ## select sampleの実データは永続化済みbackingをそのまま参照します。
  var total = 0'i64
  for count in counts:
    if count < 0:
      raise newException(ValueError, "invalid Quad Vector symbol count")
    total += count
  if total != qv.lenOfSymbols:
    raise newException(ValueError, "Quad Vector symbol counts do not match length")

  qv.totalCounts = counts
  var wordOffset = 0
  for symbol in 0..3:
    let sampleCount = ceilDivPositive(counts[symbol], QuadSelectSampleRate)
    let words = int(ceilDivPositive(sampleCount, 2'i64))
    if wordOffset > qv.selectStorageWords - words:
      raise newException(ValueError, "select sample backing memory is too small")
    if words == 0:
      qv.selectSamples[symbol] = initPackedArrayView(
        nil, 0, 0, 32)
    else:
      let memory = cast[pointer](
        cast[uint](qv.selectStorage) + uint(wordOffset * sizeof(uint64)))
      qv.selectSamples[symbol] = initPackedArrayView(
        memory, words * sizeof(uint64), sampleCount, 32)
    wordOffset += words
  qv.selectStorageUsedWords = wordOffset
  qv.isCalced = true

func initQuadWaveletMatrixView*(memory: pointer, memorySize: int,
    n: int64, bitWidth: int, built = false): QuadWaveletMatrixView =
  ## 1つの64-byte aligned external memoryからQWM Viewを構成します。
  ##
  ## `built=true`では先頭routing tableから各levelのcountを復元するため、
  ## QV payloadをopen時に再走査しません。永続化済みrank/select metadataをそのまま使います。
  validateMetadata(n, bitWidth)
  let required = requiredQuadWaveletMatrixViewBytes(n, bitWidth)
  if memorySize < 0 or memorySize < required:
    raise newException(ValueError, "backing memory is too small")
  if required > 0:
    if memory == nil:
      raise newException(ValueError, "backing memory must not be nil")
    if cast[uint](memory) mod uint(QuadVectorViewAlignment) != 0'u:
      raise newException(ValueError, "backing memory is not 64-byte aligned")

  result.n = n
  result.bitWidth = bitWidth
  result.levelCount = quadLevelCount(bitWidth)
  result.backingBytes = required
  if result.levelCount == 0:
    return

  result.routeStorage = cast[ptr UncheckedArray[int64]](memory)
  let routeBytes = int64(result.levelCount * QuadWaveletRouteBytesPerLevel)
  var offset = int(alignUpPositive(routeBytes,
                                    int64(QuadVectorViewAlignment)))
  let levelBytes = requiredQuadVectorViewBytes(n)

  for level in 0..<result.levelCount:
    offset = int(alignUpPositive(int64(offset),
                                 int64(QuadVectorViewAlignment)))
    result.levels[level] = initQuadVectorView(
      offsetPointer(memory, offset), levelBytes, n, built = false)
    if built:
      for symbol in 0..3:
        result.bucketStarts[level][symbol] =
          result.routeStorage[level * QuadWaveletRouteWidth + symbol]
      validateRoute(result.bucketStarts[level], n)
      result.levels[level].bindPersistedLevel(
        countsFromStarts(result.bucketStarts[level], n))
    offset += levelBytes

proc build*[Value: SomeUnsignedInt](wm: var QuadWaveletMatrixView,
                                    values: openArray[Value]) =
  ## mutable mmap ViewへQWMを構築します。完成後は通常のquery APIを利用できます。
  if int64(values.len) != wm.n:
    raise newException(ValueError, "value length does not match view length")
  validateValues(values, wm.bitWidth)
  if wm.levelCount == 0:
    return

  var current = newSeq[Value](values.len)
  for i, value in values:
    current[i] = value
  var next = newSeq[Value](values.len)

  for level in 0..<wm.levelCount:
    let shift = wm.levelShift(level)
    wm.levels[level].writeLevelPayload(current, shift)
    wm.levels[level].build()
    wm.bucketStarts[level] = startsFromCounts(wm.levels[level].totalCounts)
    for symbol in 0..3:
      wm.routeStorage[level * QuadWaveletRouteWidth + symbol] =
        wm.bucketStarts[level][symbol]

    var nextPos = wm.bucketStarts[level]
    for value in current:
      let symbol = int((uint64(value) shr shift) and 3'u64)
      next[int(nextPos[symbol])] = value
      inc nextPos[symbol]
    swap(current, next)

func checkIndex[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, pos: int64) {.inline.} =
  if pos < 0 or pos >= wm.n:
    raise newException(IndexDefect, "index out of bounds")

func checkPosition[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, pos: int64) {.inline.} =
  if pos < 0 or pos > wm.n:
    raise newException(IndexDefect, "position out of bounds")

func checkRange[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, left, right: int64) {.inline.} =
  if left < 0 or left > right or right > wm.n:
    raise newException(IndexDefect, "range out of bounds")

func valueFits[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, value: uint64): bool {.inline.} =
  valueFits(wm.bitWidth, value)

func access*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, i: int64): uint64 =
  ## 元配列の`i`番目の値を返します。
  wm.checkIndex(i)
  var pos = i
  for level in 0..<wm.levelCount:
    let symbol = wm.levels[level].symbolUnchecked(pos)
    let shift = wm.levelShift(level)
    result = result or (uint64(symbol) shl shift)
    pos = wm.bucketStarts[level][symbol] +
      wm.levels[level].rankUnchecked(symbol, pos)

func `[]`*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, i: int64): uint64 {.inline.} =
  wm.access(i)

func accessRankUnchecked*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, pos: int64): tuple[value: uint64, rankBefore: int64] =
  ## accessと同値rankを1 traversalへ融合した検査なしhot-path APIです。
  var current = pos
  var intervalLeft = 0'i64
  for level in 0..<wm.levelCount:
    let symbol = wm.levels[level].symbolUnchecked(current)
    let shift = wm.levelShift(level)
    result.value = result.value or (uint64(symbol) shl shift)
    let currentRank = wm.levels[level].rankUnchecked(symbol, current)
    let leftRank = wm.levels[level].rankUnchecked(symbol, intervalLeft)
    current = wm.bucketStarts[level][symbol] + currentRank
    intervalLeft = wm.bucketStarts[level][symbol] + leftRank
  result.rankBefore = current - intervalLeft

func accessRank*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, pos: int64): tuple[value: uint64, rankBefore: int64] =
  wm.checkIndex(pos)
  wm.accessRankUnchecked(pos)

func rank*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, value: uint64, pos: int64): int64 =
  ## `[0,pos)`に含まれるvalueの出現数です。
  wm.checkPosition(pos)
  if wm.n == 0 or not wm.valueFits(value):
    return 0
  if wm.levelCount == 0:
    return pos

  var left = 0'i64
  var right = pos
  for level in 0..<wm.levelCount:
    let symbol = int((value shr wm.levelShift(level)) and 3'u64)
    let start = wm.bucketStarts[level][symbol]
    left = start + wm.levels[level].rankUnchecked(symbol, left)
    right = start + wm.levels[level].rankUnchecked(symbol, right)
  result = right - left

func rank*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, value: uint64, left, right: int64): int64 =
  ## `[left,right)`に含まれるvalueの出現数です。
  wm.checkRange(left, right)
  if left == right or wm.n == 0 or not wm.valueFits(value):
    return 0
  if wm.levelCount == 0:
    return right - left

  var lo = left
  var hi = right
  for level in 0..<wm.levelCount:
    let symbol = int((value shr wm.levelShift(level)) and 3'u64)
    let start = wm.bucketStarts[level][symbol]
    lo = start + wm.levels[level].rankUnchecked(symbol, lo)
    hi = start + wm.levels[level].rankUnchecked(symbol, hi)
  result = hi - lo

func rankPair*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, value: uint64, left, right: int64):
    tuple[leftRank, rightRank: int64] =
  ## `rank(value,left)`と`rank(value,right)`を1 traversalで返します。
  wm.checkRange(left, right)
  if wm.n == 0 or not wm.valueFits(value):
    return
  if wm.levelCount == 0:
    result.leftRank = left
    result.rightRank = right
    return

  var startPos = 0'i64
  var leftPos = left
  var rightPos = right
  for level in 0..<wm.levelCount:
    let symbol = int((value shr wm.levelShift(level)) and 3'u64)
    let bucket = wm.bucketStarts[level][symbol]
    startPos = bucket + wm.levels[level].rankUnchecked(symbol, startPos)
    leftPos = bucket + wm.levels[level].rankUnchecked(symbol, leftPos)
    rightPos = bucket + wm.levels[level].rankUnchecked(symbol, rightPos)
  result.leftRank = leftPos - startPos
  result.rightRank = rightPos - startPos

func rankIncl*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, value: uint64, pos: int64): int64 =
  wm.checkIndex(pos)
  wm.rank(value, pos + 1)

func select*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, value: uint64, k: int64): int64 =
  ## 0-basedでk番目のvalueの元配列positionを返します。なければ`-1`です。
  if k < 0 or wm.n == 0 or not wm.valueFits(value):
    return -1
  if wm.levelCount == 0:
    return (if k < wm.n: k else: -1)

  var left = 0'i64
  var right = wm.n
  for level in 0..<wm.levelCount:
    let symbol = int((value shr wm.levelShift(level)) and 3'u64)
    let start = wm.bucketStarts[level][symbol]
    left = start + wm.levels[level].rankUnchecked(symbol, left)
    right = start + wm.levels[level].rankUnchecked(symbol, right)
  if k >= right - left:
    return -1

  var pos = left + k
  for level in countdown(wm.levelCount - 1, 0):
    let symbol = int((value shr wm.levelShift(level)) and 3'u64)
    pos = wm.levels[level].select(symbol,
      pos - wm.bucketStarts[level][symbol])
    if pos < 0:
      return -1
  result = pos

func selectNth*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, value: uint64, nth: int64): int64 {.inline.} =
  ## 1-based selectです。
  if nth <= 0: -1 else: wm.select(value, nth - 1)

func quantile*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, left, right, k: int64): uint64 =
  ## `[left,right)`内の0-based k番目の値を返します。
  wm.checkRange(left, right)
  if k < 0 or k >= right - left:
    raise newException(IndexDefect, "quantile index out of bounds")
  if wm.levelCount == 0:
    return 0

  var lo = left
  var hi = right
  var wanted = k
  for level in 0..<wm.levelCount:
    var leftRanks: array[4, int64]
    var counts: array[4, int64]
    for symbol in 0..3:
      leftRanks[symbol] = wm.levels[level].rankUnchecked(symbol, lo)
      counts[symbol] = wm.levels[level].rankUnchecked(symbol, hi) -
        leftRanks[symbol]

    var symbol = 0
    while symbol < 3 and wanted >= counts[symbol]:
      wanted -= counts[symbol]
      inc symbol
    result = result or (uint64(symbol) shl wm.levelShift(level))
    let start = wm.bucketStarts[level][symbol]
    lo = start + leftRanks[symbol]
    hi = lo + counts[symbol]

func countLessThan*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, left, right: int64, value: uint64): int64 =
  ## `[left,right)`内のvalue未満の個数です。
  wm.checkRange(left, right)
  if left == right or value == 0:
    return 0
  if wm.bitWidth < 64 and wm.bitWidth > 0 and
      (value shr wm.bitWidth) != 0:
    return right - left
  if wm.levelCount == 0:
    return (if value > 0: right - left else: 0)

  var lo = left
  var hi = right
  for level in 0..<wm.levelCount:
    let target = int((value shr wm.levelShift(level)) and 3'u64)
    var targetLeftRank = 0'i64
    var targetRightRank = 0'i64
    for symbol in 0..target:
      let l = wm.levels[level].rankUnchecked(symbol, lo)
      let r = wm.levels[level].rankUnchecked(symbol, hi)
      if symbol < target:
        result += r - l
      else:
        targetLeftRank = l
        targetRightRank = r
    let start = wm.bucketStarts[level][target]
    lo = start + targetLeftRank
    hi = start + targetRightRank

func countLessThan*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, value: uint64, pos: int64): int64 =
  ## `[0,pos)`内のvalue未満の個数です。
  wm.checkPosition(pos)
  wm.countLessThan(0, pos, value)

func rankLessThan*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, value: uint64, pos: int64): int64 {.inline.} =
  ## WaveletMatrix互換名です。
  wm.countLessThan(value, pos)

func occPosition*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, value: uint64, pos: int64): int64 =
  ## FM-indexの`C[value] + Occ(value,pos)`に相当します。
  wm.checkPosition(pos)
  wm.countLessThan(0, wm.n, value) + wm.rank(value, pos)

func rangeFreq*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, left, right: int64, lower, upper: uint64): int64 =
  ## `[left,right)`中で値が`[lower,upper)`に入る個数です。
  wm.checkRange(left, right)
  if lower >= upper:
    return 0
  wm.countLessThan(left, right, upper) -
    wm.countLessThan(left, right, lower)

func predecessor*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, left, right: int64, upper: uint64): uint64 =
  ## `[left,right)`内で`upper`未満の最大値を返します。
  wm.checkRange(left, right)
  let count = wm.countLessThan(left, right, upper)
  if count <= 0:
    raise newException(ValueError, "predecessor does not exist")
  wm.quantile(left, right, count - 1)

func successor*[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, left, right: int64, lower: uint64): uint64 =
  ## `[left,right)`内で`lower`以上の最小値を返します。
  wm.checkRange(left, right)
  let count = wm.countLessThan(left, right, lower)
  if count >= right - left:
    raise newException(ValueError, "successor does not exist")
  wm.quantile(left, right, count)

iterator items*[W: QuadWaveletMatrix | QuadWaveletMatrixView](wm: W): uint64 =
  ## 元配列順に値を列挙します。
  for i in 0'i64..<wm.n:
    yield wm.access(i)

func toSeq*[W: QuadWaveletMatrix | QuadWaveletMatrixView](wm: W): seq[uint64] =
  ## 元配列順にdecodeします。
  result = newSeqOfCap[uint64](int(wm.n))
  for value in wm.items:
    result.add value

func rawBytes*(wm: QuadWaveletMatrix): int64 =
  for level in 0..<wm.levelCount:
    result += wm.levels[level].rawBytes

func auxiliaryBytes*(wm: QuadWaveletMatrix): int64 =
  for level in 0..<wm.levelCount:
    result += wm.levels[level].auxiliaryBytes

func allocatedBytes*(wm: QuadWaveletMatrix): int64 =
  wm.rawBytes + wm.auxiliaryBytes

func rawBytes*(wm: QuadWaveletMatrixView): int64 =
  for level in 0..<wm.levelCount:
    result += wm.levels[level].rawBytes

func auxiliaryBytes*(wm: QuadWaveletMatrixView): int64 =
  for level in 0..<wm.levelCount:
    result += wm.levels[level].auxiliaryBytes

func allocatedBytes*(wm: QuadWaveletMatrixView): int64 =
  wm.rawBytes + wm.auxiliaryBytes
