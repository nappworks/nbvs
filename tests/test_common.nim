template expectRaises*(E: typedesc, body: untyped) =
  var raised = false
  try:
    body
  except E:
    raised = true
  doAssert raised
