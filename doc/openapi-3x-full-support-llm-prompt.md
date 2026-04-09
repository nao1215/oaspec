# OpenAPI 3.x Full Support Implementation Prompt for LLM

以下は、このリポジトリ `/home/nao/ghq/github.com/nao1215/oaspec` に対して実装作業を行う LLM への指示である。  
あなたの役割は「レビュー担当」ではなく「実装担当」であり、**分析で止まらず、実装・テスト・ドキュメント更新まで完了させること**。  
このプロンプトでは OpenAPI 3.x フルサポートに向けた構造的なリファクタと、既知の生成バグ修正を要求する。

## 最重要ルール

1. 途中で止まらないこと。調査だけで終えてはならない。
2. 「README の表現を弱めて終わり」は禁止。実装を進めること。
3. 「サポートしないことにした」と仕様を後退させてタスクを終えないこと。
4. OpenAPI 3.x フルサポートが難しい場合でも、構造的に前進するリファクタを必ず行うこと。
5. 変更後は必ずテストを追加し、既存テストと新規テストを通すこと。
6. 自分で見つけた問題を TODO コメントだけ残して放置しないこと。
7. 互換性は気にしなくてよい。より正しい構造に作り直してよい。

## ゴール

このリポジトリを、OpenAPI 3.0.x および 3.1 を正しく扱える実装へ段階的に改善すること。  
少なくとも以下を満たすこと:

- AST が lossy でないこと
- unsupported feature が「無視」ではなく「保持された上で判定」されること
- client/server codegen の判断が stringly typed ではなく、型で管理されること
- 既知の不正コード生成バグが解消されること
- OpenAPI 3.1 / JSON Schema 2020-12 対応に向けた拡張可能な構造になること

## 現在の問題認識

以下は既知の問題であり、優先的に解消すべきである。

### 1. AST が lossy

現状の `src/oaspec/openapi/spec.gleam` と `src/oaspec/openapi/schema.gleam` は、OpenAPI 3.x の重要要素を保持していない。

例:

- `webhooks`
- `jsonSchemaDialect`
- `tags`
- `externalDocs`
- `info.summary`, `termsOfService`, `contact`, `license`
- server variables
- operation/path-level `servers`
- `Parameter.content`
- `Parameter.example` / `examples`
- `MediaType.encoding`
- `MediaType.example` / `examples`
- `Response.headers`
- `Response.links`
- components の `headers`, `examples`, `links`, `callbacks`
- JSON Schema 2020-12 の多くのキーワード

### 2. SchemaObject の表現力不足

現状の schema AST は以下を十分に扱えていない:

- `not`
- `const`
- non-string enum
- `default`
- `readOnly`, `writeOnly`
- `title`
- `exclusiveMinimum`, `exclusiveMaximum`
- `multipleOf`
- `minProperties`, `maxProperties`
- `uniqueItems`
- `xml`
- `$defs`
- `prefixItems`
- `contains`
- `if` / `then` / `else`
- `dependentSchemas`
- `unevaluatedProperties`
- `$dynamicRef`
- `contentMediaType`

### 3. server generator が scaffold のまま

現状の server 側生成コードは TODO stub に留まっており、request decode / typed dispatch / response encode / security handling を実装していない。  
これは「フルサポート」とは呼べない。

### 4. client generator に既知バグがある

少なくとも以下の不正コード生成を修正すること。

- optional `deepObject` + array leaf で `uri.percent_encode(v)` に `List(String)` を渡す
- `application/x-www-form-urlencoded` の `$ref` array property で `uri.percent_encode(body.tags)` を生成する
- `$ref` array query parameter で `list.fold` を使うのに `gleam/list` import が落ちる

## 参照すべき既存資料

リポジトリ内に参考 OSS がすでにある。外部 clone は不要。

- `doc/reference/openapi-generator`
- `doc/reference/kiota`
- `doc/reference/oapi-codegen`
- `doc/reference/libopenapi`
- `doc/reference/oss-architecture-analysis.md`
- `doc/reference/openapi-3x-review.md`

特に参考にすべき設計方針:

- lossless raw AST
- normalized/resolved AST
- capability check
- language-agnostic IR
- renderer 分離

## 実装方針

以下の順で進めること。途中で勝手に順序を崩さないこと。

### Phase 1: AST の再設計

目的:

- parse 時点で情報を落とさない構造にする

やること:

1. `openapi/raw` 相当の層を導入する
2. OpenAPI Object / Components / Operation / Parameter / MediaType / Response / Schema を lossless に表現する
3. 既存 `spec.gleam` / `schema.gleam` は必要なら作り直してよい
4. free-form string で持っているものは ADT 化を優先する

