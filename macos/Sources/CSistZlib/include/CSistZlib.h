#ifndef SIST_CSISTZLIB_H
#define SIST_CSISTZLIB_H

/*
 * The three zlib functions the catalog uses to store long texts compressed. zlib is part of
 * macOS and of every Linux system; as with CArchive, the declarations are repeated here so that
 * no development package is needed. They have not changed since zlib 1.2.
 */

#define SIST_Z_OK 0
#define SIST_Z_BUF_ERROR (-5)

unsigned long compressBound(unsigned long sourceLen);
int compress2(unsigned char *dest, unsigned long *destLen, const unsigned char *source,
              unsigned long sourceLen, int level);
int uncompress(unsigned char *dest, unsigned long *destLen, const unsigned char *source,
               unsigned long sourceLen);

#endif
