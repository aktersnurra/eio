#define _XOPEN_SOURCE 600
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/unixsupport.h>

CAMLprim value caml_eio_test_open_pty(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(pair);
  /* Allocate first so an OCaml allocation failure cannot leak descriptors. */
  pair = caml_alloc_tuple(2);
  int master = posix_openpt(O_RDWR | O_NOCTTY);
  if (master == -1) caml_uerror("posix_openpt", Nothing);
  int slave = -1;
  if (grantpt(master) == -1 || unlockpt(master) == -1) goto error;
  char *name = ptsname(master);
  if (name == NULL) goto error;
  slave = open(name, O_RDWR | O_NOCTTY);
  if (slave == -1) goto error;
  if (fcntl(master, F_SETFD, FD_CLOEXEC) == -1 ||
      fcntl(slave, F_SETFD, FD_CLOEXEC) == -1) goto error;
  Store_field(pair, 0, Val_int(master));
  Store_field(pair, 1, Val_int(slave));
  CAMLreturn(pair);
error: {
    int saved = errno;
    if (slave != -1) close(slave);
    close(master);
    errno = saved;
    caml_uerror("open_pty", Nothing);
  }
}
