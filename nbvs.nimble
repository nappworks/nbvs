# Package

version       = "0.1.0"
author        = "nao.n"
description   = "Bit vector and succinct data structures for Nim"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 2.2.10"

task test, "Run all tests":
  exec "nim c --nimcache:tests/.nimcache_all -r tests/all.nim"

task testSimd, "Run all tests with the AVX2/BMI2 backend":
  exec "nim c --nimcache:tests/.nimcache_all_simd -d:nbvsSimd -r tests/all.nim"

task docs, "Generate API documentation":
  exec "nim doc --project --outdir:docs/api src/nbvs.nim"

task benchScalar, "Run scalar SuccinctBitVector benchmarks":
  exec "nim c --path:src -d:release --mm:arc -r benchmarks/bench_succinct_bit_vector.nim"

task benchSimd, "Run SIMD SuccinctBitVector benchmarks":
  exec "nim c --path:src -d:release --mm:arc -d:nbvsSimd -r benchmarks/bench_succinct_bit_vector.nim"

task benchMemory, "Report SuccinctBitVector logical memory":
  exec "nim c --path:src -d:release --mm:arc -r benchmarks/bench_memory.nim"

task benchFmDictionary, "Run FmDictionary benchmarks":
  exec "nim c --path:src -d:release --mm:arc -r benchmarks/fm_dictionary_bench.nim"

task benchRadixRepresentations, "Compare Radix Trie representations":
  exec "nim c --path:src -d:release --mm:arc -r benchmarks/experimental/radix_representation_bench.nim"

task benchFmDistributions, "Run FmDictionary distribution benchmarks":
  exec "nim c --path:src -d:release --mm:arc -r benchmarks/fm_dictionary_distributions.nim"

task benchRadixCompaction, "Compare Radix Trie metadata compaction":
  exec "nim c --path:src -d:release --mm:arc -r benchmarks/experimental/radix_compaction_bench.nim"
