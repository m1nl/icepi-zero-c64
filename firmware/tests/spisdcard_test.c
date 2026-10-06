#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <libbase/timeout.h>

#define CSR_SPISDCARD_BASE 1
#define CONFIG_CLOCK_FREQUENCY 31428571
#define min(a, b) ((a) < (b) ? (a) : (b))
#define max(a, b) ((a) > (b) ? (a) : (b))

static uint8_t expected_tx[2048], response[2048];
static unsigned int script_size, transfers, fail_transfer, status_reads;
static uint32_t mosi, cs;
static int stuck;

void timeout_start(struct timeout *timeout, unsigned int us) {
    assert(us == 10000);
    timeout->remaining = 4;
}
int timeout_expired(struct timeout *timeout) { return !--timeout->remaining; }
void busy_wait(unsigned int ms) { (void)ms; }
void busy_wait_us(unsigned int us) { (void)us; }
static void spisdcard_clk_divider_write(uint32_t value) {
    assert(value >= 2 && value <= 256);
}
static void spisdcard_mosi_write(uint32_t value) { mosi = value; }
static void spisdcard_cs_write(uint32_t value) { cs = value; }
static void spisdcard_control_write(uint32_t value) {
    assert(value == (8 * (1 << 8) | 1));
    transfers++;
    if (fail_transfer && transfers >= fail_transfer) {
        stuck = 1;
        return;
    }
    assert(transfers <= script_size);
    assert(mosi == expected_tx[transfers - 1]);
}
static uint32_t spisdcard_status_read(void) {
    status_reads++;
    return stuck ? 0 : 3; // DONE plus the aligned-mode bit.
}
static uint32_t spisdcard_miso_read(void) {
    assert(!stuck && transfers && transfers <= script_size);
    return response[transfers - 1];
}

#include "spisdcard.c"

static void byte(uint8_t tx, uint8_t rx) {
    assert(script_size < sizeof(response));
    expected_tx[script_size] = tx;
    response[script_size++] = rx;
}
static void command(uint8_t cmd, uint32_t arg, uint8_t reply) {
    if (cmd != CMD0 && cmd != CMD12) {
        byte(0xff, 0xff); // Deselect.
        byte(0xff, 0xff); // Select dummy clocks.
        byte(0xff, 0xff); // Card ready.
    }
    byte(0x40 | cmd, 0xff);
    for (int shift = 24; shift >= 0; shift -= 8)
        byte(arg >> shift, 0xff);
    byte(cmd == CMD0 ? 0x95 : cmd == CMD8 ? 0x87 : 1, 0xff);
    if (cmd == CMD12) byte(0xff, 0xff); // Stuff byte.
    byte(0xff, reply);
}
static void reset_run(unsigned int fail) {
    transfers = status_reads = stuck = 0;
    fail_transfer = fail;
    cs = SPI_CS_HIGH;
}
static void init_script(int ccs) {
    script_size = 0;
    for (int i = 0; i < 10; i++) byte(0xff, 0xff);
    command(CMD0, 0, 1);
    command(CMD8, 0x1aa, 1);
    byte(0xff, 0); byte(0xff, 0); byte(0xff, 1); byte(0xff, 0xaa);
    command(CMD55, 0, 1);
    command(41, 1 << 30, 0);
    command(CMD58, 0, 0);
    byte(0xff, ccs ? 0x40 : 0);
    for (int i = 0; i < 3; i++) byte(0xff, 0);
    byte(0xff, 0xff); // Final deselect.
}
static void storage_script(int writing, unsigned int count, int ccs) {
    script_size = 0;
    uint8_t cmd = writing ? (count > 1 ? CMD25 : CMD24) : (count > 1 ? CMD18 : CMD17);
    command(cmd, ccs ? 7 : 7 * 512, 0);
    for (unsigned int n = 0; n < count; n++) {
        if (writing) {
            byte(0xff, 0xff); // Ready for data.
            byte(count > 1 ? 0xfc : 0xfe, 0xff);
            for (int i = 0; i < 512; i++) byte(0xa5, 0xff);
            byte(0xff, 0xff); byte(0xff, 0xff); // CRC.
            byte(0xff, 0x05); // Accepted.
            byte(0xff, 0); byte(0xff, 0xff); // Busy, then ready.
        } else {
            byte(0xff, 0xfe);
            for (int i = 0; i < 512; i++) byte(0xff, 0x5a);
            byte(0xff, 0xff); byte(0xff, 0xff);
        }
    }
    if (count > 1) {
        if (writing) {
            byte(0xff, 0xff);
            byte(0xfd, 0xff);
            byte(0xff, 0); byte(0xff, 0xff);
        } else {
            command(CMD12, 0, 0);
        }
    }
    byte(0xff, 0xff);
}

