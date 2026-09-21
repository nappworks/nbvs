import std/[algorithm, monotimes, strformat, times]
import nbvs/[reversed_wavelet_matrix, succinct_bit_vector, wavelet_matrix]

const
  Rows = 65_536
  Cardinality = 1_024
  QueryCount = 2_048
  WarmupIters = 1
  MeasuredIters = 7

var sink {.volatile.}: uint64

func nextRand(state: var uint64): uint64 {.inline.} =
  state = state * 6364136223846793005'u64 + 1442695040888963407'u64
  state

proc makeValues(): seq[uint64] =
  result = newSeq[uint64](Rows)
  var state = 0x1234_5678_9abc_def0'u64
  for value in result.mitems:
    value = nextRand(state) mod Cardinality

proc makePositions(): seq[int64] =
  result = newSeq[int64](QueryCount)
  var state = 0x0fed_cba9_8765_4321'u64
  for position in result.mitems:
    position = int64(nextRand(state) mod uint64(Rows))

func legacyWmRankRange(wm: WaveletMatrix, value: uint64,
    left, right: int64): int64 =
  var lo = left
  var hi = right
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    if ((value shr shift) and 1'u64) == 0:
      lo -= wm.levels[level].rank1Unchecked(lo)
      hi -= wm.levels[level].rank1Unchecked(hi)
    else:
      lo = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(lo)
      hi = wm.zeroCounts[level] + wm.levels[level].rank1Unchecked(hi)
  hi - lo

func legacyWmCountLessThan(wm: WaveletMatrix, left, right: int64,
    value: uint64): int64 =
  var lo = left
  var hi = right
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let loOnes = wm.levels[level].rank1Unchecked(lo)
    let hiOnes = wm.levels[level].rank1Unchecked(hi)
    let loZeros = lo - loOnes
    let hiZeros = hi - hiOnes
    if ((value shr shift) and 1'u64) == 0:
      lo = loZeros
      hi = hiZeros
    else:
      result += hiZeros - loZeros
      lo = wm.zeroCounts[level] + loOnes
      hi = wm.zeroCounts[level] + hiOnes

func legacyWmQuantile(wm: WaveletMatrix, left, right, k: int64): uint64 =
  var lo = left
  var hi = right
  var rest = k
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let loOnes = wm.levels[level].rank1Unchecked(lo)
    let hiOnes = wm.levels[level].rank1Unchecked(hi)
    let loZeros = lo - loOnes
    let hiZeros = hi - hiOnes
    let zeros = hiZeros - loZeros
    if rest < zeros:
      lo = loZeros
      hi = hiZeros
    else:
      result = result or (1'u64 shl shift)
      rest -= zeros
      lo = wm.zeroCounts[level] + loOnes
      hi = wm.zeroCounts[level] + hiOnes

func legacyRwmAccess(rwm: ReversedWaveletMatrix, position: int64): uint64 =
  var pos = position
  for level in 0..<rwm.bitWidth:
    let ones = rwm.levels[level].rank1Unchecked(pos)
    let one = ((rwm.levels[level].data[int(pos shr 6)] shr
      int(pos and 63)) and 1'u64) != 0
    if one:
      result = result or (1'u64 shl level)
      pos = rwm.zeroCounts[level] + ones
    else:
      pos -= ones

func legacyRwmRank(rwm: ReversedWaveletMatrix, value: uint64,
    pos: int64): int64 =
  var left = 0'i64
  var right = pos
  for level in 0..<rwm.bitWidth:
    if ((value shr level) and 1'u64) == 0:
      left -= rwm.levels[level].rank1Unchecked(left)
      right -= rwm.levels[level].rank1Unchecked(right)
    else:
      left = rwm.zeroCounts[level] + rwm.levels[level].rank1Unchecked(left)
      right = rwm.zeroCounts[level] + rwm.levels[level].rank1Unchecked(right)
  right - left

func legacyRwmRankRange(rwm: ReversedWaveletMatrix, value: uint64,
    left, right: int64): int64 =
  var lo = left
  var hi = right
  for level in 0..<rwm.bitWidth:
    if ((value shr level) and 1'u64) == 0:
      lo -= rwm.levels[level].rank1Unchecked(lo)
      hi -= rwm.levels[level].rank1Unchecked(hi)
    else:
      lo = rwm.zeroCounts[level] + rwm.levels[level].rank1Unchecked(lo)
      hi = rwm.zeroCounts[level] + rwm.levels[level].rank1Unchecked(hi)
  hi - lo

func remainingMask(bitWidth, level: int): uint64 {.inline.} =
  let lowMask =
    if level == 0: 0'u64
    elif level >= 64: uint64.high
    else: (1'u64 shl level) - 1'u64
  let fullMask =
    if bitWidth == 64: uint64.high
    else: (1'u64 shl bitWidth) - 1'u64
  fullMask and not lowMask

func legacyRwmCountLessThanNode(rwm: ReversedWaveletMatrix, level: int,
    left, right: int64, partial, value: uint64): int64 =
  if left >= right:
    return 0
  if partial >= value:
    return 0
  if (partial or remainingMask(rwm.bitWidth, level)) < value:
    return right - left
  if level == rwm.bitWidth:
    return right - left

  let leftOnes = rwm.levels[level].rank1Unchecked(left)
  let rightOnes = rwm.levels[level].rank1Unchecked(right)
  let zeroLeft = left - leftOnes
  let zeroRight = right - rightOnes
  result = legacyRwmCountLessThanNode(
    rwm, level + 1, zeroLeft, zeroRight, partial, value)
  let oneLeft = rwm.zeroCounts[level] + leftOnes
  let oneRight = rwm.zeroCounts[level] + rightOnes
  result += legacyRwmCountLessThanNode(
    rwm, level + 1, oneLeft, oneRight,
    partial or (1'u64 shl level), value)

func legacyRwmRankLessThan(rwm: ReversedWaveletMatrix,
    value: uint64, pos: int64): int64 =
  if pos == 0 or value == 0:
    return 0
  legacyRwmCountLessThanNode(rwm, 0, 0, pos, 0, value)

func legacyRwmOccPosition(rwm: ReversedWaveletMatrix, value: uint64,
    pos: int64): int64 =
  result = pos
  for level in 0..<rwm.bitWidth:
    let ones = rwm.levels[level].rank1Unchecked(result)
    if ((value shr level) and 1'u64) == 0:
      result -= ones
    else:
      result = rwm.zeroCounts[level] + ones

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

proc emit(name: string, measured: tuple[legacyNs, currentNs: int64]) =
  echo &"{name},{measured.legacyNs},{measured.currentNs}," &
    &"{float(measured.legacyNs) / float(measured.currentNs):.4f}"

proc main() =
  let values = makeValues()
  let positions = makePositions()
  let wm = genWaveletMatrix(values)
  let rwm = genReversedWaveletMatrix(values)

  for position in positions[0..<64]:
    let value = values[int(position)]
    let left = max(0'i64, position - 97)
    let right = min(int64(Rows), position + 131)
    doAssert legacyWmRankRange(wm, value, left, right) ==
      wm.rank(value, left, right)
    doAssert legacyWmCountLessThan(wm, left, right, value) ==
      wm.countLessThan(left, right, value)
    let k = (right - left) div 2
    doAssert legacyWmQuantile(wm, left, right, k) ==
      wm.quantile(left, right, k)
    doAssert legacyRwmAccess(rwm, position) == rwm.access(position)
    doAssert legacyRwmRank(rwm, value, position) ==
      rwm.rank(value, position)
    doAssert legacyRwmRankRange(rwm, value, left, right) ==
      rwm.rank(value, left, right)
    doAssert legacyRwmOccPosition(rwm, value, position) ==
      rwm.occPosition(value, position)
    doAssert legacyRwmRankLessThan(rwm, value, position) ==
      rwm.rankLessThan(value, position)

  echo "query,legacy_ns,fixed_depth_ns,speedup"

  emit("wm_rank_range", measurePair(
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(legacyWmRankRange(
          wm, value, max(0'i64, position - 97),
          min(int64(Rows), position + 131)))),
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(wm.rank(
          value, max(0'i64, position - 97),
          min(int64(Rows), position + 131))))))

  emit("wm_count_less_than", measurePair(
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(legacyWmCountLessThan(
          wm, max(0'i64, position - 97),
          min(int64(Rows), position + 131), value))),
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(wm.countLessThan(
          max(0'i64, position - 97),
          min(int64(Rows), position + 131), value)))))

  emit("wm_quantile", measurePair(
    (block:
      for position in positions:
        let left = max(0'i64, position - 97)
        let right = min(int64(Rows), position + 131)
        sink = sink xor legacyWmQuantile(
          wm, left, right, (right - left) div 2)),
    (block:
      for position in positions:
        let left = max(0'i64, position - 97)
        let right = min(int64(Rows), position + 131)
        sink = sink xor wm.quantile(
          left, right, (right - left) div 2))))

  emit("rwm_access", measurePair(
    (block:
      for position in positions:
        sink = sink xor legacyRwmAccess(rwm, position)),
    (block:
      for position in positions:
        sink = sink xor rwm.access(position))))

  emit("rwm_rank", measurePair(
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(legacyRwmRank(rwm, value, position))),
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(rwm.rank(value, position)))))

  emit("rwm_rank_range", measurePair(
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(legacyRwmRankRange(
          rwm, value, max(0'i64, position - 97),
          min(int64(Rows), position + 131)))),
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(rwm.rank(
          value, max(0'i64, position - 97),
          min(int64(Rows), position + 131))))))

  emit("rwm_occ_position", measurePair(
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(legacyRwmOccPosition(
          rwm, value, position))),
    (block:
      for position in positions:
        let value = values[int(position)]
        sink = sink xor uint64(rwm.occPosition(value, position)))))

  let lessThanPositions = positions[0..<128]
  emit("rwm_rank_less_than", measurePair(
    (block:
      for position in lessThanPositions:
        let value = values[int(position)]
        sink = sink xor uint64(legacyRwmRankLessThan(
          rwm, value, position))),
    (block:
      for position in lessThanPositions:
        let value = values[int(position)]
        sink = sink xor uint64(rwm.rankLessThan(value, position)))))

  stderr.writeLine("sink=", sink)

when isMainModule:
  main()
