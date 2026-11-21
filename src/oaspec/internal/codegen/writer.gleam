import filepath
import gleam/bool
import gleam/list
import gleam/result
import gleam/string
import oaspec/config.{Both, Client, Server}
import oaspec/internal/codegen/context.{type GeneratedFile}
import simplifile

/// Errors that can occur during file writing.
pub type WriteError {
  CannotCreateDirectory(path: String, reason: simplifile.FileError)
  CannotWriteFile(path: String, reason: simplifile.FileError)
}

/// Write pre-generated files to disk based on configuration.
///
/// **Path overlap.** When `mode = Both` and `output_server` resolves
/// to the same directory as `output_client` (e.g. both set to
/// `"out"`, or to `"out"` and `"out/"`, which differ as strings but
/// name the same directory), shared files are written **once**, not
/// twice. Each unique destination path triggers `on_write` exactly
/// once and appears at most once in the returned list. Distinct
/// server / client paths preserve the existing behaviour: shared
/// files land in both directories.
pub fn write_all(
  files: List(GeneratedFile),
  cfg: config.Config,
  on_write: fn(String) -> Nil,
) -> Result(List(String), WriteError) {
  placements(files, cfg)
  |> list.try_fold([], fn(written, placement) {
    let #(dir, dir_files) = placement
    use _ <- result.try(ensure_directory(dir))
    write_files(dir_files, dir, written, on_write)
  })
}

/// Each output directory the config writes to, with the files that land in
/// it in write order: the shared files, then the server or client files.
/// When `mode = Both` and both outputs name the same directory, the shared
/// files are placed only once.
fn placements(
  files: List(GeneratedFile),
  cfg: config.Config,
) -> List(#(String, List(GeneratedFile))) {
  let of_target = fn(target) {
    list.filter(files, fn(f) { f.target == target })
  }
  let shared_files = of_target(context.SharedTarget)
  let server_path = cfg.output_server
  let client_path = cfg.output_client
  let server = #(
    server_path,
    list.append(shared_files, of_target(context.ServerTarget)),
  )
  let client_files = of_target(context.ClientTarget)
  case cfg.mode {
    Server -> [server]
    Client -> [#(client_path, list.append(shared_files, client_files))]
    Both ->
      case normalise_dir(server_path) == normalise_dir(client_path) {
        True -> [server, #(client_path, client_files)]
        False -> [
          server,
          #(client_path, list.append(shared_files, client_files)),
        ]
      }
  }
}

// Strip a single trailing slash so "out" and "out/" compare equal.
// Strings beyond that are left as-is — full canonicalisation (`./out`,
// symlinked paths, relative-to-cwd resolution) would require an FS
// round-trip we do not need for the documented overlap surface.
fn normalise_dir(path: String) -> String {
  use <- bool.guard(!string.ends_with(path, "/"), path)
  string.drop_end(path, 1)
}

/// Ensure a directory exists, creating it if necessary.
fn ensure_directory(path: String) -> Result(Nil, WriteError) {
  simplifile.create_directory_all(path)
  |> result.map_error(fn(err) { CannotCreateDirectory(path:, reason: err) })
}

/// Write a list of generated files to a directory.
///
/// Files marked `SkipIfExists` (`handlers.gleam`, and
/// `handlers/<operation>.gleam` under `handlers: per_operation`) are
/// written only on first generation. If the file already exists on disk,
/// it is left alone — the user owns the contents and the generator must
/// not clobber their implementation.
///
/// A file whose path has a directory part (`handlers/<operation>.gleam`)
/// gets that directory created under `base_path` first.
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
        use _ <- result.try(case parent_dir(file.path) {
          Ok(dir) -> ensure_directory(base_path <> "/" <> dir)
          // nolint: thrown_away_error -- a path without a directory part lives directly in base_path, which write_all already created
          Error(_) -> Ok(Nil)
        })
        use _ <- result.try(
          simplifile.write(full_path, file.content)
          |> result.map_error(fn(err) {
            CannotWriteFile(path: full_path, reason: err)
          }),
        )
        on_write(full_path)
        Ok([full_path, ..acc])
      }
    }
  })
}

/// The directory part of a relative generated-file path, or `Error(Nil)`
/// when the file sits directly in the output directory.
fn parent_dir(path: String) -> Result(String, Nil) {
  case list.reverse(string.split(path, "/")) {
    [_file, first, ..rest] ->
      Ok(string.join(list.reverse([first, ..rest]), "/"))
    _ -> Error(Nil)
  }
}

