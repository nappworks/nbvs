import std/[algorithm, monotimes, strformat, times]
import nbvs/[succinct_bit_vector, wavelet_matrix]

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

func referenceFinalInterval(wm: WaveletMatrix, value: uint64):
    tuple[left, right: int64] =
  ## Benchmark-only reference path: re-traverse all WM levels for one value.
  ## This intentionally models the cost of recovering a terminal interval
  ## after value-count enumeration has already completed.
  var left = 0'i64
  var right = wm.n
  for level in 0..<wm.bitWidth:
    let shift = wm.bitWidth - level - 1
    let leftOnes = wm.levels[level].rank1Unchecked(left)
    let rightOnes = wm.levels[level].rank1Unchecked(right)
    if ((value shr shift) and 1'u64) == 0'u64:
      left -= leftOnes
      right -= rightOnes
    else:
      left = wm.zeroCounts[level] + leftOnes
      right = wm.zeroCounts[level] + rightOnes
  (left: left, right: right)

proc measure(c: BenchCase) =
  let wm = genWaveletMatrix(makeValues(c))
  let expectedCounts = wm.collectValueCounts()
  let expectedIntervals = wm.collectValueCountFinalIntervals()
  doAssert expectedCounts.len == expectedIntervals.len
  for i, item in expectedIntervals:
    doAssert item.value == expectedCounts[i].value
    doAssert item.frequency == expectedCounts[i].frequency
    let reference = wm.referenceFinalInterval(item.value)
    doAssert reference.left == item.left
    doAssert reference.right == item.right

  var countsSamples: seq[int64]
  var intervalSamples: seq[int64]
  var retraverseSamples: seq[int64]

  for _ in 0..<repeats:
    var started = getMonoTime()
    for _ in 0..<innerRepeats:
      let counts = wm.collectValueCounts()
      sink = sink xor uint64(counts.len)
    countsSamples.add(
      (getMonoTime() - started).inNanoseconds div int64(innerRepeats))

    started = getMonoTime()
    for _ in 0..<innerRepeats:
      let intervals = wm.collectValueCountFinalIntervals()
      sink = sink xor uint64(intervals.len)
    intervalSamples.add(
      (getMonoTime() - started).inNanoseconds div int64(innerRepeats))

    started = getMonoTime()
    for _ in 0..<innerRepeats:
      let counts = wm.collectValueCounts()
      for item in counts:
        let interval = wm.referenceFinalInterval(item.value)
        sink = sink xor uint64(interval.left)
        sink = sink xor uint64(interval.right)
    retraverseSamples.add(
      (getMonoTime() - started).inNanoseconds div int64(innerRepeats))

  let countsP50 = percentile(countsSamples, 0.50)
  let countsP95 = percentile(countsSamples, 0.95)
  let intervalP50 = percentile(intervalSamples, 0.50)
  let intervalP95 = percentile(intervalSamples, 0.95)
  let retraverseP50 = percentile(retraverseSamples, 0.50)
  let retraverseP95 = percentile(retraverseSamples, 0.95)

  echo &"{c.n},{c.alphabet},{wm.bitWidth}," &
    &"{countsP50},{countsP95}," &
    &"{intervalP50},{intervalP95}," &
    &"{retraverseP50},{retraverseP95}," &
    &"{float(intervalP50) / float(countsP50):.4f}," &
    &"{float(intervalP95) / float(countsP95):.4f}," &
    &"{float(retraverseP50) / float(intervalP50):.4f}," &
    &"{float(retraverseP95) / float(intervalP95):.4f}"

when isMainModule:
  echo "rows,cardinality,bit_width," &
    "collect_counts_p50_ns,collect_counts_p95_ns," &
    "collect_final_intervals_p50_ns,collect_final_intervals_p95_ns," &
    "collect_plus_retraverse_p50_ns,collect_plus_retraverse_p95_ns," &
    "interval_over_counts_p50,interval_over_counts_p95," &
    "retraverse_over_interval_p50,retraverse_over_interval_p95"
  for c in cases:
    measure(c)
  stderr.writeLine("sink=", sink)
