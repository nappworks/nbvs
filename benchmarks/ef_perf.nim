import std/[monotimes, strformat, times]
import nbvs

type BenchCase = object
  n: int
  universePerValue: uint64

const
  cases = [
    BenchCase(n: 65_536, universePerValue: 16),
    BenchCase(n: 1_048_576, universePerValue: 2),
    BenchCase(n: 1_048_576, universePerValue: 16),
    BenchCase(n: 1_048_576, universePerValue: 256),
    BenchCase(n: 4_194_304, universePerValue: 16)
  ]
  buildIters = 20
  queryIters = 2_000_000

var sink {.volatile.}: uint64

func nextRand(x: var uint64): uint64 =
  x = x * 6364136223846793005'u64 + 1442695040888963407'u64
  x

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

proc makeValues(n: int, universe: uint64): seq[uint64] =
  ## Deterministic, strictly increasing input spread over the universe.
  result = newSeq[uint64](n)
  for i in 0..<n:
    result[i] = uint64(i) * universe div uint64(n)

proc makeIndices(n: int): seq[int64] =
  result = newSeq[int64](queryIters)
  var state = 0x0ddc_0ffe_e15e_beefu64 xor uint64(n)
  for i in 0..<result.len:
    result[i] = int64(nextRand(state) mod uint64(n))

proc makeQueries(universe: uint64): seq[uint64] =
  result = newSeq[uint64](queryIters)
  var state = 0xfedc_ba98_7654_3210'u64 xor universe
  for i in 0..<result.len:
    result[i] = nextRand(state) mod universe

proc storageBytes(ef: EliasFano): int64 =
  result = int64(ef.lows.data.len) * 8
  result += int64(ef.highBits.data.len) * 8
  result += int64(ef.highBits.blockPairPrefix.len) * 4
  result += int64(ef.highBits.selectStorage.len) * 8

proc runCase(c: BenchCase) =
  let universe = uint64(c.n) * c.universePerValue
  let xs = makeValues(c.n, universe)

  var ef: EliasFano
  var started = getMonoTime()
  for _ in 0..<buildIters:
    ef = genEliasFano(xs, universe)
    sink = sink xor uint64(ef.n)
  let buildNs = elapsedNs(started)

  let indices = makeIndices(c.n)
  let queries = makeQueries(universe)

  started = getMonoTime()
  for i in indices:
    sink = sink xor ef.access(i)
  let accessNs = elapsedNs(started)

  started = getMonoTime()
  for v in queries:
    sink = sink xor uint64(ef.lowerBound(v))
  let lowerBoundNs = elapsedNs(started)

  started = getMonoTime()
  for v in queries:
    sink = sink xor uint64(ef.upperBound(v))
  let upperBoundNs = elapsedNs(started)

  started = getMonoTime()
  for v in queries:
    sink = sink xor uint64(ef.predecessorIndex(v))
  let predecessorNs = elapsedNs(started)

  let mib = float(storageBytes(ef)) / 1024.0 / 1024.0
  echo &"{c.n},{universe},{c.universePerValue},{ef.lowBits},{mib:.3f}," &
    &"{float(buildNs) / float(buildIters) / 1_000_000.0:.6f}," &
    &"{float(accessNs) / float(queryIters):.3f}," &
    &"{float(lowerBoundNs) / float(queryIters):.3f}," &
    &"{float(upperBoundNs) / float(queryIters):.3f}," &
    &"{float(predecessorNs) / float(queryIters):.3f}"

when isMainModule:
  echo "n,universe,universe_per_value,low_bits,storage_mib,build_ms,access_ns,lower_bound_ns,upper_bound_ns,predecessor_index_ns"
  for c in cases:
    runCase(c)
  stderr.writeLine("sink=", sink)
