#ifndef SDCARD_PATHS_H
#define SDCARD_PATHS_H

#include "ff.h"
#include <stddef.h>

#define SDCARD_PATH_MAX 1024

const char *sdcard_current_directory(void);
FRESULT sdcard_resolve_path(const char *path, char resolved[SDCARD_PATH_MAX]);
FRESULT sdcard_change_directory(const char *path);

/* The caller mounts the card and frees the returned, sorted entries. */
FRESULT sdcard_read_directory(const char *path, FILINFO **entries, size_t *count);

#endif
