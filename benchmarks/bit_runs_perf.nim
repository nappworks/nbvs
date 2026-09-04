import std/[algorithm, monotimes, os, parseutils, strformat, times]
import nbvs

type Sample = object
  iteratorNs: int64
  seqNs: int64
  scalarScanNs: int64

proc envInt(name: string, fallback: int): int =
  var value: int
  if parseInt(getEnv(name), value) > 0: value else: fallback

proc percentile(values: seq[int64], fraction: float): int64 =
  var ordered = values
  ordered.sort()
  ordered[min(ordered.high, int(float(ordered.high) * fraction + 0.5))]

proc makeBits(rows, runLength: int): SuccinctBitVector =
  result = genSuccinctBitVector(int64(rows))
  let period = runLength * 2
  for index in 0..<rows:
    if (index mod period) < runLength:
      result[int64(index)] = true
  result.build()

proc consumeItems(bits: SuccinctBitVector): int64 =
  for run in bits.bitRunsItems(true):
    result = result xor run.left xor run.right

proc consumeSeq(bits: SuccinctBitVector): int64 =
  for run in bits.bitRuns(true):
    result = result xor run.left xor run.right

proc consumeScalar(bits: SuccinctBitVector): int64 =
  var index = 0'i64
  while index < bits.lenOfBits:
    if not bits.access(index):
      inc index
      continue
    let left = index
    while index < bits.lenOfBits and bits.access(index):
      inc index
    result = result xor left xor index

proc measure(bits: SuccinctBitVector, repeats: int): Sample =
  var iteratorSamples, seqSamples, scalarSamples: seq[int64]
  var sink = 0'i64

  for _ in 0..<repeats:
    var started = getMonoTime()
    sink = sink xor consumeItems(bits)
    iteratorSamples.add (getMonoTime() - started).inNanoseconds

    started = getMonoTime()
    sink = sink xor consumeSeq(bits)
    seqSamples.add (getMonoTime() - started).inNanoseconds

    started = getMonoTime()
    sink = sink xor consumeScalar(bits)
    scalarSamples.add (getMonoTime() - started).inNanoseconds

  if sink == int64.low:
    echo sink

  result.iteratorNs = percentile(iteratorSamples, 0.50)
  result.seqNs = percentile(seqSamples, 0.50)
  result.scalarScanNs = percentile(scalarSamples, 0.50)

proc main() =
  let rows = max(10_000, envInt("NBVS_BIT_RUNS_ROWS", 1_000_000))
  let repeats = max(5, envInt("NBVS_BIT_RUNS_REPEATS", 21))

  echo "rows,run_length,runs,repeats,iterator_p50_ns,seq_p50_ns," &
    "scalar_scan_p50_ns,iterator_vs_scalar_speedup,seq_vs_scalar_speedup"

  for runLength in [1, 4, 16, 64, 256, 1024, 4096]:
    let bits = makeBits(rows, runLength)
    let runCount = bits.bitRuns(true).len
    let sample = measure(bits, repeats)
    let iteratorSpeedup = if sample.iteratorNs == 0: 0.0 else:
      float(sample.scalarScanNs) / float(sample.iteratorNs)
    let seqSpeedup = if sample.seqNs == 0: 0.0 else:
      float(sample.scalarScanNs) / float(sample.seqNs)

    echo &"{rows},{runLength},{runCount},{repeats},{sample.iteratorNs}," &
      &"{sample.seqNs},{sample.scalarScanNs},{iteratorSpeedup:.3f}," &
      &"{seqSpeedup:.3f}"

when isMainModule:
  main()
