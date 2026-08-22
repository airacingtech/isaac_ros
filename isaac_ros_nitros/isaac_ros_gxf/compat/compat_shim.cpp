// Shim for running Ubuntu 24.04-built (glibc 2.38 / gcc 13.2) binaries on
// jammy (glibc 2.35 / gcc 11). Provides unversioned definitions for the
// handful of too-new symbols the vendored GXF/cuvslam payloads reference;
// patch_gxf_glibc.sh clears the version requirements on those references so
// they bind here. Build:
//   g++ -shared -fPIC -O2 -s -o libisoc23_compat.so compat_shim.cpp
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>

// ---- glibc 2.38 C23 strto* / sscanf renames: identical semantics for the
// inputs these binaries produce (C23 only adds 0b/0B binary prefixes).
extern "C" {
long __isoc23_strtol(const char* n, char** e, int b) { return strtol(n, e, b); }
unsigned long __isoc23_strtoul(const char* n, char** e, int b) { return strtoul(n, e, b); }
long long __isoc23_strtoll(const char* n, char** e, int b) { return strtoll(n, e, b); }
unsigned long long __isoc23_strtoull(const char* n, char** e, int b) { return strtoull(n, e, b); }
int __isoc23_sscanf(const char* s, const char* f, ...) {
  va_list ap;
  va_start(ap, f);
  int r = vsscanf(s, f, ap);
  va_end(ap);
  return r;
}
}

// ---- GLIBCXX_3.4.32: std::ios_base_library_init(), emitted by <iostream> in
// gcc >= 13.2 TUs. Equivalent to the classic static ios_base::Init object.
extern "C" void gxf_compat_ios_init() __asm__("_ZSt21ios_base_library_initv");
extern "C" void gxf_compat_ios_init() { static std::ios_base::Init init; }

// ---- GLIBCXX_3.4.31: std::__cxx11::basic_string<char>::_M_replace_cold(
//   char* p, size_type len1, const char* s, size_type len2, size_type how_much)
// Out-of-line cold path of in-place _M_replace from gcc 13's basic_string.tcc;
// operates only on the buffer (no allocation, `this` unused for char).
extern "C" void gxf_compat_replace_cold(void*, char*, size_t, const char*, size_t, size_t)
    __asm__("_ZNSt7__cxx1112basic_stringIcSt11char_traitsIcESaIcEE15_M_replace_coldEPcmPKcmm");
extern "C" void gxf_compat_replace_cold(void* /*this*/, char* p, size_t len1,
                                        const char* s, size_t len2, size_t how_much) {
  if (len2 && len2 <= len1) memmove(p, s, len2);
  if (how_much && len1 != len2) memmove(p + len2, p + len1, how_much);
  if (len2 > len1) {
    if (s + len2 <= p + len1) {
      memmove(p, s, len2);
    } else if (s >= p + len1) {
      const size_t poff = (size_t)(s - p) + (len2 - len1);
      memcpy(p, p + poff, len2);
    } else {
      const size_t nleft = (size_t)((p + len1) - s);
      memmove(p, s, nleft);
      memcpy(p + nleft, p + len2, len2 - nleft);
    }
  }
}
