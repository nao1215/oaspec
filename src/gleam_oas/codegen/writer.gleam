import gleam/io
import gleam/list
import gleam/result
import gleam_oas/codegen/client
import gleam_oas/codegen/context.{type Context, type GeneratedFile}
import gleam_oas/codegen/decoders
import gleam_oas/codegen/middleware
import gleam_oas/codegen/server
import gleam_oas/codegen/types
import gleam_oas/config.{Both, Client, Server}
import simplifile

/// Errors that can occur during file writing.
pub type WriteError {
  DirectoryCreateError(path: String, detail: String)
  FileWriteError(path: String, detail: String)
}

/// Generate and write all files based on configuration.
pub fn generate_all(ctx: Context) -> Result(List(String), WriteError) {
  let shared_files = generate_shared(ctx)
  let server_files = case ctx.config.mode {
    Server | Both -> server.generate(ctx)
    Client -> []
  }
  let client_files = case ctx.config.mode {
    Client | Both -> client.generate(ctx)
    Server -> []
  }

  let server_path = ctx.config.output_server
  let client_path = ctx.config.output_client

  // Write shared files to both directories as needed
  let written_files = []

  use written_files <- result.try(case ctx.config.mode {
    Server | Both -> {
      use _ <- result.try(ensure_directory(server_path))
      write_files(shared_files, server_path, written_files)
      |> result.try(fn(w) { write_files(server_files, server_path, w) })
    }
    Client -> Ok(written_files)
  })

  use written_files <- result.try(case ctx.config.mode {
    Client | Both -> {
      use _ <- result.try(ensure_directory(client_path))
      write_files(shared_files, client_path, written_files)
      |> result.try(fn(w) { write_files(client_files, client_path, w) })
    }
    Server -> Ok(written_files)
  })

  Ok(written_files)
}

/// Generate shared files (types, decoders, encoders, middleware).
fn generate_shared(ctx: Context) -> List(GeneratedFile) {
  let type_files = types.generate(ctx)
  let decoder_files = decoders.generate(ctx)
  let middleware_files = middleware.generate(ctx)

  list.flatten([type_files, decoder_files, middleware_files])
}

/// Ensure a directory exists, creating it if necessary.
fn ensure_directory(path: String) -> Result(Nil, WriteError) {
  simplifile.create_directory_all(path)
  |> result.map_error(fn(_) {
    DirectoryCreateError(path:, detail: "Failed to create directory")
  })
}

/// Write a list of generated files to a directory.
fn write_files(
  files: List(GeneratedFile),
  base_path: String,
  written: List(String),
) -> Result(List(String), WriteError) {
  list.try_fold(files, written, fn(acc, file) {
    let full_path = base_path <> "/" <> file.path
    use _ <- result.try(
      simplifile.write(full_path, file.content)
      |> result.map_error(fn(_) {
        FileWriteError(path: full_path, detail: "Failed to write file")
      }),
    )
    io.println("  Generated: " <> full_path)
    Ok([full_path, ..acc])
  })
}

/// Convert a write error to a human-readable string.
pub fn error_to_string(error: WriteError) -> String {
  case error {
    DirectoryCreateError(path:, detail:) ->
      "Failed to create directory " <> path <> ": " <> detail
    FileWriteError(path:, detail:) ->
      "Failed to write file " <> path <> ": " <> detail
  }
}
