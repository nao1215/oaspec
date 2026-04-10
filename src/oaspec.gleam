import argv
import glint
import oaspec/cli

/// CLI entry point for the oaspec code generator.
pub fn main() {
  cli.app()
  |> glint.run(argv.load().arguments)
}
