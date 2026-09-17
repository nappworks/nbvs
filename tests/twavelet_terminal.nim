import ../src/nbvs/[wavelet_matrix, wavelet_terminal]

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

block fixedZeroBitWidth:
  let wm = genWaveletMatrix([0'u64, 0, 0], 0)
  for position in 0'i64..<wm.n:
    doAssert wm.terminalPosition(position) == position
    let fused = wm.accessWithTerminalPosition(position)
    doAssert fused.value == 0
    doAssert fused.terminalPosition == position

  let interval = wm.terminalInterval(0)
  doAssert interval == (left: 0'i64, right: 3'i64)

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
