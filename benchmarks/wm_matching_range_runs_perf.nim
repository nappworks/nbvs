## Wavelet Matrix range-run列挙をaccess baselineと比較するbenchmarkです。
##
## 同一Wavelet Matrix・同一physical range・同一value rangeについて、
## `access + compare`、PR #22相当のposition predicate scan、
## Stage B adaptive `matchingRangeRunsItems` をsame-binaryで比較します。

import std/[algorithm, monotimes, os, parseopt, strformat, strutils, times]
import nbvs

type
  DataShape = enum
    dsRandom,
    dsClustered,
    dsPeriodic

  Summary = object
    shape: DataShape
    bitWidth: int
    selectivity: int
    methodName: string
    strategyName: string
    p50, p95, p99: float
    speedupVsAccess: float
    speedupVsPosition: float
    runCount, matchedRows: int64

const
  # 84 workload cases × 3 methods を通常の開発PCで反復できる規模を
  # defaultにします。1M/11 repeatsは明示引数でextended measurementとして実行します。
  DefaultRows = 262_144
  DefaultRepeats = 7
  BitWidths = [8, 16, 32, 64]
  Selectivities = [1, 5, 10, 25, 40, 90, 100]
  Backend = when defined(nbvsSimd): "simd" else: "scalar"
  BuildFlags = when defined(nbvsSimd):
    "-d:release --mm:arc -d:nbvsSimd"
  else:
    "-d:release --mm:arc"

var sink {.volatile.}: uint64

func nextRand(state: var uint64): uint64 =
  state += 0x9e37_79b9_7f4a_7c15'u64
  var value = state
  value = (value xor (value shr 30)) * 0xbf58_476d_1ce4_e5b9'u64
  value = (value xor (value shr 27)) * 0x94d0_49bb_1331_11eb'u64
  value xor (value shr 31)

