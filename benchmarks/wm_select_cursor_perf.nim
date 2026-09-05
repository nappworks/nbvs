import std/[algorithm, monotimes, os, parseutils, strformat, times]
import nbvs

type Sample = object
  regularNs: int64
  preparedNs: int64
  cursorNs: int64

proc envInt(name: string, fallback: int): int =
  var value: int
  if parseInt(getEnv(name), value) > 0: value else: fallback

proc percentile(values: seq[int64], fraction: float): int64 =
  var ordered = values
  ordered.sort()
  ordered[min(ordered.high, int(float(ordered.high) * fraction + 0.5))]

proc measure(wm: WaveletMatrix, value: uint64, repeats: int): Sample =
  let count = wm.rank(value, 0, wm.n)
  var regularSamples, preparedSamples, cursorSamples: seq[int64]
  var sink = 0'i64
  for _ in 0..<repeats:
    var started = getMonoTime()
    for occurrence in 0'i64..<count:
      sink = sink xor wm.select(value, occurrence)
    regularSamples.add (getMonoTime() - started).inNanoseconds

    let prepared = wm.initWaveletSelectCursor(value)
    started = getMonoTime()
    for occurrence in 0'i64..<count:
      sink = sink xor wm.selectPrepared(prepared, occurrence)
    preparedSamples.add (getMonoTime() - started).inNanoseconds

    started = getMonoTime()
    var cursor = wm.initWaveletSelectCursor(value)
    while cursor.remaining > 0:
      sink = sink xor wm.nextSelectUnchecked(cursor)
    cursorSamples.add (getMonoTime() - started).inNanoseconds

  if sink == int64.low:
    echo sink
  result.regularNs = percentile(regularSamples, 0.50)
  result.preparedNs = percentile(preparedSamples, 0.50)
  result.cursorNs = percentile(cursorSamples, 0.50)

proc main() =
  let rows = max(10_000, envInt("NBVS_SELECT_CURSOR_ROWS", 1_000_000))
  let repeats = max(5, envInt("NBVS_SELECT_CURSOR_REPEATS", 21))
  echo "rows,cardinality,occurrences,repeats,normal_select_p50_ns," &
    "prepared_select_p50_ns,sequential_cursor_p50_ns," &
    "prepared_vs_normal_speedup,cursor_vs_normal_speedup," &
    "cursor_vs_prepared_speedup,normal_ns_per_occurrence," &
    "prepared_ns_per_occurrence,cursor_ns_per_occurrence"
  for cardinality in [4, 100, 1000, 10_000]:
    var values = newSeq[uint64](rows)
    for index in 0..<rows:
      values[index] = uint64(index mod cardinality)
    let wm = genWaveletMatrix(values)
    let target = uint64(cardinality - 1)
    let occurrences = wm.rank(target, 0, wm.n)
    let sample = measure(wm, target, repeats)
    let preparedSpeedup = if sample.preparedNs == 0: 0.0 else:
      float(sample.regularNs) / float(sample.preparedNs)
    let cursorSpeedup = if sample.cursorNs == 0: 0.0 else:
      float(sample.regularNs) / float(sample.cursorNs)
    let cursorVsPrepared = if sample.cursorNs == 0: 0.0 else:
      float(sample.preparedNs) / float(sample.cursorNs)
    let regularPerOccurrence = float(sample.regularNs) / float(occurrences)
    let preparedPerOccurrence = float(sample.preparedNs) / float(occurrences)
    let cursorPerOccurrence = float(sample.cursorNs) / float(occurrences)
    echo &"{rows},{cardinality},{occurrences},{repeats},{sample.regularNs}," &
      &"{sample.preparedNs},{sample.cursorNs},{preparedSpeedup:.3f}," &
      &"{cursorSpeedup:.3f},{cursorVsPrepared:.3f}," &
      &"{regularPerOccurrence:.3f},{preparedPerOccurrence:.3f}," &
      &"{cursorPerOccurrence:.3f}"

when isMainModule:
  main()
