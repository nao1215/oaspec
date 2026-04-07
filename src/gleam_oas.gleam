import argv
import gleam_oas/cli
import glint

pub fn main() {
  cli.app()
  |> glint.run(argv.load().arguments)
}
