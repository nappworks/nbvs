## Radix Trie builderのpeak RSSと完成容量を単一processで測定します。

import std/[monotimes, os, parseutils, strformat, strutils, times]
import nbvs

when defined(linux):
  import std/posix

proc elapsedMs(started: MonoTime): float =
  (getMonoTime() - started).inNanoseconds.float / 1e6

proc peakRssKiB(): int64 =
  when defined(linux):
    var usage: Rusage
    if getrusage(RUSAGE_SELF, addr usage) == 0:
      return int64(usage.ru_maxrss)
  -1

proc makeValues(count, averageLength: int): seq[string] =
  result = newSeq[string](count)
  for index in 0..<count:
    let identifier = toHex(index, 8)
    result[index] = "shared/catalog/"
    if result[index].len + identifier.len < averageLength:
      result[index].add repeat('x',
        averageLength - result[index].len - identifier.len)
    result[index].add identifier

when isMainModule:
  var count = 1_000_000
  var averageLength = 16
  if paramCount() >= 1:
    discard parseInt(paramStr(1), count)
  if paramCount() >= 2:
    discard parseInt(paramStr(2), averageLength)
  if count <= 0 or averageLength <= 0:
    raise newException(ValueError, "count and averageLength must be positive")
  let values = makeValues(count, averageLength)
  var inputBytes = 0'i64
  for value in values:
    inputBytes += int64(value.len)
  let started = getMonoTime()
  let trie = genSuccinctRadixTrie(values)
  let buildMs = elapsedMs(started)
  echo "count,average_length,input_bytes,build_ms,peak_rss_kib,trie_bytes,nodes"
  echo &"{count},{averageLength},{inputBytes},{buildMs:.3f},{peakRssKiB()}," &
    &"{trie.memoryUsage.totalBytes},{trie.stats.nodeCount}"
