import argv
import gleam/bool
import gleam/io
import gleam/list
import gleam/string
import glint
import oaspec/internal/cli
import oaspec/internal/codegen/context

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
    _ -> run_glint(normalize_argv(arguments))
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

/// Translate `--name value` into `--name=value` for the value-bearing long
/// options listed in `cli.value_flag_names`. glint 1.x only accepts the
/// `=`-joined form, so users who reach for the GNU `--name value` convention
/// (or who copy commands from `git`/`gh`/`cargo` muscle memory) hit
/// `invalid flag '<name>'`. The normalisation happens before glint sees the
/// argv so existing `--name=value` callers are unaffected, and so unknown
/// flags still surface from glint with their original error.
///
/// Other shapes are passed through untouched:
/// - `--name=value`: already canonical (the name has `=` in it, so no match)
/// - `--bool-flag`: not in the value-bearing list
/// - `--name -other`: a `-`-prefixed value is treated as the next flag, so
///   the original (broken) call is preserved and glint reports it as before
pub fn normalize_argv(arguments: List(String)) -> List(String) {
  do_normalize(arguments, [])
}

fn do_normalize(arguments: List(String), acc: List(String)) -> List(String) {
  case arguments {
    [] -> list.reverse(acc)
    [arg, value, ..rest] -> {
      use <- bool.lazy_guard(
        !{ is_value_long_flag(arg) && value_is_value(value) },
        fn() { do_normalize([value, ..rest], [arg, ..acc]) },
      )
      do_normalize(rest, [arg <> "=" <> value, ..acc])
    }
    [single, ..rest] -> do_normalize(rest, [single, ..acc])
  }
}

fn is_value_long_flag(arg: String) -> Bool {
  use <- bool.guard(!string.starts_with(arg, "--"), False)
  let name = string.drop_start(arg, 2)
  list.contains(cli.value_flag_names, name)
}

fn value_is_value(arg: String) -> Bool {
  !string.starts_with(arg, "-")
}
