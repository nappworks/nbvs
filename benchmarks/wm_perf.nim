import std/[monotimes, strformat, times]
import nbvs

type BenchCase = object
  n: int
  alphabet: uint64

const
  cases = [
    BenchCase(n: 65_536, alphabet: 256),
    BenchCase(n: 1_048_576, alphabet: 256),
    BenchCase(n: 1_048_576, alphabet: 1_048_576),
    BenchCase(n: 4_194_304, alphabet: 256)
  ]
  buildIters = 10
  queryIters = 1_000_000
  valueCountsIters = 5

var sink {.volatile.}: uint64

func nextRand(x: var uint64): uint64 =
  x += 0x9e37_79b9_7f4a_7c15'u64
  var z = x
  z = (z xor (z shr 30)) * 0xbf58_476d_1ce4_e5b9'u64
  z = (z xor (z shr 27)) * 0x94d0_49bb_1331_11eb'u64
  z xor (z shr 31)

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

proc makeValues(c: BenchCase): seq[uint64] =
  result = newSeq[uint64](c.n)
  var state = 0x1234_5678_9abc_def0'u64 xor uint64(c.n) xor c.alphabet
  for i in 0..<result.len:
    result[i] = nextRand(state) mod c.alphabet

proc makePositions(n: int): seq[int64] =
  result = newSeq[int64](queryIters)
  var state = 0x0ddc_0ffe_e15e_beefu64 xor uint64(n)
  for i in 0..<result.len:
    result[i] = int64(nextRand(state) mod uint64(n))

proc makeRankValues(alphabet: uint64): seq[uint64] =
  result = newSeq[uint64](queryIters)
  var state = 0xfedc_ba98_7654_3210'u64 xor alphabet
  for i in 0..<result.len:
    result[i] = nextRand(state) mod alphabet

proc makeSelectQueries(xs: openArray[uint64], alphabet: uint64,
                       positions: openArray[int64]): tuple[values: seq[uint64], ks: seq[int64]] =
  var counts = newSeq[int64](int(alphabet))
  for x in xs:
    inc counts[int(x)]
  result.values = newSeq[uint64](positions.len)
  result.ks = newSeq[int64](positions.len)
  var state = 0x3141_5926_5358_9793'u64 xor alphabet
  for i, pos in positions:
    let value = xs[int(pos)]
    result.values[i] = value
    result.ks[i] = int64(nextRand(state) mod uint64(counts[int(value)]))

proc sbvStorageBytes(sbv: SuccinctBitVector): int64 =
  result = int64(sbv.data.len) * 8
  result += int64(sbv.blockPairPrefix.len) * 4
  result += int64(sbv.selectStorage.len) * 8

proc storageBytes(wm: WaveletMatrix): int64 =
  for level in wm.levels:
    result += sbvStorageBytes(level)

proc storageBytes(rwm: ReversedWaveletMatrix): int64 =
  for level in rwm.levels:
    result += sbvStorageBytes(level)

proc emit(kind: string, c: BenchCase, bitWidth: int, storage: int64,
          buildNs, accessNs, rankNs, selectNs, countsNs: int64) =
  echo &"{kind},{c.n},{c.alphabet},{bitWidth}," &
    &"{float(storage) / 1024.0 / 1024.0:.3f}," &
    &"{float(buildNs) / float(buildIters) / 1_000_000.0:.6f}," &
    &"{float(accessNs) / float(queryIters):.3f}," &
    &"{float(rankNs) / float(queryIters):.3f}," &
    &"{float(selectNs) / float(queryIters):.3f}," &
    &"{float(countsNs) / float(valueCountsIters) / 1_000_000.0:.6f}"

proc runWm(c: BenchCase, xs: seq[uint64], positions: seq[int64],
           rankValues, selectValues: seq[uint64], selectKs: seq[int64]) =
  var wm: WaveletMatrix
  var started = getMonoTime()
  for _ in 0..<buildIters:
    wm = genWaveletMatrix(xs)
    sink = sink xor uint64(wm.n)
  let buildNs = elapsedNs(started)

  started = getMonoTime()
  for pos in positions:
    sink = sink xor wm.access(pos)
  let accessNs = elapsedNs(started)

  started = getMonoTime()
  for i in 0..<queryIters:
    sink = sink xor uint64(wm.rank(rankValues[i], positions[i]))
  let rankNs = elapsedNs(started)

  started = getMonoTime()
  for i in 0..<queryIters:
    sink = sink xor uint64(wm.select(selectValues[i], selectKs[i]))
  let selectNs = elapsedNs(started)

  started = getMonoTime()
  for _ in 0..<valueCountsIters:
    let counts = wm.valueCounts()
    sink = sink xor uint64(counts.len)
  let countsNs = elapsedNs(started)
  emit("WM", c, wm.bitWidth, storageBytes(wm), buildNs, accessNs, rankNs,
    selectNs, countsNs)

proc runRwm(c: BenchCase, xs: seq[uint64], positions: seq[int64],
            rankValues, selectValues: seq[uint64], selectKs: seq[int64]) =
  var rwm: ReversedWaveletMatrix
  var started = getMonoTime()
  for _ in 0..<buildIters:
    rwm = genReversedWaveletMatrix(xs)
    sink = sink xor uint64(rwm.n)
  let buildNs = elapsedNs(started)

  started = getMonoTime()
  for pos in positions:
    sink = sink xor rwm.access(pos)
  let accessNs = elapsedNs(started)

  started = getMonoTime()
  for i in 0..<queryIters:
    sink = sink xor uint64(rwm.rank(rankValues[i], positions[i]))
  let rankNs = elapsedNs(started)

  started = getMonoTime()
  for i in 0..<queryIters:
    sink = sink xor uint64(rwm.select(selectValues[i], selectKs[i]))
  let selectNs = elapsedNs(started)

  started = getMonoTime()
  for _ in 0..<valueCountsIters:
    let counts = rwm.valueCounts()
    sink = sink xor uint64(counts.len)
  let countsNs = elapsedNs(started)
  emit("RWM", c, rwm.bitWidth, storageBytes(rwm), buildNs, accessNs, rankNs,
    selectNs, countsNs)

proc runCase(c: BenchCase) =
  let xs = makeValues(c)
  let positions = makePositions(c.n)
  let rankValues = makeRankValues(c.alphabet)
  let selectQueries = makeSelectQueries(xs, c.alphabet, positions)
  runWm(c, xs, positions, rankValues, selectQueries.values, selectQueries.ks)
  runRwm(c, xs, positions, rankValues, selectQueries.values, selectQueries.ks)

when isMainModule:
  echo "kind,n,alphabet,bit_width,storage_mib,build_ms,access_ns,rank_ns,select_ns,value_counts_ms"
  for c in cases:
    runCase(c)
  stderr.writeLine("sink=", sink)
