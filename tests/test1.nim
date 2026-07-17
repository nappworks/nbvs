# テストファイル名を `t` から始めると、`nimble test` の対象になります。

import unittest

import nbvs
test "can add":
  check add(5, 5) == 10