int main(void) {
    uint8_t buffer[1024];
    for (int ccs = 0; ccs <= 1; ccs++) {
        init_script(ccs);
        reset_run(0);
        spisdcardstatus = STA_NOINIT;
        assert(disk_initialize(0) == 0);
        assert(spisdcard_ccs == ccs && cs == SPI_CS_HIGH && transfers == script_size);
        // Each stalled initialization transfer must return, including OCR and cleanup.
        for (unsigned int fail = 1; fail <= script_size; fail++) {
            reset_run(fail);
            spisdcardstatus = STA_NOINIT;
            assert(disk_initialize(0) == STA_NOINIT);
            assert(cs == SPI_CS_HIGH && transfers <= fail + 1);
        }
        for (int writing = 0; writing <= 1; writing++) {
            for (unsigned int count = 1; count <= 2; count++) {
                storage_script(writing, count, ccs);
                // Inject a permanent stall at every byte, including CRC and stop.
                for (unsigned int fail = 1; fail <= script_size; fail++) {
                    reset_run(fail);
                    memset(buffer, 0xa5, sizeof(buffer));
                    DRESULT result = writing ? disk_write(0, buffer, 7, count)
                                             : disk_read(0, buffer, 7, count);
                    assert(result == RES_ERROR);
                    assert(cs == SPI_CS_HIGH && transfers <= fail + 2);
                    assert(status_reads <= transfers + 15);
                }
                // The next operation can succeed after the controller recovers.
                reset_run(0);
                memset(buffer, 0xa5, sizeof(buffer));
                DRESULT result = writing ? disk_write(0, buffer, 7, count)
                                         : disk_read(0, buffer, 7, count);
                assert(result == RES_OK && transfers == script_size && cs == SPI_CS_HIGH);
                if (!writing)
                    for (unsigned int i = 0; i < count * 512; i++) assert(buffer[i] == 0x5a);
            }
        }
    }
    // A card can reject data even when the SPI controller completes normally.
    storage_script(1, 1, 1);
    response[526] = 0x0b; // CRC error instead of the accepted-data response.
    reset_run(0);
    memset(buffer, 0xa5, sizeof(buffer));
    assert(disk_write(0, buffer, 7, 1) == RES_ERROR && cs == SPI_CS_HIGH);
    // A failed stop command must invalidate an otherwise successful read.
    storage_script(0, 2, 1);
    response[script_size - 2] = 0x04;
    reset_run(0);
    assert(disk_read(0, buffer, 7, 2) == RES_ERROR && cs == SPI_CS_HIGH);
    // An error sentinel must never be stored as a received data byte.
    storage_script(0, 1, 1);
    reset_run(14);
    memset(buffer, 0xa5, sizeof(buffer));
    assert(disk_read(0, buffer, 7, 1) == RES_ERROR);
    assert(buffer[0] == 0x5a && buffer[1] == 0x5a && buffer[2] == 0xa5);
    reset_run(0);
    assert(disk_read(1, buffer, 0, 1) == RES_PARERR);
    assert(disk_write(1, buffer, 0, 1) == RES_PARERR);
    assert(disk_read(0, buffer, 0, 0) == RES_PARERR);
    assert(disk_write(0, buffer, 0, 0) == RES_PARERR);
    assert(!transfers);
    puts("PASS");
    return 0;
}
