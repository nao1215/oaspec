import gleam/list
import gleam/result
import oaspec/codegen/context.{type GeneratedFile}
import oaspec/config.{Both, Client, Server}
import simplifile

/// Errors that can occur during file writing.
pub type WriteError {
  DirectoryCreateError(path: String, detail: String)
  FileWriteError(path: String, detail: String)
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

  let server_path = config.output_server(cfg)
  let client_path = config.output_client(cfg)
  let written_files = []

  use written_files <- result.try(case config.mode(cfg) {
    Server | Both -> {
      use _ <- result.try(ensure_directory(server_path))
      write_files(shared_files, server_path, written_files, on_write)
      |> result.try(fn(w) {
        write_files(server_files, server_path, w, on_write)
      })
    }
    Client -> Ok(written_files)
  })

  use written_files <- result.try(case config.mode(cfg) {
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
  |> result.map_error(fn(err) {
    DirectoryCreateError(
      path:,
      detail: "Failed to create directory: " <> simplifile.describe_error(err),
    )
  })
}

/// Write a list of generated files to a directory.
///
/// Issue #247: files marked `SkipIfExists` (currently `handlers.gleam`)
/// are written only on first generation. If the file already exists on
/// disk, it is left alone — the user owns the contents and the
/// generator must not clobber their implementation.
fn write_files(
  files: List(GeneratedFile),
  base_path: String,
  written: List(String),
  on_write: fn(String) -> Nil,
) -> Result(List(String), WriteError) {
  list.try_fold(files, written, fn(acc, file) {
    let full_path = base_path <> "/" <> file.path
    case file.write_mode, simplifile.is_file(full_path) {
      context.SkipIfExists, Ok(True) -> {
        // File already exists; leave it alone. Don't notify on_write —
        // generation status messages should reflect what was actually
        // written.
        Ok(acc)
      }
      _, _ -> {
        use _ <- result.try(
          simplifile.write(full_path, file.content)
          |> result.map_error(fn(err) {
            FileWriteError(
              path: full_path,
              detail: "Failed to write file: " <> simplifile.describe_error(err),
            )
          }),
        )
        on_write(full_path)
        Ok([full_path, ..acc])
      }
    }
  })
}

/// Resolve generated files to their full output paths and content.
/// Used by --check to compare against existing files without writing.
///
/// Issue #247: `SkipIfExists` files (e.g. user-owned `handlers.gleam`)
/// are dropped from the result. `--check` is meant to flag drift in
/// generator-owned files; user-edited files are expected to differ
/// from the bootstrap stub and should not be reported as out-of-date.
pub fn resolve_paths(
  files: List(GeneratedFile),
  cfg: config.Config,
) -> List(#(String, String)) {
  let files = list.filter(files, fn(f) { f.write_mode != context.SkipIfExists })
  let shared_files =
    list.filter(files, fn(f) { f.target == context.SharedTarget })
  let server_files =
    list.filter(files, fn(f) { f.target == context.ServerTarget })
  let client_files =
    list.filter(files, fn(f) { f.target == context.ClientTarget })

  let server_path = config.output_server(cfg)
  let client_path = config.output_client(cfg)

  let server_entries = case config.mode(cfg) {
    Server | Both ->
      list.map(list.append(shared_files, server_files), fn(f) {
        #(server_path <> "/" <> f.path, f.content)
      })
    Client -> []
  }

  let client_entries = case config.mode(cfg) {
    Client | Both ->
      list.map(list.append(shared_files, client_files), fn(f) {
        #(client_path <> "/" <> f.path, f.content)
      })
    Server -> []
  }

  list.append(server_entries, client_entries)
}

/// Every file path the generator would write for the given config — including
/// `SkipIfExists` files. Used by `--check` to keep user-owned `handlers.gleam`
/// off the orphan list while still excluding it from byte-comparison drift
/// reports (`resolve_paths` drops `SkipIfExists` entries).
pub fn expected_paths(
  files: List(GeneratedFile),
  cfg: config.Config,
) -> List(String) {
  let shared_files =
    list.filter(files, fn(f) { f.target == context.SharedTarget })
  let server_files =
    list.filter(files, fn(f) { f.target == context.ServerTarget })
  let client_files =
    list.filter(files, fn(f) { f.target == context.ClientTarget })

  let server_path = config.output_server(cfg)
  let client_path = config.output_client(cfg)

  let server_entries = case config.mode(cfg) {
    Server | Both ->
      list.map(list.append(shared_files, server_files), fn(f) {
        server_path <> "/" <> f.path
      })
    Client -> []
  }

  let client_entries = case config.mode(cfg) {
    Client | Both ->
      list.map(list.append(shared_files, client_files), fn(f) {
        client_path <> "/" <> f.path
      })
    Server -> []
  }

  list.append(server_entries, client_entries)
}

/// Return the output directories that would be written to for the given config.
pub fn output_dirs(cfg: config.Config) -> List(String) {
  case config.mode(cfg) {
    Server -> [config.output_server(cfg)]
    Client -> [config.output_client(cfg)]
    Both -> [config.output_server(cfg), config.output_client(cfg)]
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
