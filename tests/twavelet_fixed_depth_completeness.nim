import std/algorithm
import nbvs/[reversed_wavelet_matrix, wavelet_matrix, wavelet_matching_runs,
  wavelet_position_match, wavelet_select_cursor, wavelet_terminal]

proc naiveRank(values: openArray[uint64], target: uint64, pos: int): int64 =
  for index in 0..<pos:
    if values[index] == target:
      inc result

proc naiveLessThan(values: openArray[uint64], target: uint64,
    left, right: int): int64 =
  for index in left..<right:
    if values[index] < target:
      inc result

proc naiveRuns(values: openArray[uint64], target: uint64,
    left, right: int): seq[MatchingRun] =
  var index = left
  while index < right:
    if values[index] != target:
      inc index
      continue
    let start = index
    while index < right and values[index] == target:
      inc index
    result.add (left: int64(start), right: int64(index))

block wmRwmFixedDepthCompleteness:
  for item in [
      (length: 257, expectedDepth: 0),
      (length: 4_097, expectedDepth: 1),
      (length: 65_536, expectedDepth: 2),
      (length: 65_537, expectedDepth: 3)]:
    var values = newSeq[uint64](item.length)
    for index in 0..<values.len:
      values[index] = uint64((index * 37 + index div 11) mod 257)

    let wm = genWaveletMatrix(values, 9)
    let rwm = genReversedWaveletMatrix(values)
    doAssert int(wm.levels[0].level) == item.expectedDepth
    doAssert int(rwm.levels[0].level) == item.expectedDepth

    let positions = [0, 1, item.length div 2, item.length - 1]
    for position in positions:
      let expected = values[position]
      doAssert wm.access(int64(position)) == expected
      doAssert rwm.access(int64(position)) == expected
      doAssert wm.matchesAt(int64(position), expected)
      doAssert rwm.matchesAt(int64(position), expected)
      doAssert not wm.matchesAt(int64(position), expected xor 1'u64)
      doAssert not rwm.matchesAt(int64(position), expected xor 1'u64)
      doAssert wm.valueInRangeAt(
        int64(position), expected, expected)

      let terminal = wm.terminalPosition(int64(position))
      let accessed = wm.accessWithTerminalPosition(int64(position))
      let interval = wm.terminalInterval(expected)
      doAssert accessed.value == expected
      doAssert accessed.terminalPosition == terminal
      doAssert terminal >= interval.left and terminal < interval.right

    let target = 7'u64
    let left = 13
    let right = item.length - 17
    let leftRank = naiveRank(values, target, left)
    let rightRank = naiveRank(values, target, right)
    doAssert wm.rank(target, int64(left), int64(right)) ==
      rightRank - leftRank
    doAssert rwm.rank(target, int64(left), int64(right)) ==
      rightRank - leftRank
    doAssert wm.rankPair(target, int64(left), int64(right)) ==
      (leftRank: leftRank, rightRank: rightRank)
    doAssert wm.countLessThan(
      int64(left), int64(right), 128'u64) ==
      naiveLessThan(values, 128'u64, left, right)
    doAssert rwm.rankLessThan(128'u64, int64(right)) ==
      naiveLessThan(values, 128'u64, 0, right)
    doAssert rwm.occPosition(target, int64(right)) >= rightRank

    var firstTarget = -1
    for index, value in values:
      if value == target:
        firstTarget = index
        break
    doAssert firstTarget >= 0
    doAssert wm.select(target, 0) == int64(firstTarget)
    doAssert rwm.select(target, 0) == int64(firstTarget)

    let qLeft = left
    let qRight = min(right, left + 4_096)
    var sorted = values[qLeft..<qRight]
    sorted.sort()
    let k = sorted.len div 2
    doAssert wm.quantile(int64(qLeft), int64(qRight), int64(k)) ==
      sorted[k]

    var expectedDistinct = values[qLeft..<qRight]
    expectedDistinct.sort()
    var uniqueDistinct: seq[uint64]
    for value in expectedDistinct:
      if uniqueDistinct.len == 0 or uniqueDistinct[^1] != value:
        uniqueDistinct.add value

    var wmDistinct = wm.collectDistinctValues(
      int64(qLeft), int64(qRight))
    var rwmDistinct = rwm.collectDistinctValues(
      int64(qLeft), int64(qRight))
    wmDistinct.sort()
    rwmDistinct.sort()
    doAssert wmDistinct == uniqueDistinct
    doAssert rwmDistinct == uniqueDistinct

    var cursor = wm.initWaveletSelectCursor(target)
    var occurrence = 0
    while occurrence < min(8'i64, cursor.count):
      let position = wm.nextSelect(cursor)
      doAssert position >= 0
      doAssert values[int(position)] == target
      inc occurrence

    let runRight = min(item.length, 4_096)
    doAssert wm.matchingRuns(target, 0, int64(runRight)) ==
      naiveRuns(values, target, 0, runRight)

echo "OK twavelet_fixed_depth_completeness"
