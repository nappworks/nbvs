## RunLengthBwt primitiveとrun-start取得方式を比較します。

import std/[bitops, monotimes, os, parseutils, strformat, times]
import nbvs
import nbvs/internal/fm_symbols

const
  Iterations = 1_000_000
  Seed = 0x726c_655f_7265_7634'u64

type RunDistribution = enum
  rdUniform = "uniform"
  rdSkewed = "skewed"

var sink {.volatile.}: uint64

func nextRandom(state: var uint64): uint64 =
  state += 0x9e37_79b9_7f4a_7c15'u64
  var value = state
  value = (value xor (value shr 30)) * 0xbf58_476d_1ce4_e5b9'u64
  value = (value xor (value shr 27)) * 0x94d0_49bb_1331_11eb'u64
  value xor (value shr 31)

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

func requiredBitWidth(maximum: uint64): int =
  if maximum == 0: 0 else: 64 - countLeadingZeroBits(maximum)

proc makeBwt(length: int, runRatio: float,
             distribution: RunDistribution): seq[FmSymbol] =
  result = newSeq[FmSymbol](length)
  let targetRuns = max(1, min(length, int(length.float * runRatio)))
  var position = 0
  for run in 0..<targetRuns:
    let remainingRuns = targetRuns - run
    let remaining = length - position
    var runLength = max(1, remaining div remainingRuns)
    if distribution == rdSkewed and run + 1 < targetRuns:
      runLength = if (run and 15) == 0:
        min(remaining - remainingRuns + 1, runLength * 8)
      else:
        max(1, runLength div 2)
    let finish = if run + 1 == targetRuns: length
      else: min(length, position + runLength)
    for index in position..<finish:
      result[index] = FmSymbol(run mod AlphabetSize)
    position = finish

proc run(length: int, runRatio: float, distribution: RunDistribution) =
  let values = makeBwt(length, runRatio, distribution)
  var started = getMonoTime()
  let bwt = genRunLengthBwt(values)
  let buildNs = elapsedNs(started)

  var directStarts = genPackedArray(bwt.runCount,
    requiredBitWidth(uint64(max(0, length - 1))))
  for run in 0..<bwt.runCount:
    directStarts[run] = uint64(bwt.runStarts.select1(int64(run)))
  var state = Seed

  started = getMonoTime()
  for _ in 0..<Iterations:
    let position = int64(nextRandom(state) mod uint64(length))
    sink = sink xor bwt.accessRank(position).value
  let accessRankNs = elapsedNs(started)

  started = getMonoTime()
  for _ in 0..<Iterations:
    let left = int64(nextRandom(state) mod uint64(length + 1))
    let width = int64(nextRandom(state) mod 64)
    let right = min(int64(length), left + width)
    let symbol = FmSymbol(nextRandom(state) mod uint64(AlphabetSize))
    let ranks = bwt.rankPair(symbol, left, right)
    sink = sink xor uint64(ranks.leftRank + ranks.rightRank)
  let rankPairNs = elapsedNs(started)

  started = getMonoTime()
  for _ in 0..<Iterations:
    let run = int64(nextRandom(state) mod uint64(bwt.runCount))
    sink = sink xor uint64(bwt.runStarts.select1(run))
  let sbvSelectNs = elapsedNs(started)

  started = getMonoTime()
  for _ in 0..<Iterations:
    let run = int(nextRandom(state) mod uint64(bwt.runCount))
    sink = sink xor directStarts.getUnchecked(run)
  let packedStartNs = elapsedNs(started)

  echo &"{length},{runRatio:.2f},{distribution},{bwt.runCount}," &
    &"{bwt.memoryUsage},{directStarts.data.len * sizeof(uint64)}," &
    &"{float(buildNs) / 1e6:.3f}," &
    &"{float(rankPairNs) / Iterations.float:.2f}," &
    &"{float(accessRankNs) / Iterations.float:.2f}," &
    &"{float(sbvSelectNs) / Iterations.float:.2f}," &
    &"{float(packedStartNs) / Iterations.float:.2f}"

when isMainModule:
  var length = 1_000_000
  if paramCount() >= 1:
    discard parseInt(paramStr(1), length)
  if length <= 0:
    raise newException(ValueError, "length must be positive")
  echo "length,run_ratio,distribution,runs,rle_bytes,direct_start_bytes," &
    "build_ms,rank_pair_ns,access_rank_ns,sbv_select_ns,packed_start_ns"
  for ratio in [0.02, 0.05, 0.08, 0.10, 0.20, 0.50, 0.80]:
    for distribution in RunDistribution:
      run(length, ratio, distribution)
  stderr.writeLine("sink=", sink)