/// Every file the config writes paired with its destination path, in write
/// order. When `mode = Both` and both outputs name the same directory, the
/// shared files appear once.
pub fn place(
  files: List(GeneratedFile),
  cfg: config.Config,
) -> List(#(String, GeneratedFile)) {
  placements(files, cfg)
  |> list.flat_map(fn(placement) {
    let #(dir, dir_files) = placement
    list.map(dir_files, fn(f) { #(dir <> "/" <> f.path, f) })
  })
}

/// Write each `#(path, content, write_mode)` entry, creating parent
/// directories as needed. A `SkipIfExists` entry whose file already exists
/// is left alone. Returns the written paths in order.
pub fn write_placed(
  entries: List(#(String, String, context.WriteMode)),
) -> Result(List(String), WriteError) {
  list.try_fold(entries, [], fn(written, entry) {
    let #(path, content, write_mode) = entry
    case write_mode, simplifile.is_file(path) {
      context.SkipIfExists, Ok(True) -> Ok(written)
      _, _ -> {
        use _ <- result.try(ensure_directory(filepath.directory_name(path)))
        use _ <- result.try(
          simplifile.write(path, content)
          |> result.map_error(fn(err) { CannotWriteFile(path:, reason: err) }),
        )
        Ok([path, ..written])
      }
    }
  })
  |> result.map(list.reverse)
}

/// Resolve generated files to their full output paths and content.
/// Used by --check to compare against existing files without writing.
///
/// `SkipIfExists` files (e.g. user-owned `handlers.gleam`)
/// are dropped from the result. `--check` is meant to flag drift in
/// generator-owned files; user-edited files are expected to differ
/// from the bootstrap stub and should not be reported as out-of-date.
///
/// When `mode = Both` and `output_server` resolves to the
/// same directory as `output_client`, shared files appear once in
/// the result, not twice — `--check` would otherwise compare the
/// same file twice and double-count any drift.
pub fn resolve_paths(
  files: List(GeneratedFile),
  cfg: config.Config,
) -> List(#(String, String)) {
  files
  |> list.filter(fn(f) { f.write_mode != context.SkipIfExists })
  |> placements(cfg)
  |> list.flat_map(fn(placement) {
    let #(dir, dir_files) = placement
    list.map(dir_files, fn(f) { #(dir <> "/" <> f.path, f.content) })
  })
}

/// Every file path the generator would write for the given config — including
/// `SkipIfExists` files. Used by `--check` to keep user-owned `handlers.gleam`
/// off the orphan list while still excluding it from byte-comparison drift
/// reports (`resolve_paths` drops `SkipIfExists` entries).
///
/// Same path-overlap dedup as `resolve_paths`: shared files
/// appear once when the two output directories coincide.
pub fn expected_paths(
  files: List(GeneratedFile),
  cfg: config.Config,
) -> List(String) {
  placements(files, cfg)
  |> list.flat_map(fn(placement) {
    let #(dir, dir_files) = placement
    list.map(dir_files, fn(f) { dir <> "/" <> f.path })
  })
}

/// Return the output directories that would be written to for the given config.
pub fn output_dirs(cfg: config.Config) -> List(String) {
  case cfg.mode {
    Server -> [cfg.output_server]
    Client -> [cfg.output_client]
    Both -> [cfg.output_server, cfg.output_client]
  }
}

/// The output directories plus every subdirectory the generator writes
/// into. `--check` scans these for orphaned `.gleam` files. Under
/// `handlers: per_operation`, `<server>/handlers` is always listed, even
/// when the spec has no operations left, so the stubs of removed
/// operations are still found. Other directories that hold no generated
/// file are not listed, so a user's own subdirectory is never treated as
/// generator-owned.
@internal
pub fn owned_dirs(
  files: List(GeneratedFile),
  cfg: config.Config,
) -> List(String) {
  let sub_dirs = fn(target) {
    files
    |> list.filter(fn(f) { f.target == target })
    |> list.filter_map(fn(f) { parent_dir(f.path) })
    |> list.unique
  }
  let server_sub_dirs = case cfg.handler_layout {
    config.PerOperation ->
      list.unique(["handlers", ..sub_dirs(context.ServerTarget)])
    config.SingleFile -> sub_dirs(context.ServerTarget)
  }
  let server_dirs = case cfg.mode {
    Server | Both ->
      list.map(server_sub_dirs, fn(d) { cfg.output_server <> "/" <> d })
    Client -> []
  }
  let client_dirs = case cfg.mode {
    Client | Both ->
      list.map(sub_dirs(context.ClientTarget), fn(d) {
        cfg.output_client <> "/" <> d
      })
    Server -> []
  }
  list.flatten([output_dirs(cfg), server_dirs, client_dirs])
}

/// Convert a write error to a human-readable string.
pub fn error_to_string(error: WriteError) -> String {
  case error {
    CannotCreateDirectory(path:, reason:) ->
      "Failed to create directory "
      <> path
      <> ": Failed to create directory: "
      <> simplifile.describe_error(reason)
    CannotWriteFile(path:, reason:) ->
      "Failed to write file "
      <> path
      <> ": Failed to write file: "
      <> simplifile.describe_error(reason)
  }
}
