import std/algorithm

template expectRaises*(E: typedesc, body: untyped) =
  var raised = false
  try:
    body
  except E:
    raised = true
  doAssert raised

func naiveOccPosition*(xs: openArray[uint64], value: uint64,
                       pos: int): int64 =
  for x in xs:
    if x < value:
      inc result
  for i in 0..<pos:
    if xs[i] == value:
      inc result

func naiveValueCounts*(xs: openArray[uint64], left, right: int):
    seq[tuple[value: uint64, frequency: int64]] =
  var values = @xs[left..<right]
  values.sort()
  for value in values:
    if result.len == 0 or result[^1].value != value:
      result.add (value: value, frequency: 1'i64)
    else:
      inc result[^1].frequency

template assertEnumerations*(matrix, xs: untyped) =
  for left in 0..xs.len:
    for right in left..xs.len:
      let expectedCounts = naiveValueCounts(xs, left, right)
      var expectedValues: seq[uint64]
      for item in expectedCounts:
        expectedValues.add item.value

      var collectedCounts = matrix.collectValueCounts(int64(left), int64(right))
      var sortedCollectedCounts = collectedCounts
      sortedCollectedCounts.sort(proc(a, b: typeof(collectedCounts[0])): int =
        cmp(a.value, b.value))
      doAssert sortedCollectedCounts == expectedCounts
      doAssert matrix.valueCounts(int64(left), int64(right)) == expectedCounts

      var countItems: typeof(collectedCounts)
      for item in matrix.collectValueCountsItems(int64(left), int64(right)):
        countItems.add item
      doAssert countItems == collectedCounts
      countItems.setLen(0)
      for item in matrix.valueCountsItems(int64(left), int64(right)):
        countItems.add item
      doAssert countItems == expectedCounts

      let collectedValues =
        matrix.collectDistinctValues(int64(left), int64(right))
      var sortedCollectedValues = collectedValues
      sortedCollectedValues.sort()
      doAssert sortedCollectedValues == expectedValues
      doAssert matrix.distinctValues(int64(left), int64(right)) == expectedValues

      var valueItems: seq[uint64]
      for value in matrix.collectDistinctValuesItems(int64(left), int64(right)):
        valueItems.add value
      doAssert valueItems == collectedValues
      valueItems.setLen(0)
      for value in matrix.distinctValuesItems(int64(left), int64(right)):
        valueItems.add value
      doAssert valueItems == expectedValues
