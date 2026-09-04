import std/[algorithm, monotimes, os, parseutils, strformat, times]
import nbvs

type
  Sample = object
    iteratorNs: int64
    seqNs: int64
    regularSelectNs: int64
    cursorSelectNs: int64

proc envInt(name: string, fallback: int): int =
  var value: int
  if parseInt(getEnv(name), value) > 0: value else: fallback

proc percentile(values: seq[int64], fraction: float): int64 =
  var ordered = values
  ordered.sort()
  ordered[min(ordered.high, int(float(ordered.high) * fraction + 0.5))]

proc consumeMatchingRunsItems(wm: WaveletMatrix, target: uint64): int64 =
  for run in wm.matchingRunsItems(target):
    result = result xor run.left xor run.right

proc consumeMatchingRunsSeq(wm: WaveletMatrix, target: uint64): int64 =
  for run in wm.matchingRuns(target):
    result = result xor run.left xor run.right

proc consumeRegularSelect(wm: WaveletMatrix, target: uint64,
    occurrences: int64): int64 =
  var previous = -2'i64
  var runLeft = -1'i64
  for occurrence in 0'i64..<occurrences:
    let position = wm.select(target, occurrence)
    if position != previous + 1:
      if runLeft >= 0:
        result = result xor runLeft xor (previous + 1)
      runLeft = position
    previous = position
  if runLeft >= 0:
    result = result xor runLeft xor (previous + 1)

proc consumeCursorSelect(wm: WaveletMatrix, target: uint64): int64 =
  var cursor = wm.initWaveletSelectCursor(target)
  var previous = -2'i64
  var runLeft = -1'i64
  while cursor.remaining > 0:
    let position = wm.nextSelect(cursor)
    if position != previous + 1:
      if runLeft >= 0:
        result = result xor runLeft xor (previous + 1)
      runLeft = position
    previous = position
  if runLeft >= 0:
    result = result xor runLeft xor (previous + 1)

proc measure(wm: WaveletMatrix, target: uint64, repeats: int): Sample =
  let occurrences = wm.rank(target, 0, wm.n)
  var iteratorSamples, seqSamples: seq[int64]
  var regularSelectSamples, cursorSelectSamples: seq[int64]
  var sink = 0'i64

  for _ in 0..<repeats:
    var started = getMonoTime()
    sink = sink xor consumeMatchingRunsItems(wm, target)
    iteratorSamples.add (getMonoTime() - started).inNanoseconds

    started = getMonoTime()
    sink = sink xor consumeMatchingRunsSeq(wm, target)
    seqSamples.add (getMonoTime() - started).inNanoseconds

    started = getMonoTime()
    sink = sink xor consumeRegularSelect(wm, target, occurrences)
    regularSelectSamples.add (getMonoTime() - started).inNanoseconds

    started = getMonoTime()
    sink = sink xor consumeCursorSelect(wm, target)
    cursorSelectSamples.add (getMonoTime() - started).inNanoseconds

  if sink == int64.low:
    echo sink

  result.iteratorNs = percentile(iteratorSamples, 0.50)
  result.seqNs = percentile(seqSamples, 0.50)
  result.regularSelectNs = percentile(regularSelectSamples, 0.50)
  result.cursorSelectNs = percentile(cursorSelectSamples, 0.50)

proc makeValues(rows, runLength: int, target: uint64): seq[uint64] =
  ## 一致率を約25%に固定し、target run の長さだけを変えます。
  result = newSeq[uint64](rows)
  let period = runLength * 4
  for index in 0..<rows:
    if (index mod period) < runLength:
      result[index] = target
    else:
      result[index] = uint64((index mod 6) + 1)
      if result[index] == target:
        result[index] = 1

proc main() =
  let rows = max(10_000, envInt("NBVS_MATCHING_RUNS_ROWS", 1_000_000))
  let repeats = max(5, envInt("NBVS_MATCHING_RUNS_REPEATS", 21))
  let target = 7'u64

  echo "rows,run_length,occurrences,runs,repeats,iterator_p50_ns,seq_p50_ns," &
    "regular_select_p50_ns,cursor_select_p50_ns," &
    "iterator_vs_regular_speedup,iterator_vs_cursor_speedup," &
    "seq_vs_regular_speedup,seq_vs_cursor_speedup"

  for runLength in [1, 4, 16, 64, 256, 1024, 4096]:
    let values = makeValues(rows, runLength, target)
    let wm = genWaveletMatrix(values)
    let occurrences = wm.rank(target, 0, wm.n)
    let runCount = wm.matchingRuns(target).len
    let sample = measure(wm, target, repeats)

    let iteratorRegular = if sample.iteratorNs == 0: 0.0 else:
      float(sample.regularSelectNs) / float(sample.iteratorNs)
    let iteratorCursor = if sample.iteratorNs == 0: 0.0 else:
      float(sample.cursorSelectNs) / float(sample.iteratorNs)
    let seqRegular = if sample.seqNs == 0: 0.0 else:
      float(sample.regularSelectNs) / float(sample.seqNs)
    let seqCursor = if sample.seqNs == 0: 0.0 else:
      float(sample.cursorSelectNs) / float(sample.seqNs)

    echo &"{rows},{runLength},{occurrences},{runCount},{repeats}," &
      &"{sample.iteratorNs},{sample.seqNs},{sample.regularSelectNs}," &
      &"{sample.cursorSelectNs},{iteratorRegular:.3f},{iteratorCursor:.3f}," &
      &"{seqRegular:.3f},{seqCursor:.3f}"

when isMainModule:
  main()
