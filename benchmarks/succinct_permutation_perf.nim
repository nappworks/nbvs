## SuccinctPermutationと完全なpacked inverseを持つ基準実装を比較します。
##
## 固定seedで生成した単一の長いcycleを使用し、build、forward lookup、
## inverse lookup、論理格納容量を測定します。

import std/[algorithm, monotimes, strformat, times]
import nbvs/[packed_array, succinct_permutation]

type
  PackedPermutationPair = object
    forward: PackedArray
    inverse: PackedArray

const
  sizes = [65_536, 1_048_576]
  strides = [8, 32, 128]
  queryCount = 200_000
  warmupIters = 1
  measuredIters = 7

var sink {.volatile.}: uint64

func nextRand(state: var uint64): uint64 {.inline.} =
  state = state * 6364136223846793005'u64 + 1442695040888963407'u64
  state

proc makeLongCycle(n: int): seq[uint64] =
  ## Fisher-Yatesでnode順を決め、全nodeを含む単一cycleを構築します。
  var nodes = newSeq[uint64](n)
  for index in 0..<n:
    nodes[index] = uint64(index)

  var state = 0x6a09_e667_f3bc_c909'u64 xor uint64(n)
  for index in countdown(n - 1, 1):
    let other = int(nextRand(state) mod uint64(index + 1))
    swap nodes[index], nodes[other]

  result = newSeq[uint64](n)
  for index in 0..<n:
    result[int(nodes[index])] = nodes[(index + 1) mod n]

proc makeQueries(n: int): seq[int] =
  result = newSeq[int](queryCount)
  var state = 0xbb67_ae85_84ca_a73b'u64 xor uint64(n)
  for query in result.mitems:
    query = int(nextRand(state) mod uint64(n))

func median(samples: var seq[int64]): int64 =
  samples.sort()
  samples[samples.len div 2]

template measureMedian(body: untyped): int64 =
  block:
    var samples = newSeqOfCap[int64](measuredIters)
    for iteration in 0..<(warmupIters + measuredIters):
      let started = getMonoTime()
      body
      let elapsed = (getMonoTime() - started).inNanoseconds
      if iteration >= warmupIters:
        samples.add elapsed
    median(samples)

proc genPackedPermutationPair(values: openArray[
    uint64]): PackedPermutationPair =
  let width = permutationBitWidth(int64(values.len))
  result.forward = genPackedArray(int64(values.len), width)
  result.inverse = genPackedArray(int64(values.len), width)
  for index, value in values:
    result.forward[int64(index)] = value
    result.inverse[int64(value)] = uint64(index)

func packedPairBytes(pair: PackedPermutationPair): int64 =
  int64((pair.forward.data.len + pair.inverse.data.len) * sizeof(uint64))

func succinctBytes(permutation: SuccinctPermutation): int64 =
  let landmarkWords = permutation.landmarks.data.len +
    permutation.landmarks.selectStorage.len
  let compatibilityBytes =
    (permutation.landmarks.blockPairPrefix.len +
      permutation.landmarks.wordPairPrefix.len) * sizeof(uint32)
  int64((permutation.values.data.len + landmarkWords +
    permutation.previousLandmarks.data.len) * sizeof(uint64) +
    compatibilityBytes)

proc main() =
  echo "n,inverse_stride,queries,repeats,landmarks,succinct_bytes," &
    "packed_pair_bytes,memory_ratio,succinct_build_p50_ms," &
    "packed_pair_build_p50_ms,succinct_access_p50_ns," &
    "packed_pair_access_p50_ns,succinct_inverse_p50_ns," &
    "packed_pair_inverse_p50_ns,inverse_slowdown"

  for n in sizes:
    let values = makeLongCycle(n)
    let queries = makeQueries(n)

    for stride in strides:
      var permutation = genSuccinctPermutation(values, stride)
      var pair = genPackedPermutationPair(values)

      let succinctBuildNs = measureMedian:
        permutation = genSuccinctPermutation(values, stride)
        sink = sink xor uint64(permutation.landmarkCount)

      let pairBuildNs = measureMedian:
        pair = genPackedPermutationPair(values)
        sink = sink xor pair.inverse[int64(queries[0])]

      let succinctAccessNs = measureMedian:
        for query in queries:
          sink = sink xor permutation.accessUnchecked(query)

      let pairAccessNs = measureMedian:
        for query in queries:
          sink = sink xor pair.forward.getUnchecked(query)

      let succinctInverseNs = measureMedian:
        for query in queries:
          sink = sink xor permutation.inverseUnchecked(uint64(query))

      let pairInverseNs = measureMedian:
        for query in queries:
          sink = sink xor pair.inverse.getUnchecked(query)

      let permutationBytes = permutation.succinctBytes
      let baselineBytes = pair.packedPairBytes
      let memoryRatio = float(permutationBytes) / float(baselineBytes)
      let inverseSlowdown = float(succinctInverseNs) / float(pairInverseNs)

      echo &"{n},{stride},{queryCount},{measuredIters}," &
        &"{permutation.landmarkCount},{permutationBytes},{baselineBytes}," &
        &"{memoryRatio:.6f},{float(succinctBuildNs) / 1_000_000.0:.6f}," &
        &"{float(pairBuildNs) / 1_000_000.0:.6f}," &
        &"{float(succinctAccessNs) / queryCount.float:.3f}," &
        &"{float(pairAccessNs) / queryCount.float:.3f}," &
        &"{float(succinctInverseNs) / queryCount.float:.3f}," &
        &"{float(pairInverseNs) / queryCount.float:.3f}," &
        &"{inverseSlowdown:.3f}"

  if sink == uint64.high:
    echo sink

when isMainModule:
  main()
