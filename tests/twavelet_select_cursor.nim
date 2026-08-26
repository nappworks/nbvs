import nbvs

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
