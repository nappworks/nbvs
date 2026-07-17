import std/[monotimes, strformat, times]
import nbvs

const queryIters = 1_000_000
var sink {.volatile.}: uint64

func nextRand(x: var uint64): uint64 =
  x += 0x9e37_79b9_7f4a_7c15'u64
  var z = x
  z = (z xor (z shr 30)) * 0xbf58_476d_1ce4_e5b9'u64
  z = (z xor (z shr 27)) * 0x94d0_49bb_1331_11eb'u64
  z xor (z shr 31)

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

proc runCase(n: int, alphabet: uint64) =
  var state = 0x1234_5678_9abc_def0'u64 xor uint64(n) xor alphabet
  var xs = newSeq[uint64](n)
  for x in xs.mitems:
    x = nextRand(state) mod alphabet

  var lefts = newSeq[int64](queryIters)
  var rights = newSeq[int64](queryIters)
  var values = newSeq[uint64](queryIters)
  for i in 0..<queryIters:
    let a = int64(nextRand(state) mod uint64(n + 1))
    let b = int64(nextRand(state) mod uint64(n + 1))
    lefts[i] = min(a, b)
    rights[i] = max(a, b)
    values[i] = nextRand(state) mod alphabet

  let wm = genWaveletMatrix(xs)
  let rwm = genReversedWaveletMatrix(xs)

  var started = getMonoTime()
  for i in 0..<queryIters:
    sink = sink xor uint64(wm.rank(values[i], lefts[i], rights[i]))
  let wmDirect = elapsedNs(started)

  started = getMonoTime()
  for i in 0..<queryIters:
    sink = sink xor uint64(wm.rank(values[i], rights[i]) -
      wm.rank(values[i], lefts[i]))
  let wmTwoPrefix = elapsedNs(started)

  started = getMonoTime()
  for i in 0..<queryIters:
    sink = sink xor uint64(rwm.rank(values[i], lefts[i], rights[i]))
  let rwmDirect = elapsedNs(started)

  started = getMonoTime()
  for i in 0..<queryIters:
    sink = sink xor uint64(rwm.rank(values[i], rights[i]) -
      rwm.rank(values[i], lefts[i]))
  let rwmTwoPrefix = elapsedNs(started)

  echo &"{n},{alphabet},{wm.bitWidth}," &
    &"{float(wmDirect) / queryIters.float:.3f}," &
    &"{float(wmTwoPrefix) / queryIters.float:.3f}," &
    &"{float(rwmDirect) / queryIters.float:.3f}," &
    &"{float(rwmTwoPrefix) / queryIters.float:.3f}"

when isMainModule:
  echo "n,alphabet,bits,wm_direct_ns,wm_two_prefix_ns,rwm_direct_ns,rwm_two_prefix_ns"
  runCase(1_048_576, 256)
  runCase(1_048_576, 1_048_576)
  stderr.writeLine("sink=", sink)
