import std/[monotimes, strformat, times]
import nbvs

type BenchCase = object
  bits: int64
  densityPercent: int

const
  cases = [
    BenchCase(bits: 1_048_576'i64, densityPercent: 50),
    BenchCase(bits: 16_777_216'i64, densityPercent: 50),
    BenchCase(bits: 67_108_864'i64, densityPercent: 50),
    BenchCase(bits: 16_777_216'i64, densityPercent: 1),
    BenchCase(bits: 16_777_216'i64, densityPercent: 99)
  ]
  buildIters = 20
  queryIters = 2_000_000

var sink {.volatile.}: int64

func nextRand(x: var uint64): uint64 =
  x = x * 6364136223846793005'u64 + 1442695040888963407'u64
  x

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

proc fillData(sbv: var SuccinctBitVector, densityPercent: int) =
  var state = 0x1234_5678_9abc_def0'u64 xor uint64(sbv.lenOfBits)
  if densityPercent == 50:
    for w in 0..<sbv.dataWords:
      sbv.data[w] = nextRand(state)
  else:
    let threshold = uint64(densityPercent) * (uint64.high div 100'u64)
    for bit in 0'i64..<sbv.lenOfBits:
      if nextRand(state) < threshold:
        sbv.data[int(bit div 64)] = sbv.data[int(bit div 64)] or (1'u64 shl int(bit mod 64))

  let tail = sbv.lenOfBits mod 64
  if tail != 0 and sbv.dataWords > 0:
    sbv.data[sbv.dataWords - 1] = sbv.data[sbv.dataWords - 1] and
      ((1'u64 shl int(tail)) - 1'u64)

proc makePositions(n: int64): seq[int64] =
  result = newSeq[int64](queryIters)
  var state = 0x0ddc_0ffe_e15e_beefu64 xor uint64(n)
  for i in 0..<result.len:
    result[i] = int64(nextRand(state) mod uint64(n))

proc makeTargets(total: int64): seq[int64] =
  result = newSeq[int64](queryIters)
  var state = 0xfedc_ba98_7654_3210'u64 xor uint64(total)
  for i in 0..<result.len:
    result[i] = int64(nextRand(state) mod uint64(total))

proc runCase(c: BenchCase) =
  var sbv = genSuccinctBitVector(c.bits)
  sbv.fillData(c.densityPercent)

  var started = getMonoTime()
  for _ in 0..<buildIters:
    sbv.build()
    sink = sink xor sbv.totalOnes
  let buildNs = elapsedNs(started)

  let positions = makePositions(c.bits)
  let oneTargets = makeTargets(sbv.totalOnes)
  let zeroTargets = makeTargets(sbv.totalZeros)

  started = getMonoTime()
  for p in positions:
    sink = sink xor sbv.rank1(p)
  let rankNs = elapsedNs(started)

  started = getMonoTime()
  for k in oneTargets:
    sink = sink xor sbv.select1(k)
  let select1Ns = elapsedNs(started)

  started = getMonoTime()
  for k in zeroTargets:
    sink = sink xor sbv.select0(k)
  let select0Ns = elapsedNs(started)

  let mib = float(c.bits) / 8.0 / 1024.0 / 1024.0
  echo &"{c.bits},{c.densityPercent},{sbv.totalOnes},{mib:.2f}," &
    &"{float(buildNs) / float(buildIters) / 1_000_000.0:.6f}," &
    &"{float(rankNs) / float(queryIters):.3f}," &
    &"{float(select1Ns) / float(queryIters):.3f}," &
    &"{float(select0Ns) / float(queryIters):.3f}"

when isMainModule:
  echo "bits,density_percent,total_ones,mib,build_ms,rank1_ns,select1_ns,select0_ns"
  for c in cases:
    runCase(c)
  stderr.writeLine("sink=", sink)
