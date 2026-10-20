#ifndef SIST_CARCHIVE_H
#define SIST_CARCHIVE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <time.h>

/*
 * The part of libarchive 3.x (archive.h, archive_entry.h) the archive extractor uses.
 *
 * macOS ships libarchive in /usr/lib (bsdtar is built on it) but not its headers, so the
 * declarations are repeated here and the library is linked with -larchive. On Linux the same
 * library comes from the libarchive-dev package. Everything below has been part of the stable
 * libarchive 3 API for years.
 */

struct archive;
struct archive_entry;

#define SIST_ARCHIVE_EOF 1
#define SIST_ARCHIVE_OK 0
#define SIST_ARCHIVE_RETRY (-10)
#define SIST_ARCHIVE_WARN (-20)
#define SIST_ARCHIVE_FAILED (-25)
#define SIST_ARCHIVE_FATAL (-30)

/* archive_entry_filetype() */
#define SIST_AE_IFMT 0170000
#define SIST_AE_IFREG 0100000

struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
/* A compressed stream that is not an archive (file.txt.gz) is read as one entry */
int archive_read_support_format_raw(struct archive *);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_open_memory(struct archive *, const void *buffer, size_t size);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *buffer, size_t size);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_format_name(struct archive *);

const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);

/* shim.c: switch the calling thread to a UTF-8 locale and back (see there) */
void *sist_archive_enter_utf8_locale(void);
void sist_archive_leave_locale(void *previous);

#endif