例:

- parameter style
- parameter in
- security scheme in
- content type family
- schema keyword classification

### Phase 2: normalize / resolve / capability check の分離

目的:

- parse できることと codegen できることを分離する

やること:

1. raw AST から normalized AST へ変換する
2. `$ref` 解決を専用段階に分離する
3. circular ref の扱いを明確化する
4. unsupported feature を flat string list ではなく構造化された capability error にする

最低限、以下の観点を分けること:

- parse 可否
- normalize 可否
- client 生成可否
- server 生成可否

### Phase 3: IR 主導の codegen へ寄せる

目的:

- 文字列連結の分岐重複を減らす

やること:

1. `ir.gleam` と `ir_render.gleam` を本当に使う
2. `types`, `decoders`, `client`, `server` の生成ロジックを IR ベースへ寄せる
3. import 推論、型マッピング、serialization を単一点管理にする

### Phase 4: 既知の生成バグ修正

以下を必ずテスト付きで直すこと:

1. optional `deepObject` + array leaf
2. form-urlencoded の `$ref` array property
3. `$ref` array parameter の import 判定

### Phase 5: OpenAPI 3.x 機能の実装拡張

少なくとも以下は AST で保持し、可能なものは生成に使い、未対応でも capability error として明示すること:

- `webhooks`
- top-level / path-level / operation-level `servers`
- server variables
- `Parameter.content`
- `MediaType.encoding`
- `Response.headers`
- `Response.links`
- `externalDocs`
- OpenAPI 3.1 `jsonSchemaDialect`
- JSON Schema 2020-12 keywords

## server generator の扱い

server 側は逃げずに改善すること。

最低限必要:

- request path/query/header/cookie/body の typed decode
- handler に typed request を渡す
- typed response を HTTP response へ encode する
- status code / content type を適切に選ぶ
- security の入力点を明示する

もしフレームワーク非依存を維持するなら、transport adapter を分けること。  
stub のまま残すのは禁止。

## README / ドキュメント更新ルール

実装後は必ず以下を更新すること。

- `README.md`
- 必要なら `doc/reference/openapi-3.1-notes.md`
- 必要なら追加の設計メモ

README の supported / not supported は、**実装に合わせて正確に更新**すること。  
過大表現も過小表現も禁止。

## テスト要件

以下を満たすまで完了扱いにしないこと。

1. 既存 unit test を通す
2. 既存 integration test を通す
3. 新規追加したケースの test を通す
4. 壊れていた生成ケースを regression test 化する

最低限追加すべき回帰テスト:

- optional `deepObject` + array leaf
- form-urlencoded + `$ref` array property
- `$ref` array parameter import
- lossless parse した新規フィールドが AST で保持されるテスト
- unsupported ではなく capability error として出るテスト

## 完了条件

以下をすべて満たしたら完了:

1. lossy AST の主要問題が解消されている
2. 既知の生成バグ 3 件が修正されている
3. codegen の中核ロジックが以前より IR / typed dispatch に寄っている
4. OpenAPI 3.x で未対応のものが silent ignore ではなく明示的に扱われる
5. server generator が scaffold 以上になっている
6. README が実装状況と一致している
7. テストが全部通っている

## 途中報告のルール

作業中は以下を守ること:

- 何を直したかを短く報告する
- 問題を見つけたら、その場で修正方針を出して進める
- 「要検討」で止めない
- 実装困難な箇所は理由と代替案を即提示し、その代替案を実装する

## 禁止事項

- README だけ更新して終える
- TODO コメントだけ追加して終える
- unsupported を増やして見かけ上解決したことにする
- テストを書かずに修正したことにする
- 既知の 3 バグを放置する
- server generator を放置したまま「full support に近い」と主張する

## 実行開始時の宣言

作業開始時は次の方針で着手すること:

1. AST を lossless にするための差分を決める
2. normalize / resolve / capability check の分離を始める
3. 既知の codegen バグ 3 件を回帰テスト化する
4. 実装を進めながら README を追随更新する

## 最終出力フォーマット

作業終了時は以下を報告すること:

1. 何を実装したか
2. どの OpenAPI 3.x 機能が新たに扱えるようになったか
3. まだ未完了の点があるなら何が残っているか
4. 追加・更新したテスト
5. 実行したコマンドと結果

このタスクは「提案」ではなく「実装」である。  
必ずコードを書き、テストを通し、ドキュメントを更新して完了させよ。
