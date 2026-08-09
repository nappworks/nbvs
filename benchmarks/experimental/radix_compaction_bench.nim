## Succinct Radix Trieのmetadata圧縮候補を比較します。

import std/[bitops, monotimes, os, parseutils, strformat, strutils, times]
import nbvs

const QueryIterations = 1_000_000

var sink {.volatile.}: uint64

proc elapsedNs(started: MonoTime): int64 =
  (getMonoTime() - started).inNanoseconds

func requiredBitWidth(maximum: uint64): int =
  if maximum == 0: 0 else: 64 - countLeadingZeroBits(maximum)

func packedBytes(values: PackedArray): int64 =
  int64(values.data.len) * 8

func sbvBytes(values: SuccinctBitVector): int64 =
  int64(values.data.len + values.selectStorage.len) * 8 +
    int64(values.blockPairPrefix.len + values.wordPairPrefix.len) * 4

func parentBytes(values: BlockPackedParents): int64 =
  int64(values.bitWidths.len) + int64(values.wordOffsets.len) * 4 +
    int64(values.data.len) * 8

proc makeValues(count, averageLength: int): seq[string] =
  for index in 0..<count:
    let identifier = $index
    result.add "v" & repeat('a', max(0,
      averageLength - identifier.len - 1)) & identifier

proc run(count, averageLength: int) =
  let trie = genSuccinctRadixTrie(makeValues(count, averageLength))
  let nodeCount = trie.edgeFirstBytes.len
  let internalCount = int(trie.internalBits.totalOnes)

  var internalIndex = genPackedArray(nodeCount,
    requiredBitWidth(uint64(internalCount)))
  var internalOrdinal = 0
  for node in 0..<nodeCount:
    if trie.internalBits.access(int64(node)):
      internalIndex[node] = uint64(internalOrdinal + 1)
      inc internalOrdinal

  var firstChildren = newSeq[uint64](internalCount)
  for index in 0..<internalCount:
    firstChildren[index] = trie.internalFirstChild.getUnchecked(index)
  let firstChildEf = genEliasFano(firstChildren,
    uint64(trie.childNodes.len + 1))

  var subtreeEnds = genPackedArray(nodeCount,
    requiredBitWidth(uint64(nodeCount)))
  for node in countdown(nodeCount - 1, 0):
    var subtreeEnd = node + 1
    if trie.childCountAt(node) > 0:
      let first = trie.firstChildOffset(node)
      let count = trie.childCountAt(node)
      let lastChild = int(trie.childNodes.getUnchecked(first + count - 1))
      subtreeEnd = int(subtreeEnds.getUnchecked(lastChild))
    subtreeEnds[node] = uint64(subtreeEnd)

  var directParents = genPackedArray(nodeCount,
    requiredBitWidth(uint64(max(0, nodeCount - 1))))
  for node in 0..<nodeCount:
    directParents[node] = uint64(trie.parentAt(node))

  var idToTerminalOrdinal = genPackedArray(count,
    requiredBitWidth(uint64(max(0, count - 1))))
  for id in 0..<count:
    let node = int(trie.idToTerminal.getUnchecked(id))
    idToTerminalOrdinal[id] = uint64(trie.terminalBits.rank1(int64(node)))

  var started = getMonoTime()
  for query in 0..<QueryIterations:
    let node = query mod nodeCount
    if trie.internalBits.access(int64(node)):
      sink = sink xor uint64(trie.internalBits.rank1Unchecked(int64(node)))
  let internalRankNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    sink = sink xor internalIndex.getUnchecked(query mod nodeCount)
  let internalDirectNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    sink = sink xor trie.internalFirstChild.getUnchecked(
        query mod internalCount)
  let firstChildPackedNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    sink = sink xor firstChildEf[query mod internalCount]
  let firstChildEfNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    sink = sink xor directParents.getUnchecked(query mod nodeCount)
  let directParentNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    sink = sink xor uint64(trie.parentAt(query mod nodeCount))
  let deltaParentNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    sink = sink xor trie.idToTerminal.getUnchecked(query mod count)
  let directTerminalNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    let ordinal = idToTerminalOrdinal.getUnchecked(query mod count)
    sink = sink xor uint64(trie.terminalBits.select1(int64(ordinal)))
  let ordinalTerminalNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    let node = query mod nodeCount
    let count = trie.childCountAt(node)
    if count > 0:
      let first = trie.firstChildOffset(node)
      for offset in 0..<count:
        sink = sink xor trie.childNodes.getUnchecked(first + offset)
  let childNodesNs = elapsedNs(started)

  started = getMonoTime()
  for query in 0..<QueryIterations:
    let node = query mod nodeCount
    let count = trie.childCountAt(node)
    var child = node + 1
    for _ in 0..<count:
      sink = sink xor uint64(child)
      child = int(subtreeEnds.getUnchecked(child))
  let subtreeChainNs = elapsedNs(started)

  echo "candidate,baseline_bytes,candidate_bytes,baseline_ns,candidate_ns"
  echo &"internal_lookup,{sbvBytes(trie.internalBits)}," &
    &"{packedBytes(internalIndex)}," &
    &"{float(internalRankNs) / QueryIterations.float:.2f}," &
    &"{float(internalDirectNs) / QueryIterations.float:.2f}"
  echo &"first_child,{packedBytes(trie.internalFirstChild)}," &
    &"{packedBytes(firstChildEf.lows) + sbvBytes(firstChildEf.highBits)}," &
    &"{float(firstChildPackedNs) / QueryIterations.float:.2f}," &
    &"{float(firstChildEfNs) / QueryIterations.float:.2f}"
  echo &"child_navigation,{packedBytes(trie.childNodes)}," &
    &"{packedBytes(subtreeEnds)}," &
    &"{float(childNodesNs) / QueryIterations.float:.2f}," &
    &"{float(subtreeChainNs) / QueryIterations.float:.2f}"
  echo &"parent,{packedBytes(directParents)},{parentBytes(trie.parents)}," &
    &"{float(directParentNs) / QueryIterations.float:.2f}," &
    &"{float(deltaParentNs) / QueryIterations.float:.2f}"
  echo &"id_to_terminal,{packedBytes(trie.idToTerminal)}," &
    &"{packedBytes(idToTerminalOrdinal)}," &
    &"{float(directTerminalNs) / QueryIterations.float:.2f}," &
    &"{float(ordinalTerminalNs) / QueryIterations.float:.2f}"

when isMainModule:
  var count = 100_000
  var averageLength = 16
  if paramCount() >= 1:
    discard parseInt(paramStr(1), count)
  if paramCount() >= 2:
    discard parseInt(paramStr(2), averageLength)
  if count <= 0 or averageLength <= 0:
    raise newException(ValueError, "count and averageLength must be positive")
  run(count, averageLength)
  stderr.writeLine("sink=", sink)
