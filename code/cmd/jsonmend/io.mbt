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
extern "C" fn ffi_fgetc(f : Int64) -> Int32 = "fgetc"

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
/// stdio is read byte by byte because the runtime exposes no buffered read
/// symbol, and the fixed chunk keeps the memory cost bounded anyway.
fn read_chunk(f : Int64, cap : Int32) -> Bytes {
  let out : Array[Byte] = []
  while out.length() < cap {
    let c = ffi_fgetc(f)
    if c < 0 {
      break
    }
    out.push(c.to_byte())
  }
  Bytes::from_array(out[:])
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
