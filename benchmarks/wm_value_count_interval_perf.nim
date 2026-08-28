import std/[algorithm, monotimes, strformat, times]
import nbvs/wavelet_matrix

type BenchCase = object
  n: int
  alphabet: uint64

const
  cases = [
    BenchCase(n: 65_536, alphabet: 4),
    BenchCase(n: 65_536, alphabet: 100),
    BenchCase(n: 65_536, alphabet: 1000),
    BenchCase(n: 1_048_576, alphabet: 4),
    BenchCase(n: 1_048_576, alphabet: 100),
    BenchCase(n: 1_048_576, alphabet: 1000)
  ]
  repeats = 11
  innerRepeats = 10

var sink {.volatile.}: uint64

func nextRand(x: var uint64): uint64 =
  x += 0x9e37_79b9_7f4a_7c15'u64
  var z = x
  z = (z xor (z shr 30)) * 0xbf58_476d_1ce4_e5b9'u64
  z = (z xor (z shr 27)) * 0x94d0_49bb_1331_11eb'u64
  z xor (z shr 31)

proc makeValues(c: BenchCase): seq[uint64] =
  result = newSeq[uint64](c.n)
  var state = 0x1234_5678_9abc_def0'u64 xor uint64(c.n) xor c.alphabet
  for i in 0..<result.len:
    result[i] = nextRand(state) mod c.alphabet

proc percentile(values: seq[int64], fraction: float): int64 =
  var sorted = values
  sorted.sort()
  sorted[min(sorted.high, int(float(sorted.high) * fraction + 0.5))]

proc measure(c: BenchCase) =
  let wm = genWaveletMatrix(makeValues(c))
  doAssert wm.collectValueCounts.len == wm.collectValueCountFinalIntervals.len

  var countsSamples: seq[int64]
  var intervalSamples: seq[int64]
  for _ in 0..<repeats:
    var started = getMonoTime()
    for _ in 0..<innerRepeats:
      let counts = wm.collectValueCounts()
      sink = sink xor uint64(counts.len)
    countsSamples.add((getMonoTime() - started).inNanoseconds div int64(innerRepeats))

    started = getMonoTime()
    for _ in 0..<innerRepeats:
      let intervals = wm.collectValueCountFinalIntervals()
      sink = sink xor uint64(intervals.len)
    intervalSamples.add((getMonoTime() - started).inNanoseconds div int64(innerRepeats))

  echo &"{c.n},{c.alphabet},{wm.bitWidth}," &
    &"{percentile(countsSamples, 0.50)},{percentile(countsSamples, 0.95)}," &
    &"{percentile(intervalSamples, 0.50)},{percentile(intervalSamples, 0.95)}"

when isMainModule:
  echo "rows,cardinality,bit_width,collect_counts_p50_ns,collect_counts_p95_ns," &
    "collect_final_intervals_p50_ns,collect_final_intervals_p95_ns"
  for c in cases:
    measure(c)
  stderr.writeLine("sink=", sink)
