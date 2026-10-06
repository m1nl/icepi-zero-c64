#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sdcard_paths.h"

static int index_in_dir, closes, mounts, unmounts;
static int mount_error, read_error, close_error, many_entries;
static char opened[SDCARD_PATH_MAX];

FRESULT f_mount(FATFS *fs, const TCHAR *path, BYTE opt) {
    (void)path; (void)opt;
    if (!fs) { unmounts++; return FR_OK; }
    mounts++;
    return mount_error ? FR_NOT_READY : FR_OK;
}
FRESULT f_opendir(DIR *dir, const TCHAR *path) {
    (void)dir;
    strcpy(opened, path);
    index_in_dir = 0;
    return strcmp(path, "/") == 0 || strcmp(path, "/games") == 0 ||
           strcmp(path, "/games/My Games") == 0 ? FR_OK : FR_NO_PATH;
}
FRESULT f_closedir(DIR *dir) {
    (void)dir;
    closes++;
    return close_error ? FR_DISK_ERR : FR_OK;
}
FRESULT f_readdir(DIR *dir, FILINFO *info) {
    (void)dir;
    if (read_error && index_in_dir == 1) return FR_DISK_ERR;
    memset(info, 0, sizeof(*info));
    if (many_entries) {
        if (index_in_dir < 70)
            snprintf(info->fname, sizeof(info->fname), "file%02d", 69 - index_in_dir++);
        return FR_OK;
    }
    const char *names[] = {"zebra", "beta", ".", "Zoo", "Apple", "..", "alpha", "Alpha"};
    if (index_in_dir < 8) {
        strcpy(info->fname, names[index_in_dir]);
        info->fattrib = index_in_dir == 1 || index_in_dir == 3 ? AM_DIR : 0;
        info->fsize = 100 + index_in_dir++;
    }
    return FR_OK;
}

static void expect_path(const char *input, const char *expected) {
    char resolved[SDCARD_PATH_MAX];
    assert(sdcard_resolve_path(input, resolved) == FR_OK);
    assert(strcmp(resolved, expected) == 0);
}

int main(void) {
    expect_path("", "/");
    assert(sdcard_change_directory("games/") == FR_OK);
    assert(strcmp(sdcard_current_directory(), "/games") == 0);
    expect_path("demo.d64", "/games/demo.d64");
    expect_path("new.d64", "/games/new.d64"); // Creation need not name an existing file.
    expect_path("/demo.d64", "/demo.d64");
    expect_path("/", "/");
    expect_path(".", "/games");
    expect_path("..", "/");
    expect_path("../..", "/");
    expect_path("0:/demo.d64", "/demo.d64");
    expect_path("0:demo.d64", "/games/demo.d64");
    assert(sdcard_change_directory("./My Games") == FR_OK);
    expect_path("../../games//./demo.d64", "/games/demo.d64");
    expect_path("\\demo.d64", "/demo.d64");
    char pinned[SDCARD_PATH_MAX];
    assert(sdcard_resolve_path("image.d64", pinned) == FR_OK);
    assert(sdcard_change_directory("/") == FR_OK);
    expect_path(pinned, "/games/My Games/image.d64");
    assert(sdcard_change_directory("/games") == FR_OK);
    assert(sdcard_change_directory("file.d64") == FR_NO_PATH);
    assert(strcmp(sdcard_current_directory(), "/games") == 0);
    mount_error = 1;
    assert(sdcard_change_directory("/") == FR_NOT_READY);
    mount_error = 0;
    close_error = 1;
    assert(sdcard_change_directory("/") == FR_DISK_ERR);
    close_error = 0;
    assert(strcmp(sdcard_current_directory(), "/games") == 0);
    char oversized[SDCARD_PATH_MAX + 1], resolved[SDCARD_PATH_MAX];
    memset(oversized, 'a', sizeof(oversized) - 1);
    oversized[sizeof(oversized) - 1] = 0;
    assert(sdcard_resolve_path(oversized, resolved) == FR_INVALID_NAME);
    assert(sdcard_resolve_path("1:/games", resolved) == FR_INVALID_NAME);

    FILINFO *entries;
    size_t count;
    assert(sdcard_read_directory(".", &entries, &count) == FR_OK);
    assert(strcmp(opened, "/games") == 0 && count == 6);
    const char *sorted[] = {"beta", "Zoo", "Alpha", "alpha", "Apple", "zebra"};
    for (size_t i = 0; i < count; i++) assert(strcmp(entries[i].fname, sorted[i]) == 0);
    assert(entries[0].fattrib & AM_DIR && entries[1].fattrib & AM_DIR);
    assert(entries[0].fsize == 101 && entries[5].fsize == 100);
    free(entries);
    many_entries = 1;
    assert(sdcard_read_directory("/", &entries, &count) == FR_OK && count == 70);
    assert(strcmp(entries[0].fname, "file00") == 0 && strcmp(entries[69].fname, "file69") == 0);
    free(entries);
    many_entries = 0;
    read_error = 1;
    assert(sdcard_read_directory(".", &entries, &count) == FR_DISK_ERR);
    assert(!entries && !count);
    read_error = 0;
    close_error = 1;
    assert(sdcard_read_directory(".", &entries, &count) == FR_DISK_ERR);
    assert(!entries && !count);
    close_error = 0;
    assert(sdcard_read_directory("missing", &entries, &count) == FR_NO_PATH);
    assert(!entries && !count);
    assert(mounts == unmounts && closes > 0);
    puts("PASS");
    return 0;
}