func domainHigh(bitWidth: int): uint64 =
  if bitWidth >= 64: uint64.high
  elif bitWidth <= 0: 0'u64
  else: (1'u64 shl bitWidth) - 1'u64

func shapeName(shape: DataShape): string =
  case shape
  of dsRandom: "random"
  of dsClustered: "clustered"
  of dsPeriodic: "periodic"

proc percentile(samples: seq[float], fraction: float): float =
  var ordered = samples
  ordered.sort()
  let index = min(ordered.high,
    int(float(ordered.len - 1) * fraction + 0.999999))
  ordered[index]

proc makeValues(rowCount, bitWidth: int, shape: DataShape): seq[uint64] =
  result = newSeq[uint64](rowCount)
  let mask = domainHigh(bitWidth)
  case shape
  of dsRandom:
    var state = 0x52414e474552554e'u64 xor uint64(bitWidth)
    for value in result.mitems:
      value = nextRand(state) and mask
  of dsClustered:
    # 同一値のphysical runを作りつつ、値域全体へcluster valueを分散します。
    const clusterSize = 256
    var state = 0x434c555354455245'u64 xor uint64(bitWidth)
    var clusterValue = 0'u64
    for position in 0..<rowCount:
      if position mod clusterSize == 0:
        clusterValue = nextRand(state) and mask
      result[position] = clusterValue
  of dsPeriodic:
    # odd multiplierで値域へ分散し、隣接一致が少ないfragmented入力を作ります。
    const multiplier = 0x9e37_79b9_7f4a_7c15'u64
    for position in 0..<rowCount:
      result[position] = (uint64(position) * multiplier) and mask

func queryRange(bitWidth, selectivity: int): tuple[low, high: uint64] =
  let highDomain = domainHigh(bitWidth)
  if selectivity >= 100:
    return (0'u64, highDomain)

  # uint64.high + 1を作らず、おおよそのdomain割合を安全に求めます。
  var span = (highDomain div 100'u64) * uint64(selectivity)
  span += ((highDomain mod 100'u64) * uint64(selectivity)) div 100'u64
  span = max(1'u64, span)
  let low = (highDomain - span) div 2'u64
  (low, low + span - 1'u64)

proc mixRun(checksum: var uint64, left, right: int64) {.inline.} =
  checksum = checksum xor
    ((uint64(left) + 0x9e37_79b9'u64) * 0xbf58_476d'u64)
  checksum = checksum xor
    ((uint64(right) + 0x94d0_49bb'u64) * 0x1331_11eb'u64)

proc baselineAccessRuns(wm: WaveletMatrix, low, high: uint64):
    tuple[checksum: uint64, runCount, matchedRows: int64] =
  var pending = false
  var pendingLeft = 0'i64
  for position in 0'i64..<wm.n:
    let value = wm.access(position)
    let matches = value >= low and value <= high
    if matches:
      if not pending:
        pending = true
        pendingLeft = position
    elif pending:
      mixRun(result.checksum, pendingLeft, position)
      inc result.runCount
      result.matchedRows += position - pendingLeft
      pending = false
  if pending:
    mixRun(result.checksum, pendingLeft, wm.n)
    inc result.runCount
    result.matchedRows += wm.n - pendingLeft

proc positionPredicateRuns(wm: WaveletMatrix, low, high: uint64):
    tuple[checksum: uint64, runCount, matchedRows: int64] =
  ## PR #22のpublic routeをbenchmark内で固定再現します。
  ## full-domain / equality fast pathは維持し、general rangeだけ
  ## `valueInRangeAtUnchecked` をphysical positionごとに呼びます。
  if wm.n == 0 or low > high:
    return

  let highDomain = domainHigh(wm.bitWidth)
  if low > highDomain:
    return
  if low == 0 and high >= highDomain:
    mixRun(result.checksum, 0, wm.n)
    result.runCount = 1
    result.matchedRows = wm.n
    return
  if low == high:
    for run in wm.matchingRunsItems(low):
      mixRun(result.checksum, run.left, run.right)
      inc result.runCount
      result.matchedRows += run.right - run.left
    return

  var pending = false
  var pendingLeft = 0'i64
  for position in 0'i64..<wm.n:
    if wm.valueInRangeAtUnchecked(position, low, high):
      if not pending:
        pending = true
        pendingLeft = position
    elif pending:
      mixRun(result.checksum, pendingLeft, position)
      inc result.runCount
      result.matchedRows += position - pendingLeft
      pending = false

  if pending:
    mixRun(result.checksum, pendingLeft, wm.n)
    inc result.runCount
    result.matchedRows += wm.n - pendingLeft

proc apiRangeRuns(wm: WaveletMatrix, low, high: uint64):
    tuple[checksum: uint64, runCount, matchedRows: int64] =
  for run in wm.matchingRangeRunsItems(low, high):
    mixRun(result.checksum, run.left, run.right)
    inc result.runCount
    result.matchedRows += run.right - run.left

proc csvEscape(value: string): string =
  "\"" & value.replace("\"", "\"\"") & "\""

proc main() =
  var rows = DefaultRows
  var repeats = DefaultRepeats
  var outputPath = ""
  for kind, key, value in getopt():
    if kind in {cmdLongOption, cmdShortOption}:
      case key
      of "rows": rows = parseInt(value)
      of "repeats": repeats = parseInt(value)
      of "output": outputPath = value
      else: raise newException(ValueError, "unknown option: " & key)
  if rows <= 0 or repeats < 5:
    raise newException(ValueError,
      "rows must be positive and repeats must be at least 5")

  var lines = @[
    "backend,shape,bit_width,rows,selectivity,method,strategy,repeat," &
    "latency_ns,run_count,matched_rows"]
  var summaries: seq[Summary]

  for shape in [dsRandom, dsClustered, dsPeriodic]:
    for bitWidth in BitWidths:
      let values = makeValues(rows, bitWidth, shape)
      let wm = genWaveletMatrix(values, bitWidth)

      for selectivity in Selectivities:
        let (low, high) = queryRange(bitWidth, selectivity)
        let expected = baselineAccessRuns(wm, low, high)
        let positionObserved = positionPredicateRuns(wm, low, high)
        let adaptiveObserved = apiRangeRuns(wm, low, high)
        doAssert positionObserved == expected
        doAssert adaptiveObserved == expected
        let adaptiveStrategy =
          if low == 0 and high >= domainHigh(bitWidth):
            "full_domain"
          elif low == high:
            "equality"
          else:
            when defined(nbvsRangeRunBenchmark):
              if wm.rangeRunAdaptiveUsesNativeBenchmark(
                  low, high, 0, wm.n):
                "native"
              else:
                "position"
            else:
              "unobserved"

        # 3 methodを1回ずつwarmupした後、repeatごとに開始methodをrotateします。
        sink = sink xor baselineAccessRuns(wm, low, high).checksum
        sink = sink xor positionPredicateRuns(wm, low, high).checksum
        sink = sink xor apiRangeRuns(wm, low, high).checksum

        var baselineSamples = newSeqOfCap[float](repeats)
        var positionSamples = newSeqOfCap[float](repeats)
        var adaptiveSamples = newSeqOfCap[float](repeats)

        template recordBaseline() =
          block:
            let started = getMonoTime()
            sink = sink xor baselineAccessRuns(wm, low, high).checksum
            baselineSamples.add float(
              (getMonoTime() - started).inNanoseconds)

        template recordPosition() =
          block:
            let started = getMonoTime()
            sink = sink xor positionPredicateRuns(wm, low, high).checksum
            positionSamples.add float(
              (getMonoTime() - started).inNanoseconds)

        template recordAdaptive() =
          block:
            let started = getMonoTime()
            sink = sink xor apiRangeRuns(wm, low, high).checksum
            adaptiveSamples.add float(
              (getMonoTime() - started).inNanoseconds)

        for repeatIndex in 0..<repeats:
          case repeatIndex mod 3
          of 0:
            recordBaseline()
            recordPosition()
            recordAdaptive()
          of 1:
            recordPosition()
            recordAdaptive()
            recordBaseline()
          else:
            recordAdaptive()
            recordBaseline()
            recordPosition()

        let baselineP50 = percentile(baselineSamples, 0.50)
        let positionP50 = percentile(positionSamples, 0.50)
        let adaptiveP50 = percentile(adaptiveSamples, 0.50)

        for repeat, latency in baselineSamples:
          lines.add &"{Backend},{shape.shapeName},{bitWidth},{rows},{selectivity}," &
            &"access_compare,n/a,{repeat + 1},{latency:.0f}," &
            &"{expected.runCount},{expected.matchedRows}"
        for repeat, latency in positionSamples:
          lines.add &"{Backend},{shape.shapeName},{bitWidth},{rows},{selectivity}," &
            &"position_predicate_scan,position,{repeat + 1},{latency:.0f}," &
            &"{positionObserved.runCount},{positionObserved.matchedRows}"
        for repeat, latency in adaptiveSamples:
          lines.add &"{Backend},{shape.shapeName},{bitWidth},{rows},{selectivity}," &
            &"matching_range_runs_adaptive,{adaptiveStrategy},{repeat + 1}," &
            &"{latency:.0f},{adaptiveObserved.runCount}," &
            &"{adaptiveObserved.matchedRows}"

        summaries.add Summary(
          shape: shape,
          bitWidth: bitWidth,
          selectivity: selectivity,
          methodName: "position_predicate_scan",
          strategyName: "position",
          p50: positionP50,
          p95: percentile(positionSamples, 0.95),
          p99: percentile(positionSamples, 0.99),
          speedupVsAccess: baselineP50 / positionP50,
          speedupVsPosition: 1.0,
          runCount: positionObserved.runCount,
          matchedRows: positionObserved.matchedRows)
        summaries.add Summary(
          shape: shape,
          bitWidth: bitWidth,
          selectivity: selectivity,
          methodName: "matching_range_runs_adaptive",
          strategyName: adaptiveStrategy,
          p50: adaptiveP50,
          p95: percentile(adaptiveSamples, 0.95),
          p99: percentile(adaptiveSamples, 0.99),
          speedupVsAccess: baselineP50 / adaptiveP50,
          speedupVsPosition: positionP50 / adaptiveP50,
          runCount: adaptiveObserved.runCount,
          matchedRows: adaptiveObserved.matchedRows)

  let output = lines.join("\n") & "\n"
  if outputPath.len > 0:
    let parent = parentDir(outputPath)
    if parent.len > 0:
      createDir(parent)
    writeFile(outputPath, output)
  else:
    stdout.write(output)

  stderr.writeLine("## Summary")
  stderr.writeLine(
    "backend,shape,bits,selectivity,method,strategy,p50_ns,p95_ns,p99_ns," &
    "speedup_vs_access,speedup_vs_position,runs,matched_rows")
  for item in summaries:
    stderr.writeLine(&"{Backend},{item.shape.shapeName},{item.bitWidth}," &
      &"{item.selectivity},{item.methodName},{item.strategyName}," &
      &"{item.p50:.0f},{item.p95:.0f}," &
      &"{item.p99:.0f},{item.speedupVsAccess:.4f}," &
      &"{item.speedupVsPosition:.4f},{item.runCount},{item.matchedRows}")
  stderr.writeLine("sink=", sink)
  stderr.writeLine("backend=", Backend)
  stderr.writeLine("build_flags=", csvEscape(BuildFlags))
  stderr.writeLine("nim_version=", NimVersion)
  stderr.writeLine("host=", hostOS, "/", hostCPU)

when isMainModule:
  main()
