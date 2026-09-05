import nbvs

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

let values = @[3'u64, 1, 3, 2, 3, 1, 7, 3, 2, 3]
let wm = genWaveletMatrix(values)

block preparedSelectMatchesRegularSelect:
  let prepared = wm.initWaveletSelectCursor(3)
  doAssert prepared.count == wm.rank(3, 0, wm.n)
  for occurrence in 0'i64..<prepared.count:
    doAssert wm.selectPrepared(prepared, occurrence) == wm.select(3, occurrence)
  doAssert wm.selectPrepared(prepared, -1) == -1
  doAssert wm.selectPrepared(prepared, prepared.count) == -1

block sequentialCursorProducesOrderedPositions:
  var cursor = wm.initWaveletSelectCursor(3)
  var previous = -1'i64
  var count = 0'i64
  while true:
    let position = wm.nextSelect(cursor)
    if position < 0:
      break
    doAssert position > previous
    doAssert wm[position] == 3
    previous = position
    inc count
  doAssert count == wm.rank(3, 0, wm.n)
  doAssert cursor.remaining == 0
  doAssert wm.nextSelect(cursor) == -1

block uncheckedCursorMatchesRegularSelect:
  var cursor = wm.initWaveletSelectCursor(3)
  var occurrence = 0'i64
  while cursor.remaining > 0:
    doAssert wm.nextSelectUnchecked(cursor) == wm.select(3, occurrence)
    inc occurrence
  doAssert occurrence == wm.rank(3, 0, wm.n)

block missingValueIsEmpty:
  var cursor = wm.initWaveletSelectCursor(6)
  doAssert cursor.count == 0
  doAssert cursor.remaining == 0
  doAssert wm.nextSelect(cursor) == -1

block outOfDomainValueIsEmpty:
  let narrow = genWaveletMatrix(@[0'u64, 1, 2, 3], 2)
  var cursor = narrow.initWaveletSelectCursor(4)
  doAssert cursor.count == 0
  doAssert narrow.nextSelect(cursor) == -1

block viewCursorMatchesRegularSelect:
  var levelStorage: seq[seq[uint64]]
  var levelViews: seq[SuccinctBitVectorView]
  var zeroCounts: seq[int64]
  let view = wm.initWaveletView(levelStorage, levelViews, zeroCounts)
  for value in [0'u64, 1, 2, 3, 6, 7, 8]:
    var cursor = view.initWaveletSelectCursor(value)
    var occurrence = 0'i64
    while cursor.remaining > 0:
      let position = view.nextSelect(cursor)
      doAssert position == view.select(value, occurrence)
      inc occurrence
    doAssert occurrence == view.rank(value, 0, view.n)
    doAssert view.nextSelect(cursor) == -1

block largerMatrixAllValuesMatchRegularSelect:
  var larger = newSeq[uint64](4096)
  var state = 0x1234_5678_9abc_def0'u64
  for i in 0..<larger.len:
    state = state * 6364136223846793005'u64 + 1442695040888963407'u64
    larger[i] = (state shr 32) and 63'u64
  let largeWm = genWaveletMatrix(larger)

  for value in 0'u64..<64'u64:
    var cursor = largeWm.initWaveletSelectCursor(value)
    var occurrence = 0'i64
    while cursor.remaining > 0:
      doAssert largeWm.nextSelectUnchecked(cursor) ==
        largeWm.select(value, occurrence)
      inc occurrence
    doAssert occurrence == largeWm.rank(value, 0, largeWm.n)
