import std/[algorithm, monotimes, strformat, times]
import nbvs/[quad_wavelet_matrix, quad_vector, quad_vector_view]

type
  BenchCase = object
    rows: int
    cardinality: int

  TraversalNode = tuple[level: int, left, right: int64, value: uint64]

const
  Cases = [
    BenchCase(rows: 65_536, cardinality: 256),
    BenchCase(rows: 65_536, cardinality: 65_536),
    BenchCase(rows: 1_048_576, cardinality: 256),
    BenchCase(rows: 1_048_576, cardinality: 65_536)
  ]
  QueryCount = 2_048
  RangeProbeCount = 64
  RangeWidth = 4_096
  WarmupIters = 1
  MeasuredIters = 7

var sink {.volatile.}: uint64

func nextRand(state: var uint64): uint64 {.inline.} =
  state = state * 6364136223846793005'u64 + 1442695040888963407'u64
  state

proc makeValues(c: BenchCase): seq[uint64] =
  result = newSeq[uint64](c.rows)
  var state = 0x517c_c1b7_2722_0a95'u64 xor uint64(c.rows) xor
    uint64(c.cardinality)
  for value in result.mitems:
    value = nextRand(state) mod uint64(c.cardinality)
  if result.len > 0:
    result[^1] = uint64(c.cardinality - 1)

proc makePositions(rows: int): seq[int64] =
  result = newSeq[int64](QueryCount)
  var state = 0x94d0_49bb_1331_11eb'u64 xor uint64(rows)
  for pos in result.mitems:
    pos = int64(nextRand(state) mod uint64(rows))

func shiftAt[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, level: int): int {.inline.} =
  (wm.levelCount - level - 1) shl 1

