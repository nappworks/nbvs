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

task testPortable, "Run all tests with the portable scalar backend":
  exec "nim c --nimcache:tests/.nimcache_all_portable -d:nbvsNoSimd -r tests/all.nim"

task docs, "Generate API documentation":
  exec "nim doc --project --outdir:docs/api src/nbvs.nim"
