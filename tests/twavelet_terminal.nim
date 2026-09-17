import ../src/nbvs/[wavelet_matrix, wavelet_terminal, succinct_bit_vector]

proc initWaveletView(wm: WaveletMatrix,
    levelStorage: var seq[seq[uint64]],
    levelViews: var seq[SuccinctBitVectorView],
    zeroCounts: var seq[int64]): WaveletMatrixView =
  levelStorage = newSeq[seq[uint64]](wm.bitWidth)
  levelViews = newSeq[SuccinctBitVectorView](wm.bitWidth)
  for level in 0..<wm.bitWidth:
    let requiredBytes = requiredSuccinctBitVectorViewBytes(wm.n)
    levelStorage[level] = newSeq[uint64]((requiredBytes + 7) div 8)
    levelViews[level] = initSuccinctBitVectorView(
      addr levelStorage[level][0], requiredBytes, wm.n)
    for position in 0'i64..<wm.n:
      if wm.levels[level][position]:
        levelViews[level][position] = true
    levelViews[level].build()
  zeroCounts = wm.zeroCounts
  initWaveletMatrixView(wm.n, wm.bitWidth,
    cast[ptr UncheckedArray[SuccinctBitVectorView]](addr levelViews[0]),
    levelViews.len, addr zeroCounts[0], zeroCounts.len * sizeof(int64))

block terminalTraversal:
  let xs = @[5'u64, 1, 7, 5, 2, 9, 1, 5, 0, 7, 3, 5]
  let wm = genWaveletMatrix(xs)

  for position in 0'i64..<wm.n:
    let value = wm.access(position)
    let terminal = wm.terminalPosition(position)
    let fused = wm.accessWithTerminalPosition(position)
    let interval = wm.terminalInterval(value)

    doAssert fused.value == value
    doAssert fused.terminalPosition == terminal
    doAssert wm.terminalPositionUnchecked(position) == terminal
    doAssert wm.accessWithTerminalPositionUnchecked(position) == fused
    doAssert interval.left <= terminal
    doAssert terminal < interval.right
    doAssert terminal - interval.left == wm.rank(value, position)
    doAssert interval.right - interval.left == wm.rank(value, wm.n)

block terminalIntervals:
  let wm = genWaveletMatrix(@[5'u64, 1, 7, 5, 2, 9, 1, 5])

  for value in [1'u64, 2, 5, 7, 9]:
    let interval = wm.terminalInterval(value)
    doAssert interval.right - interval.left == wm.rank(value, wm.n)

  let absent = wm.terminalInterval(6)
  doAssert absent.left == absent.right

  let outOfAlphabet = wm.terminalInterval(1'u64 shl wm.bitWidth)
  doAssert outOfAlphabet.left == 0
  doAssert outOfAlphabet.right == 0

block viewMatchesOwned:
  let wm = genWaveletMatrix(@[5'u64, 1, 7, 5, 2, 9, 1, 5, 0, 7, 3, 5])
  var levelStorage: seq[seq[uint64]]
  var levelViews: seq[SuccinctBitVectorView]
  var zeroCounts: seq[int64]
  let view = wm.initWaveletView(levelStorage, levelViews, zeroCounts)

  for position in 0'i64..<wm.n:
    doAssert view.terminalPosition(position) == wm.terminalPosition(position)
    doAssert view.accessWithTerminalPosition(position) ==
      wm.accessWithTerminalPosition(position)

  for value in [0'u64, 1, 2, 3, 5, 6, 7, 9, 15]:
    doAssert view.terminalInterval(value) == wm.terminalInterval(value)

block fixedZeroBitWidth:
  let wm = genWaveletMatrix([0'u64, 0, 0], 0)
  for position in 0'i64..<wm.n:
    doAssert wm.terminalPosition(position) == position
    let fused = wm.accessWithTerminalPosition(position)
    doAssert fused.value == 0
    doAssert fused.terminalPosition == position

  let interval = wm.terminalInterval(0)
  doAssert interval == (left: 0'i64, right: 3'i64)

  let view = initWaveletMatrixView(3, 0, nil, 0, nil, 0)
  doAssert view.terminalInterval(0) == interval
  for position in 0'i64..<view.n:
    doAssert view.terminalPosition(position) == position
    doAssert view.accessWithTerminalPosition(position) ==
      (value: 0'u64, terminalPosition: position)

block checkedBounds:
  let wm = genWaveletMatrix(@[1'u64, 2, 3])
  var raised = false
  try:
    discard wm.terminalPosition(-1)
  except IndexDefect:
    raised = true
  doAssert raised

  raised = false
  try:
    discard wm.accessWithTerminalPosition(wm.n)
  except IndexDefect:
    raised = true
  doAssert raised