func legacyRankRange[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, value: uint64, left, right: int64): int64 =
  var lo = left
  var hi = right
  for level in 0..<wm.levelCount:
    let symbol = int((value shr wm.shiftAt(level)) and 3'u64)
    let start = wm.bucketStarts[level][symbol]
    lo = start + wm.levels[level].rankUnchecked(symbol, lo)
    hi = start + wm.levels[level].rankUnchecked(symbol, hi)
  hi - lo

func legacyRankPair[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, value: uint64, left, right: int64):
    tuple[leftRank, rightRank: int64] =
  var startPos = 0'i64
  var leftPos = left
  var rightPos = right
  for level in 0..<wm.levelCount:
    let symbol = int((value shr wm.shiftAt(level)) and 3'u64)
    let bucket = wm.bucketStarts[level][symbol]
    startPos = bucket + wm.levels[level].rankUnchecked(symbol, startPos)
    leftPos = bucket + wm.levels[level].rankUnchecked(symbol, leftPos)
    rightPos = bucket + wm.levels[level].rankUnchecked(symbol, rightPos)
  result.leftRank = leftPos - startPos
  result.rightRank = rightPos - startPos

func legacySelect[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, value: uint64, k: int64): int64 =
  var left = 0'i64
  var right = wm.n
  for level in 0..<wm.levelCount:
    let symbol = int((value shr wm.shiftAt(level)) and 3'u64)
    let start = wm.bucketStarts[level][symbol]
    left = start + wm.levels[level].rankUnchecked(symbol, left)
    right = start + wm.levels[level].rankUnchecked(symbol, right)
  if k < 0 or k >= right - left:
    return -1

  var pos = left + k
  for level in countdown(wm.levelCount - 1, 0):
    let symbol = int((value shr wm.shiftAt(level)) and 3'u64)
    pos = wm.levels[level].select(
      symbol, pos - wm.bucketStarts[level][symbol])
    if pos < 0:
      return -1
  pos

func legacyQuantile[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, left, right, k: int64): uint64 =
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
    result = result or (uint64(symbol) shl wm.shiftAt(level))
    let start = wm.bucketStarts[level][symbol]
    lo = start + leftRanks[symbol]
    hi = lo + counts[symbol]

func legacyCountLessThan[W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, left, right: int64, value: uint64): int64 =
  var lo = left
  var hi = right
  for level in 0..<wm.levelCount:
    let target = int((value shr wm.shiftAt(level)) and 3'u64)
    var targetLeft = 0'i64
    var targetRight = 0'i64
    for symbol in 0..target:
      let l = wm.levels[level].rankUnchecked(symbol, lo)
      let r = wm.levels[level].rankUnchecked(symbol, hi)
      if symbol < target:
        result += r - l
      else:
        targetLeft = l
        targetRight = r
    let start = wm.bucketStarts[level][target]
    lo = start + targetLeft
    hi = start + targetRight

func legacyCountsChecksum[
    W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, left, right: int64): uint64 =
  var stack: seq[TraversalNode] =
    @[(level: 0, left: left, right: right, value: 0'u64)]
  while stack.len > 0:
    let node = stack.pop()
    if node.left >= node.right:
      continue
    if node.level == wm.levelCount:
      result = result xor node.value xor uint64(node.right - node.left)
      continue

    let shift = wm.shiftAt(node.level)
    for symbol in countdown(3, 0):
      let l = wm.levels[node.level].rankUnchecked(symbol, node.left)
      let r = wm.levels[node.level].rankUnchecked(symbol, node.right)
      let childLeft = wm.bucketStarts[node.level][symbol] + l
      let childRight = wm.bucketStarts[node.level][symbol] + r
      if childLeft < childRight:
        stack.add (
          level: node.level + 1,
          left: childLeft,
          right: childRight,
          value: node.value or (uint64(symbol) shl shift))

func currentCountsChecksum[
    W: QuadWaveletMatrix | QuadWaveletMatrixView](
    wm: W, left, right: int64): uint64 =
  for item in wm.collectValueCountsItems(left, right):
    result = result xor item.value xor uint64(item.frequency)

func legacyRangeEnumerationChecksum[
    W: QuadWaveletMatrix | QuadWaveletMatrixView](wm: W): uint64 =
  for probe in 0..<RangeProbeCount:
    let left = int64((probe * 977) mod max(1, int(wm.n) - RangeWidth))
    let right = min(wm.n, left + int64(RangeWidth))
    result = result xor wm.legacyCountsChecksum(left, right)

func currentRangeEnumerationChecksum[
    W: QuadWaveletMatrix | QuadWaveletMatrixView](wm: W): uint64 =
  for probe in 0..<RangeProbeCount:
    let left = int64((probe * 977) mod max(1, int(wm.n) - RangeWidth))
    let right = min(wm.n, left + int64(RangeWidth))
    result = result xor wm.currentCountsChecksum(left, right)

func median(samples: var seq[int64]): int64 =
  samples.sort()
  samples[samples.len div 2]

template elapsedNs(body: untyped): int64 =
  block:
    let started = getMonoTime()
    body
    (getMonoTime() - started).inNanoseconds

template measurePair(legacyBody, currentBody: untyped):
    tuple[legacyNs, currentNs: int64] =
  block:
    var legacySamples = newSeqOfCap[int64](MeasuredIters)
    var currentSamples = newSeqOfCap[int64](MeasuredIters)
    for iteration in 0..<(WarmupIters + MeasuredIters):
      var legacyElapsed, currentElapsed: int64
      if (iteration and 1) == 0:
        legacyElapsed = elapsedNs: legacyBody
        currentElapsed = elapsedNs: currentBody
      else:
        currentElapsed = elapsedNs: currentBody
        legacyElapsed = elapsedNs: legacyBody
      if iteration >= WarmupIters:
        legacySamples.add legacyElapsed
        currentSamples.add currentElapsed
    (legacySamples.median(), currentSamples.median())

proc emit(c: BenchCase, query: string,
    measured: tuple[legacyNs, currentNs: int64]) =
  echo &"{c.rows},{c.cardinality},{query},{measured.legacyNs}," &
    &"{measured.currentNs}," &
    &"{float(measured.legacyNs) / float(measured.currentNs):.4f}"

proc runCase(c: BenchCase) =
  let values = makeValues(c)
  let qwm = genQuadWaveletMatrix(values)
  let positions = makePositions(c.rows)

  var occurrenceBefore = newSeq[int64](c.rows)
  var seen = newSeq[int64](c.cardinality)
  for index, value in values:
    occurrenceBefore[index] = seen[int(value)]
    inc seen[int(value)]

  for position in positions[0..<64]:
    let value = values[int(position)]
    let left = max(0'i64, position - 97)
    let right = min(int64(c.rows), position + 131)
    doAssert qwm.legacyRankRange(value, left, right) ==
      qwm.rank(value, left, right)
    doAssert qwm.legacyRankPair(value, left, right) ==
      qwm.rankPair(value, left, right)
    doAssert qwm.legacySelect(
      value, occurrenceBefore[int(position)]) == position
    doAssert qwm.select(
      value, occurrenceBefore[int(position)]) == position
    doAssert qwm.legacyQuantile(
      left, right, (right - left) div 2) ==
      qwm.quantile(left, right, (right - left) div 2)
    doAssert qwm.legacyCountLessThan(left, right, value) ==
      qwm.countLessThan(left, right, value)

  doAssert qwm.legacyCountsChecksum(0, qwm.n) ==
    qwm.currentCountsChecksum(0, qwm.n)
  doAssert qwm.legacyRangeEnumerationChecksum() ==
    qwm.currentRangeEnumerationChecksum()

  emit(c, "rank_range", measurePair(
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(qwm.legacyRankRange(
          value, max(0'i64, position - 97),
          min(int64(c.rows), position + 131)))),
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(qwm.rank(
          value, max(0'i64, position - 97),
          min(int64(c.rows), position + 131))))))

  emit(c, "rank_pair", measurePair(
    (block:
      for position in positions:
        let value = values[int(position)]
        let pair = qwm.legacyRankPair(
          value, max(0'i64, position - 97),
          min(int64(c.rows), position + 131))
        sink = sink xor uint64(pair.leftRank) xor uint64(pair.rightRank)),
    (block:
      for position in positions:
        let value = values[int(position)]
        let pair = qwm.rankPair(
          value, max(0'i64, position - 97),
          min(int64(c.rows), position + 131))
        sink = sink xor uint64(pair.leftRank) xor uint64(pair.rightRank))))

  emit(c, "select", measurePair(
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(qwm.legacySelect(
          value, occurrenceBefore[int(position)]))),
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(qwm.select(
          value, occurrenceBefore[int(position)])))))

  emit(c, "quantile", measurePair(
    (block:
      for position in positions:
        let left = max(0'i64, position - 97)
        let right = min(int64(c.rows), position + 131)
        sink = sink xor qwm.legacyQuantile(
          left, right, (right - left) div 2)),
    (block:
      for position in positions:
        let left = max(0'i64, position - 97)
        let right = min(int64(c.rows), position + 131)
        sink = sink xor qwm.quantile(
          left, right, (right - left) div 2))))

  emit(c, "count_less_than", measurePair(
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(qwm.legacyCountLessThan(
          max(0'i64, position - 97),
          min(int64(c.rows), position + 131), value))),
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(qwm.countLessThan(
          max(0'i64, position - 97),
          min(int64(c.rows), position + 131), value)))))

  emit(c, "full_value_counts", measurePair(
    (block: sink = sink xor qwm.legacyCountsChecksum(0, qwm.n)),
    (block: sink = sink xor qwm.currentCountsChecksum(0, qwm.n))))

  emit(c, "range_value_counts", measurePair(
    (block: sink = sink xor qwm.legacyRangeEnumerationChecksum()),
    (block: sink = sink xor qwm.currentRangeEnumerationChecksum())))

when isMainModule:
  echo "rows,cardinality,query,legacy_ns,current_ns,speedup"
  for c in Cases:
    runCase(c)
  stderr.writeLine("sink=", sink)
