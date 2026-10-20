#include "CArchive.h"

#include <locale.h>
#include <pthread.h>
#ifdef __APPLE__
#include <xlocale.h>
#endif

/*
 * libarchive converts entry names through the current locale's charset. Apps and the worker run
 * in the C locale, where a 7z or rar name in Chinese cannot be converted at all and is lost. The
 * reader switches its own thread to a UTF-8 locale around each libarchive call instead of
 * changing the locale of the whole process.
 */

static locale_t utf8_locale;
static pthread_once_t utf8_locale_once = PTHREAD_ONCE_INIT;

static void make_utf8_locale(void) {
    const char *names[] = {"C.UTF-8", "en_US.UTF-8", "UTF-8"};
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]) && utf8_locale == (locale_t) 0; i++) {
        utf8_locale = newlocale(LC_CTYPE_MASK, names[i], (locale_t) 0);
    }
}

void *sist_archive_enter_utf8_locale(void) {
    pthread_once(&utf8_locale_once, make_utf8_locale);
    if (utf8_locale == (locale_t) 0) {
        return NULL;
    }
    return (void *) uselocale(utf8_locale);
}

void sist_archive_leave_locale(void *previous) {
    if (previous != NULL) {
        uselocale((locale_t) previous);
    }
}
