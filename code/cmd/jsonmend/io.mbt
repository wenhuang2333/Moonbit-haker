// Low level stdio for the CLI. The toolchain runtime does not expose a file
// API, so the CLI talks to libc/stdio directly; the package is therefore
// restricted to the native backend (see `moon.pkg`).

///|
extern "C" fn ffi_is_null(p : Int64) -> Int32 = "moonbit_is_null"

///|
extern "C" fn ffi_fgetc(f : Int64) -> Int32 = "fgetc"

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
/// Every remaining byte of an open stream.
fn read_stream(f : Int64) -> Bytes {
  let out : Array[Byte] = []
  let mut c = ffi_fgetc(f)
  while c >= 0 {
    out.push(c.to_byte())
    c = ffi_fgetc(f)
  }
  Bytes::from_array(out[:])
}

///|
/// Bytes of the named file, or of standard input when `path` is `None`.
fn read_input(path : String?) -> Bytes? {
  match path {
    Some(p) => {
      let f = ffi_fopen(@utf8.encode(p), b"rb")
      if ffi_is_null(f) != 0 {
        None
      } else {
        let bytes = read_stream(f)
        ignore(ffi_fclose(f))
        Some(bytes)
      }
    }
    None => {
      let f = ffi_fdopen(0, b"rb")
      if ffi_is_null(f) != 0 {
        None
      } else {
        let bytes = read_stream(f)
        ignore(ffi_fclose(f))
        Some(bytes)
      }
    }
  }
}

///|
/// Flush stdio and leave with `code`.
fn quit(code : Int32) -> Unit {
  ignore(ffi_fflush(0L))
  ffi_exit(code)
}
