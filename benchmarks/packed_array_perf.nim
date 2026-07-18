import std/[monotimes, strformat, times]
import nbvs/packed_array

const
  elementCount = 1_048_576
  fillIters = 10
  toSeqIters = 5
  setIters = 3
  getIters = 2_000_000
  widths = [1, 3, 7, 8, 13, 16, 31, 32, 63, 64]

var sink {.volatile.}: uint64

func nextRand(state: var uint64): uint64 =
  state = state * 6364136223846793005'u64 + 1442695040888963407'u64
  state

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

proc makeIndices(): seq[int64] =
  result = newSeq[int64](getIters)
  var state = 0x0ddc_0ffe_e15e_beef'u64
  for index in result.mitems:
    index = int64(nextRand(state) mod uint64(elementCount))

proc runCase(bitWidth: int, indices: openArray[int64]) =
  let mask = maskForWidth(bitWidth)
  let fillValue = 0xa5a5_a5a5_a5a5_a5a5'u64 and mask
  var packed = genPackedArray(elementCount, bitWidth)

  var started = getMonoTime()
  for iteration in 0..<fillIters:
    packed.fill((fillValue xor uint64(iteration and 1)) and mask)
    sink = sink xor packed.data[iteration mod packed.data.len]
  let fillNs = elapsedNs(started)

  started = getMonoTime()
  for iteration in 0..<setIters:
    for i in 0'i64..<packed.len:
      packed[i] = (uint64(i) + uint64(iteration)) and mask
    sink = sink xor packed.data[iteration mod packed.data.len]
  let setNs = elapsedNs(started)

  started = getMonoTime()
  for _ in 0..<toSeqIters:
    let unpacked = packed.toSeq()
    sink = sink xor unpacked[unpacked.len div 2]
  let toSeqNs = elapsedNs(started)

  started = getMonoTime()
  for index in indices:
    sink = sink xor packed[index]
  let getNs = elapsedNs(started)

  let storageMiB = float(packed.data.len * sizeof(uint64)) / 1024.0 / 1024.0
  echo &"{bitWidth},{storageMiB:.3f}," &
    &"{float(fillNs) / float(fillIters) / 1_000_000.0:.6f}," &
    &"{float(toSeqNs) / float(toSeqIters) / 1_000_000.0:.6f}," &
    &"{float(setNs) / float(setIters) / float(elementCount):.3f}," &
    &"{float(getNs) / float(getIters):.3f}"

when isMainModule:
  let indices = makeIndices()
  echo "bit_width,storage_mib,fill_ms,to_seq_ms,sequential_set_ns,random_get_ns"
  for bitWidth in widths:
    runCase(bitWidth, indices)
  stderr.writeLine("sink=", sink)
