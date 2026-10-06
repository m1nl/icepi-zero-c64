#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t file_size, dma_enabled, dma_length, dma_error;
static uint32_t cassette_sense, play_value, play_writes, enabled_events;
static uint64_t dma_base;
static unsigned int reads, closes, unmounts;

#include "c64_tape.c"

void tap_dma_enable_write(uint32_t value) { dma_enabled = value; }
void tap_dma_base_write(uint64_t value) { dma_base = value; }
void tap_dma_length_write(uint32_t value) { dma_length = value; }
void tap_dma_loop_write(uint32_t value) { assert(value == 0); }
uint32_t tap_dma_error_read(void) { return dma_error; }
uint32_t c64_control_tape_cass_sense_read(void) { return cassette_sense; }
uint32_t c64_control_tape_play_read(void) { return play_value; }
void c64_control_tape_play_write(uint32_t value) {
    play_value = value;
    cassette_sense ^= 1;
    play_writes++;
}
uint32_t c64_control_ev_enable_read(void) { return enabled_events; }
void c64_control_ev_enable_write(uint32_t value) { enabled_events = value; }
void busy_wait(unsigned int value) { (void)value; }
void flush_cpu_dcache(void) { }
void flush_l2_cache(void) { }

FRESULT f_mount(FATFS *fs, const TCHAR *path, BYTE opt) {
    (void)path;
    (void)opt;
    if (!fs) unmounts++;
    return FR_OK;
}
FRESULT f_open(FIL *fil, const TCHAR *path, BYTE mode) {
    (void)path;
    assert(mode == FA_READ);
    fil->obj.objsize = file_size;
    return FR_OK;
}
FRESULT f_close(FIL *fil) { (void)fil; closes++; return FR_OK; }
FRESULT f_read(FIL *fil, void *buf, UINT size, UINT *br) {
    (void)fil;
    reads++;
    memset(buf, 0x55, size);
    *br = size;
    return FR_OK;
}

int main(void) {
    c64_tape_init();
    assert(enabled_events == (EV_TAPE_PLAY | EV_TAPE_STOP));
    // Include every alignment remainder, empty files and a block boundary.
    const uint32_t sizes[] = {0, 1, 2, 3, 4, 511, 512, 513};
    for (unsigned int n = 0; n < sizeof(sizes) / sizeof(sizes[0]); n++) {
        file_size = sizes[n];
        assert(c64_tape_load("test.tap") == 0);
        assert(tap_size % 4 == 0);
        assert(tap_size >= file_size + 32 && tap_size <= file_size + 35);
        for (uint32_t i = 0; i < tap_size; i++)
            assert(tap_data[i] == (i < file_size ? 0x55 : 0x2a));
        dma_error = 0;
        c64_tape_isr(EV_TAPE_PLAY);
        assert(c64_tape_service() == 1);
        assert(dma_enabled && tap_play_running && cassette_sense);
        assert(dma_length == tap_size && dma_base == (uintptr_t)tap_data);
        assert(c64_tape_service() == 0);
        c64_tape_isr(EV_TAPE_STOP);
        assert(c64_tape_service() == 1);
        assert(!dma_enabled && !tap_play_running && !cassette_sense);
    }
    // A rejected start must not toggle cassette sense or retry every service.
    dma_error = 1;
    uint32_t previous_writes = play_writes;
    c64_tape_isr(EV_TAPE_PLAY);
    assert(c64_tape_service() == 1);
    assert(!dma_enabled && !tap_play_running && !tap_play_running_next);
    assert(!cassette_sense && play_writes == previous_writes);
    assert(c64_tape_service() == 0);
    // A later explicit play can succeed after the error clears.
    dma_error = 0;
    c64_tape_isr(EV_TAPE_PLAY);
    assert(c64_tape_service() == 1 && tap_play_running);
    c64_tape_isr(EV_TAPE_STOP);
    assert(c64_tape_service() == 1);
    c64_tape_eject();
    assert(!tap_data && !tap_size);
    // Reject overflow before allocating or attempting to read the file.
    unsigned int previous_reads = reads;
    unsigned int previous_closes = closes, previous_unmounts = unmounts;
    file_size = UINT32_MAX - 32;
    assert(c64_tape_load("large.tap") == -1);
    assert(!tap_data && reads == previous_reads);
    assert(closes == previous_closes + 1 && unmounts == previous_unmounts + 1);
    puts("PASS");
    return 0;
}
