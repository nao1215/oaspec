import gleam_oas/codegen/context.{
  type Context, type GeneratedFile, GeneratedFile,
}
import gleam_oas/util/string_extra as se

/// Generate middleware module.
pub fn generate(ctx: Context) -> List(GeneratedFile) {
  let content = generate_middleware(ctx)
  [GeneratedFile(path: "middleware.gleam", content: content)]
}

/// Generate the middleware types and utilities.
fn generate_middleware(ctx: Context) -> String {
  let sb =
    se.file_header(context.version)
    |> se.imports([])

  let sb =
    sb
    |> se.doc_comment(
      "A handler is a function that takes a request and returns a result.",
    )
    |> se.line("pub type Handler(req, res) =")
    |> se.indent(1, "fn(req) -> Result(res, MiddlewareError)")
    |> se.blank_line()

  let sb =
    sb
    |> se.doc_comment(
      "A middleware wraps a handler to add cross-cutting concerns.",
    )
    |> se.doc_comment(
      "Middleware is composable: each middleware takes a handler and returns",
    )
    |> se.doc_comment("a new handler with added behavior.")
    |> se.line("pub type Middleware(req, res) =")
    |> se.indent(1, "fn(Handler(req, res)) -> Handler(req, res)")
    |> se.blank_line()

  // Error type
  let sb =
    sb
    |> se.doc_comment("Errors that middleware can produce.")
    |> se.line("pub type MiddlewareError {")
    |> se.indent(1, "Unauthorized(detail: String)")
    |> se.indent(1, "Forbidden(detail: String)")
    |> se.indent(1, "BadRequest(detail: String)")
    |> se.indent(1, "InternalError(detail: String)")
    |> se.indent(1, "CustomError(code: Int, detail: String)")
    |> se.line("}")
    |> se.blank_line()

  // Identity middleware
  let sb =
    sb
    |> se.doc_comment(
      "Identity middleware that passes the request through unchanged.",
    )
    |> se.line("pub fn identity() -> Middleware(req, res) {")
    |> se.indent(1, "fn(handler: Handler(req, res)) -> Handler(req, res) {")
    |> se.indent(2, "handler")
    |> se.indent(1, "}")
    |> se.line("}")
    |> se.blank_line()

  // Compose middleware
  let sb =
    sb
    |> se.doc_comment("Compose two middleware functions.")
    |> se.doc_comment("The first middleware is applied first (outermost),")
    |> se.doc_comment("the second middleware is applied second (innermost).")
    |> se.line("pub fn compose(")
    |> se.indent(1, "first: Middleware(req, res),")
    |> se.indent(1, "second: Middleware(req, res),")
    |> se.line(") -> Middleware(req, res) {")
    |> se.indent(1, "fn(handler: Handler(req, res)) -> Handler(req, res) {")
    |> se.indent(2, "first(second(handler))")
    |> se.indent(1, "}")
    |> se.line("}")
    |> se.blank_line()

  // Apply middleware chain
  let sb =
    sb
    |> se.doc_comment("Apply a list of middleware to a handler.")
    |> se.doc_comment(
      "Middleware is applied in order: first in list = outermost.",
    )
    |> se.line("pub fn apply(")
    |> se.indent(1, "middlewares: List(Middleware(req, res)),")
    |> se.indent(1, "handler: Handler(req, res),")
    |> se.line(") -> Handler(req, res) {")
    |> se.indent(1, "case middlewares {")
    |> se.indent(2, "[] -> handler")
    |> se.indent(2, "[mw, ..rest] -> mw(apply(rest, handler))")
    |> se.indent(1, "}")
    |> se.line("}")
    |> se.blank_line()

  // Logging middleware example
  let sb =
    sb
    |> se.doc_comment("Example: A logging middleware stub.")
    |> se.doc_comment("Replace the body with your logging implementation.")
    |> se.line("pub fn logging() -> Middleware(req, res) {")
    |> se.indent(1, "fn(handler: Handler(req, res)) -> Handler(req, res) {")
    |> se.indent(2, "fn(request: req) -> Result(res, MiddlewareError) {")
    |> se.indent(3, "// TODO: Add logging before/after the handler call")
    |> se.indent(3, "handler(request)")
    |> se.indent(2, "}")
    |> se.indent(1, "}")
    |> se.line("}")
    |> se.blank_line()

  // Retry middleware for client
  let sb =
    sb
    |> se.doc_comment("Retry middleware for client operations.")
    |> se.doc_comment("Retries the handler up to max_retries times on failure.")
    |> se.line("pub fn retry(max_retries: Int) -> Middleware(req, res) {")
    |> se.indent(1, "fn(handler: Handler(req, res)) -> Handler(req, res) {")
    |> se.indent(2, "fn(request: req) -> Result(res, MiddlewareError) {")
    |> se.indent(3, "do_retry(handler, request, max_retries, 0)")
    |> se.indent(2, "}")
    |> se.indent(1, "}")
    |> se.line("}")
    |> se.blank_line()

  let sb =
    sb
    |> se.line("fn do_retry(")
    |> se.indent(1, "handler: Handler(req, res),")
    |> se.indent(1, "request: req,")
    |> se.indent(1, "max_retries: Int,")
    |> se.indent(1, "attempt: Int,")
    |> se.line(") -> Result(res, MiddlewareError) {")
    |> se.indent(1, "case handler(request) {")
    |> se.indent(2, "Ok(response) -> Ok(response)")
    |> se.indent(2, "Error(err) -> {")
    |> se.indent(3, "case attempt < max_retries {")
    |> se.indent(
      4,
      "True -> do_retry(handler, request, max_retries, attempt + 1)",
    )
    |> se.indent(4, "False -> Error(err)")
    |> se.indent(3, "}")
    |> se.indent(2, "}")
    |> se.indent(1, "}")
    |> se.line("}")
    |> se.blank_line()

  let _ = ctx
  se.to_string(sb)
}
