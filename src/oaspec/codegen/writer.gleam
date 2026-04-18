import gleam/list
import gleam/result
import oaspec/codegen/context.{type Context, type GeneratedFile}
import oaspec/config.{Both, Client, Server}
import oaspec/generate as gen
import simplifile

/// Errors that can occur during file writing.
pub type WriteError {
  DirectoryCreateError(path: String, detail: String)
  FileWriteError(path: String, detail: String)
}

/// Generate and write all files based on configuration.
pub fn generate_all(
  ctx: Context,
  on_write: fn(String) -> Nil,
) -> Result(List(String), WriteError) {
  let files = gen.generate_all_files(ctx)
  write_all(files, context.config(ctx), on_write)
}

/// Write pre-generated files to disk based on configuration.
pub fn write_all(
  files: List(GeneratedFile),
  cfg: config.Config,
  on_write: fn(String) -> Nil,
) -> Result(List(String), WriteError) {
  // Separate files by their target kind (ADT-based, not filename matching)
  let shared_files =
    list.filter(files, fn(f) { f.target == context.SharedTarget })
  let server_files =
    list.filter(files, fn(f) { f.target == context.ServerTarget })
  let client_files =
    list.filter(files, fn(f) { f.target == context.ClientTarget })

  let server_path = cfg.output_server
  let client_path = cfg.output_client
  let written_files = []

  use written_files <- result.try(case cfg.mode {
    Server | Both -> {
      use _ <- result.try(ensure_directory(server_path))
      write_files(shared_files, server_path, written_files, on_write)
      |> result.try(fn(w) {
        write_files(server_files, server_path, w, on_write)
      })
    }
    Client -> Ok(written_files)
  })

  use written_files <- result.try(case cfg.mode {
    Client | Both -> {
      use _ <- result.try(ensure_directory(client_path))
      write_files(shared_files, client_path, written_files, on_write)
      |> result.try(fn(w) {
        write_files(client_files, client_path, w, on_write)
      })
    }
    Server -> Ok(written_files)
  })

  Ok(written_files)
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
  on_write: fn(String) -> Nil,
) -> Result(List(String), WriteError) {
  list.try_fold(files, written, fn(acc, file) {
    let full_path = base_path <> "/" <> file.path
    use _ <- result.try(
      simplifile.write(full_path, file.content)
      |> result.map_error(fn(_) {
        FileWriteError(path: full_path, detail: "Failed to write file")
      }),
    )
    on_write(full_path)
    Ok([full_path, ..acc])
  })
}

/// Resolve generated files to their full output paths and content.
/// Used by --check to compare against existing files without writing.
pub fn resolve_paths(
  files: List(GeneratedFile),
  cfg: config.Config,
) -> List(#(String, String)) {
  let shared_files =
    list.filter(files, fn(f) { f.target == context.SharedTarget })
  let server_files =
    list.filter(files, fn(f) { f.target == context.ServerTarget })
  let client_files =
    list.filter(files, fn(f) { f.target == context.ClientTarget })

  let server_path = cfg.output_server
  let client_path = cfg.output_client

  let server_entries = case cfg.mode {
    Server | Both ->
      list.map(list.append(shared_files, server_files), fn(f) {
        #(server_path <> "/" <> f.path, f.content)
      })
    Client -> []
  }

  let client_entries = case cfg.mode {
    Client | Both ->
      list.map(list.append(shared_files, client_files), fn(f) {
        #(client_path <> "/" <> f.path, f.content)
      })
    Server -> []
  }

  list.append(server_entries, client_entries)
}

/// Return the output directories that would be written to for the given config.
pub fn output_dirs(cfg: config.Config) -> List(String) {
  case cfg.mode {
    Server -> [cfg.output_server]
    Client -> [cfg.output_client]
    Both -> [cfg.output_server, cfg.output_client]
  }
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
