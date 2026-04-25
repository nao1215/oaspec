import argv
import gleam/io
import glint
import oaspec/cli
import oaspec/codegen/context

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

/// CLI entry point for the oaspec code generator.
///
/// Routes diagnostic output to stderr while keeping requested output (such as
/// `--help` text) on stdout, following POSIX/CLIG conventions.
pub fn main() -> Nil {
  let arguments = argv.load().arguments
  case arguments {
    ["--version", ..] -> io.println("oaspec v" <> context.version)
    _ -> run_glint(arguments)
  }
}

fn run_glint(arguments: List(String)) -> Nil {
  case glint.execute(cli.app(), arguments) {
    Error(message) -> {
      io.println_error(message)
      halt(1)
    }
    Ok(glint.Help(text)) -> io.println(text)
    Ok(glint.Out(_)) -> Nil
  }
}
