import std/[algorithm, monotimes, os, parseutils, strformat]
import nbvs

type Sample = object
  regularNs: int64
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
  var regularSamples, cursorSamples: seq[int64]
  var sink = 0'i64
  for _ in 0..<repeats:
    var started = getMonoTime()
    for occurrence in 0'i64..<count:
      sink = sink xor wm.select(value, occurrence)
    regularSamples.add (getMonoTime() - started).inNanoseconds

    started = getMonoTime()
    var cursor = wm.initWaveletSelectCursor(value)
    while cursor.remaining > 0:
      sink = sink xor wm.nextSelect(cursor)
    cursorSamples.add (getMonoTime() - started).inNanoseconds

  if sink == int64.low:
    echo sink
  result.regularNs = percentile(regularSamples, 0.50)
  result.cursorNs = percentile(cursorSamples, 0.50)

proc main() =
  let rows = max(10_000, envInt("NBVS_SELECT_CURSOR_ROWS", 1_000_000))
  let repeats = max(5, envInt("NBVS_SELECT_CURSOR_REPEATS", 21))
  echo "rows,cardinality,occurrences,regular_p50_ns,cursor_p50_ns,speedup"
  for cardinality in [4, 100, 1000, 10_000]:
    var values = newSeq[uint64](rows)
    for index in 0..<rows:
      values[index] = uint64(index mod cardinality)
    let wm = genWaveletMatrix(values)
    let target = uint64(cardinality - 1)
    let occurrences = wm.rank(target, 0, wm.n)
    let sample = measure(wm, target, repeats)
    let speedup = if sample.cursorNs == 0: 0.0 else:
      float(sample.regularNs) / float(sample.cursorNs)
    echo &"{rows},{cardinality},{occurrences},{sample.regularNs},{sample.cursorNs},{speedup:.3f}"

when isMainModule:
  main()
