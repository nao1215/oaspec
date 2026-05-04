# js_smoke

A minimal Gleam project that depends on `oaspec` with
`target = "javascript"`. It imports a few public modules from oaspec
that are expected to stay target-neutral and verifies they both compile
and run on Node.

This is **not** an end-user example — it does not actually issue HTTP
calls. For an actual JavaScript client example using the first-party
fetch adapter, see
[`examples/petstore_client_fetch`](../petstore_client_fetch/). It exists so
that CI catches any regression that re-couples the public runtime
modules to BEAM-only code.

## Run locally

```bash
cd examples/js_smoke
gleam run
```

You should see `oaspec js_smoke: ok`.
