## degree別にlinear、binary、256-bit bitmap child探索を比較します。

import std/[bitops, monotimes, strformat, times]

const Iterations = 1_000_000
var sink {.volatile.}: int

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

func linearFind(values: openArray[byte], target: byte): int =
  for index, value in values:
    if value == target:
      return index
  -1

func binaryFind(values: openArray[byte], target: byte): int =
  var left = 0
  var right = values.len
  while left < right:
    let middle = (left + right) shr 1
    if values[middle] < target: left = middle + 1 else: right = middle
  if left < values.len and values[left] == target: left else: -1

func bitmapFind(bitmap: array[4, uint64], target: byte): int =
  let targetWord = int(target) shr 6
  let mask = 1'u64 shl (int(target) and 63)
  if (bitmap[targetWord] and mask) == 0:
    return -1
  for word in 0..<targetWord:
    result += countSetBits(bitmap[word])
  result += countSetBits(bitmap[targetWord] and (mask - 1))

proc run(degree: int) =
  var values = newSeq[byte](degree)
  var bitmap: array[4, uint64]
  for index in 0..<degree:
    values[index] = byte(index * 256 div degree)
    bitmap[int(values[index]) shr 6] = bitmap[int(values[index]) shr 6] or
      (1'u64 shl (int(values[index]) and 63))
  var started = getMonoTime()
  for query in 0..<Iterations:
    sink = sink xor linearFind(values, byte(query and 255))
  let linearNs = elapsedNs(started)
  started = getMonoTime()
  for query in 0..<Iterations:
    sink = sink xor binaryFind(values, byte(query and 255))
  let binaryNs = elapsedNs(started)
  started = getMonoTime()
  for query in 0..<Iterations:
    sink = sink xor bitmapFind(bitmap, byte(query and 255))
  let bitmapNs = elapsedNs(started)
  echo &"{degree},{float(linearNs) / Iterations.float:.2f}," &
    &"{float(binaryNs) / Iterations.float:.2f}," &
    &"{float(bitmapNs) / Iterations.float:.2f},32"

when isMainModule:
  echo "degree,linear_ns,binary_ns,bitmap_ns,bitmap_bytes"
  for degree in [1, 2, 4, 8, 16, 17, 32, 64, 128, 256]:
    run(degree)
  echo "sink=", sink
