# 利用者は ``import nbvs/submodule`` と記述してこのモジュールを読み込みます。
# 実装する責務に応じて、ファイル名の変更やモジュールの追加を行います。

type
  Submodule* = object
    name*: string

proc initSubmodule*(): Submodule =
  ## デフォルト名を持つ ``Submodule`` を生成します。
  Submodule(name: "Anonymous")
