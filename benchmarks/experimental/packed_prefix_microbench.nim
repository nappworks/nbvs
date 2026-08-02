import std/[monotimes, times]
import packed_prefix_entry

const iterations = 20_000_000
var sink {.volatile.}: uint64
var entry: RankPrefixEntry
entry.setAbsoluteRank((1'u64 shl 32) + 123)
for subblock in 1..7:
  entry.setRelativeRank(subblock, uint64(subblock * 511))

template measure(label: string, body: untyped) =
  let started = getMonoTime()
  for _ in 0..<iterations:
    sink = sink xor body
  let elapsed = (getMonoTime() - started).inNanoseconds
  echo label, ",", float(elapsed) / float(iterations)

echo "operation,ns_per_operation"
measure("absolute", entry.absoluteRank)
measure("relative0", entry.relativeRank(0))
measure("relative1", entry.relativeRank(1))
measure("relative2", entry.relativeRank(2))
measure("relative3", entry.relativeRank(3))
measure("relative7", entry.relativeRank(7))
stderr.writeLine("sink=", sink)
