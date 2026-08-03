## Select経路のleaf分布を製品コードへcounterを追加せずに測定します。
import std/[monotimes, strformat, times]
import nbvs/succinct_bit_vector

const
  BitLength = 16_777_217'i64
  QueryCount = 100_000

var sink {.volatile.}: int64

func nextRand(state: var uint64): uint64 =
  state = state * 6364136223846793005'u64 + 1442695040888963407'u64
  state

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

proc makeVector(): SuccinctBitVector =
  result = genSuccinctBitVector(BitLength)
  var state = 0x1234_5678_9abc_def0'u64
  for wordIndex in 0..<result.dataWords:
    result.data[wordIndex] = nextRand(state)
  result.data[^1] = result.data[^1] and 1'u64
  result.build()

proc profile(sbv: SuccinctBitVector, ones: bool): tuple[
    queryNs: float, offsets: array[8, int], tailQueries: int] =
  var state = if ones: 0x1111_2222_3333_4444'u64 else: 0xaaaa_bbbb_cccc_dddd'u64
  let total = if ones: sbv.totalOnes else: sbv.totalZeros
  var targets = newSeq[int64](QueryCount)
  for target in targets.mitems:
    target = int64(nextRand(state) mod uint64(total))
  targets[^1] = total - 1

  let started = getMonoTime()
  for target in targets:
    let pos = if ones: sbv.select1(target) else: sbv.select0(target)
    sink = sink xor pos
  result.queryNs = float(elapsedNs(started)) / float(QueryCount)

  let tailBase = (sbv.lenOfBits shr 9) shl 9
  for target in targets:
    let pos = if ones: sbv.select1(target) else: sbv.select0(target)
    inc result.offsets[int((pos shr 6) and 7)]
    if pos >= tailBase:
      inc result.tailQueries

when isMainModule:
  let sbv = makeVector()
  let ones = profile(sbv, true)
  let zeros = profile(sbv, false)
  let backend = when defined(nbvsSimd): "simd" else: "scalar"
  echo &"{{\"backend\":\"{backend}\",\"bits\":{BitLength}," &
    &"\"queries\":{QueryCount},\"treeDepth\":{sbv.level}," &
    &"\"select1Ns\":{ones.queryNs:.3f},\"select0Ns\":{zeros.queryNs:.3f}," &
    &"\"select1Offsets\":{ones.offsets},\"select0Offsets\":{zeros.offsets}," &
    &"\"select1TailQueries\":{ones.tailQueries}," &
    &"\"select0TailQueries\":{zeros.tailQueries}}}"
  stderr.writeLine("sink=", sink)
