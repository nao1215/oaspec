import argv
import glint
import oas_gleam/cli

pub fn main() {
  cli.app()
  |> glint.run(argv.load().arguments)
}
