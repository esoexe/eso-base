#!/usr/bin/env python3
"""eso-pamtest.py SERVICE PASSWORD: exit 0 if PAM accepts PASSWORD for the CALLING user (as ESO Lock asks it).
Build test for stage 6c: run as the user (not root), so pam_unix has to go through unix_chkpwd like the lock screen."""
import ctypes, ctypes.util, os, pwd, sys

CONV_FUNC = None


class PamMessage(ctypes.Structure):
    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]


class PamResponse(ctypes.Structure):
    _fields_ = [("resp", ctypes.c_char_p), ("resp_retcode", ctypes.c_int)]


CONV_FUNC = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.POINTER(PamMessage)),
                             ctypes.POINTER(ctypes.POINTER(PamResponse)), ctypes.c_void_p)


class PamConv(ctypes.Structure):
    _fields_ = [("conv", CONV_FUNC), ("appdata_ptr", ctypes.c_void_p)]


def main():
    service, password = sys.argv[1].encode(), sys.argv[2].encode()
    user = pwd.getpwuid(os.getuid()).pw_name.encode()
    libpam = ctypes.CDLL(ctypes.util.find_library("pam") or "libpam.so.0")
    libc = ctypes.CDLL(ctypes.util.find_library("c"))
    libc.calloc.restype, libc.calloc.argtypes = ctypes.c_void_p, [ctypes.c_size_t, ctypes.c_size_t]
    libc.strdup.restype, libc.strdup.argtypes = ctypes.c_void_p, [ctypes.c_char_p]
    libpam.pam_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(PamConv), ctypes.POINTER(ctypes.c_void_p)]
    libpam.pam_authenticate.argtypes = [ctypes.c_void_p, ctypes.c_int]
    libpam.pam_end.argtypes = [ctypes.c_void_p, ctypes.c_int]
    libpam.pam_strerror.restype, libpam.pam_strerror.argtypes = ctypes.c_char_p, [ctypes.c_void_p, ctypes.c_int]

    @CONV_FUNC
    def conv(n, msgs, resp, _data):
        arr = ctypes.cast(libc.calloc(n, ctypes.sizeof(PamResponse)), ctypes.POINTER(PamResponse))
        for i in range(n):
            if msgs[i].contents.msg_style in (1, 2):
                arr[i].resp = ctypes.cast(libc.strdup(password), ctypes.c_char_p)
        resp[0] = arr
        return 0

    h = ctypes.c_void_p()
    c = PamConv(conv, None)
    r = libpam.pam_start(service, user, ctypes.byref(c), ctypes.byref(h))
    if r != 0:
        print(f"pam_start({service.decode()}) failed: {r}")
        return 2
    r = libpam.pam_authenticate(h, 0)
    print(f"{user.decode()} @ {service.decode()}: {libpam.pam_strerror(h, r).decode()}")
    libpam.pam_end(h, r)
    return 0 if r == 0 else 1


sys.exit(main())
