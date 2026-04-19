import argv
import glint
import oaspec/cli

/// CLI entry point for the oaspec code generator.
pub fn main() -> Nil {
  cli.app()
  |> glint.run(argv.load().arguments)
}
