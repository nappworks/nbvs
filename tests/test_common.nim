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
