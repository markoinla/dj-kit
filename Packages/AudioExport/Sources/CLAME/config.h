/* Hand-written config.h for building libmp3lame 3.100 as a SwiftPM C target on
 * Apple Silicon macOS (replaces autoconf's). Encoder only: no mpglib decoder,
 * no SSE/NASM paths, no frontend. */
#ifndef LAME_CONFIG_H
#define LAME_CONFIG_H

/* Debug builds pass -DDEBUG, which turns on LAME's stderr chatter. */
#undef DEBUG

#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LIMITS_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_MEMCPY 1
#define HAVE_STRCHR 1
#define HAVE_LONG_DOUBLE 1

#define HAVE_INT8_T 1
#define HAVE_INT16_T 1
#define HAVE_INT32_T 1
#define HAVE_INT64_T 1
#define HAVE_UINT8_T 1
#define HAVE_UINT16_T 1
#define HAVE_UINT32_T 1
#define HAVE_UINT64_T 1

#define SIZEOF_SHORT 2
#define SIZEOF_UNSIGNED_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_UNSIGNED_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_UNSIGNED_LONG 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF_UNSIGNED_LONG_LONG 8
#define SIZEOF_FLOAT 4
#define SIZEOF_DOUBLE 8
#define SIZEOF_LONG_DOUBLE 8

/* add ieee754_float64_t / ieee754_float32_t types (configure's AH_VERBATIM) */
typedef double ieee754_float64_t;
typedef float ieee754_float32_t;

#define LAME_LIBRARY_BUILD 1
#define PACKAGE "lame"
#define PACKAGE_NAME "lame"
#define PACKAGE_VERSION "3.100"
#define VERSION "3.100"

#endif /* LAME_CONFIG_H */
