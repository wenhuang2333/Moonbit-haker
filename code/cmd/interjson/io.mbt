// Low level stdio for the CLI. The toolchain runtime does not expose a file
// API, so the CLI talks to libc/stdio directly; the package is therefore
// restricted to the native backend (see `moon.pkg`).

///|
extern "C" fn ffi_is_null(p : Int64) -> Int32 = "moonbit_is_null"

///|
extern "C" fn ffi_fclose(f : Int64) -> Int32 = "moonbit_fclose_ffi"

///|
extern "C" fn ffi_fflush(f : Int64) -> Int32 = "fflush"

///|
extern "C" fn ffi_exit(code : Int32) -> Unit = "exit"

///|
#borrow(mode)
extern "C" fn ffi_fdopen(fd : Int32, mode : Bytes) -> Int64 = "fdopen"

///|
#borrow(path, mode)
extern "C" fn ffi_fopen(path : Bytes, mode : Bytes) -> Int64 = "moonbit_fopen_ffi"

///|
/// Bulk read into a `Bytes` buffer. `moonbit_fread_ffi` is provided by the
/// toolchain runtime, so no C header of our own is needed.
#borrow(buf)
extern "C" fn ffi_fread(
  buf : Bytes,
  size : Int32,
  nitems : Int32,
  f : Int64,
) -> Int64 = "moonbit_fread_ffi"

///|
/// The named file, or standard input when `path` is `None`, as a stdio
/// stream. `0L` means the input could not be opened.
fn open_input(path : String?) -> Int64 {
  match path {
    Some(p) => {
      let f = ffi_fopen(@utf8.encode(p), b"rb")
      if ffi_is_null(f) != 0 {
        0L
      } else {
        f
      }
    }
    None => {
      let f = ffi_fdopen(0, b"rb")
      if ffi_is_null(f) != 0 {
        0L
      } else {
        f
      }
    }
  }
}

///|
/// The next piece of the stream, at most `cap` bytes; empty at end of stream.
/// One `fread` per chunk: reading byte by byte through `fgetc` capped the CLI
/// at roughly 25 MB/s no matter how fast the engine was.
fn read_chunk(f : Int64, cap : Int32) -> Bytes {
  let buf = Bytes::make(cap, b'\x00')
  let n = ffi_fread(buf, 1, cap, f)
  if n <= 0L {
    Bytes::make(0, b'\x00')
  } else {
    Bytes::makei(n.to_int(), i => buf[i])
  }
}

///|
/// Bulk write of a byte buffer. `fwrite` is used rather than the runtime's
/// `println`, whose output is buffered until the process exits: a line
/// protocol has to reach the reader while the process is still running.
#borrow(buf)
extern "C" fn ffi_fwrite(
  buf : Bytes,
  size : Int32,
  nitems : Int32,
  f : Int64,
) -> Int64 = "moonbit_fwrite_ffi"

///|
/// Standard output as its own stdio stream. `0L` when it cannot be opened.
///
/// The protocol writers use this instead of `println` so that one line is
/// flushed per response; `println`'s buffer is only flushed at exit, which
/// deadlocks an interactive client.
fn open_output() -> Int64 {
  let f = ffi_fdopen(1, b"wb")
  if ffi_is_null(f) != 0 {
    0L
  } else {
    f
  }
}

///|
/// Write one protocol line and flush it.
fn write_line(f : Int64, line : String) -> Unit {
  if f == 0L {
    return
  }
  let bytes = @utf8.encode(line + "\n")
  ignore(ffi_fwrite(bytes, 1, bytes.length(), f))
  ignore(ffi_fflush(f))
}

///|
/// Close a stream opened by `open_input`.
fn close_input(f : Int64) -> Unit {
  ignore(ffi_fclose(f))
}

///|
/// Flush stdio and leave with `code`.
fn quit(code : Int32) -> Unit {
  ignore(ffi_fflush(0L))
  ffi_exit(code)
}
