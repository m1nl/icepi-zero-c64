#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static uint32_t produced;
static uint32_t hw_overruns;
static uint8_t hw_bytes[8], hw_starts[8];
static uint8_t hw_read, hw_write, hw_level;
static int overwrite_on_read;
static uint8_t test_read_byte(unsigned int offset);
static uint32_t test_read_word(unsigned int offset);
static void byte(uint8_t value, int first, int interrupt);
static uint32_t status;
static unsigned int mask = ~0u;
static uint8_t transmitted[256];
static unsigned int tx_count;
static uint32_t joy_state[2], joy_writes[2];
#include "spi_hid.c"

void c64_control_companion_joy_a_write(uint32_t value) { joy_state[0] = value; joy_writes[0]++; }
void c64_control_companion_joy_b_write(uint32_t value) { joy_state[1] = value; joy_writes[1]++; }

uint32_t spi_report_status_read(void) { return (status & 2) | (hw_level != 0); }
static uint8_t test_read_byte(unsigned int offset) {
    assert(offset < 8);
    if (overwrite_on_read) {
        overwrite_on_read = 0;
        byte(0xaa, 0, 0);
    }
    if (!hw_level)
        return 0;
    uint8_t value = hw_bytes[hw_read];
    hw_read = (hw_read + 1) & 7;
    hw_level--;
    // VexRiscv byte loads still select all four Wishbone lanes. The slave
    // returns a zero-extended byte; the CPU extracts the addressed lane.
    return (uint8_t)((uint32_t)value >> (8 * (offset & 3)));
}
static uint32_t test_read_word(unsigned int offset) {
    if (offset == 0)
        return test_read_byte(0);
    assert(offset == 8 || offset == 12);
    return offset == 8 ? produced : (hw_overruns << 5) |
           (hw_level << 1) | (hw_level != 0 && hw_starts[hw_read]);
}
unsigned int irq_getmask(void) { return mask; }
void irq_setmask(unsigned int value) { mask = value; }
unsigned int irq_pending(void) { return hw_level ? (1u << SPI_REPORT_INTERRUPT) : 0; }
void timer0_uptime_latch_write(uint32_t value) { (void)value; }
uint64_t timer0_uptime_cycles_read(void) {
    static uint64_t cycles;
    cycles += CONFIG_CLOCK_FREQUENCY;
    return cycles;
}

static void send_key(uint8_t event, uint8_t usage, const uint8_t *ps2, uint8_t length) {
    (void)event;
    (void)usage;
    for (uint8_t i = 0; i < length; i++)
        transmitted[tx_count++] = ps2[i];
}
static void start(void) { status = 2; }
static void byte(uint8_t value, int first, int interrupt) {
    hw_bytes[hw_write] = value;
    hw_starts[hw_write] = first;
    hw_write = (hw_write + 1) & 7;
    produced++;
    if (hw_level == 8) {
        hw_read = (hw_read + 1) & 7;
        hw_overruns = (hw_overruns + 1) & 0x7ffffffu;
    } else {
        hw_level++;
    }
    if (interrupt)
        spi_hid_isr();
}
static void packet(const uint8_t *data, unsigned int length, int interrupt) {
    start();
    for (unsigned int i = 0; i < length; i++)
        byte(data[i], i == 0, interrupt);
    status = 0;
}
static void expect(const uint8_t *data, unsigned int length) {
    spi_hid_service(send_key);
    assert(tx_count == length);
    if (length)
        assert(memcmp(transmitted, data, length) == 0);
    assert(mask == ~0u);
    tx_count = 0;
}
static void reset(void) {
    produced = hw_overruns = 0;
    hw_read = hw_write = hw_level = 0;
    overwrite_on_read = 0;
    memset(hw_bytes, 0, sizeof(hw_bytes));
    memset(hw_starts, 0, sizeof(hw_starts));
    status = tx_count = 0;
    spi_hid_init();
    assert(joy_state[0] == 0 && joy_state[1] == 0);
    joy_writes[0] = joy_writes[1] = 0;
}
#define PACKET(...) do { const uint8_t p[] = {__VA_ARGS__}; packet(p, sizeof(p), 1); } while (0)
#define EXPECT(...) do { const uint8_t p[] = {__VA_ARGS__}; expect(p, sizeof(p)); } while (0)

int main(void) {
    reset();
    // Real-device regression: whole Space packets arrive before IRQ service.
    // Byte loads at offsets 0..4 used to turn this into 01 00 00 00 29.
    const uint8_t space_make[] = {1, 1, 0x2c, 0x2c, 0x29};
    const uint8_t space_break[] = {1, 1, 0xac, 0x2c, 0xf0, 0x29};
    packet(space_make, sizeof(space_make), 0); EXPECT(0x29);
    packet(space_break, sizeof(space_break), 0); EXPECT(0xf0, 0x29);
    PACKET(1, 1, 4, 4, 0x1c); EXPECT(0x1c);
    PACKET(1, 1, 0x84, 4, 0xf0, 0x1c); EXPECT(0xf0, 0x1c);
    PACKET(1, 1, 0x4f, 0x4f, 0xe0, 0x74); EXPECT(0xe0, 0x74);
    PACKET(1, 1, 0xcf, 0x4f, 0xe0, 0xf0, 0x74); EXPECT(0xe0, 0xf0, 0x74);
    PACKET(1, 1, 0x6c, 4, 0xe0, 0x14); EXPECT(0xe0, 0x14);
    PACKET(1, 1, 0xec, 4, 0xe0, 0xf0, 0x14); EXPECT(0xe0, 0xf0, 0x14);
    PACKET(1, 1, 0x46, 0x46, 0xe0, 0x12, 0xe0, 0x7c);
    EXPECT(0xe0, 0x12, 0xe0, 0x7c);
    PACKET(1, 1, 0xc6, 0x46, 0xe0, 0xf0, 0x7c, 0xe0, 0xf0, 0x12);
    EXPECT(0xe0, 0xf0, 0x7c, 0xe0, 0xf0, 0x12);
    PACKET(1, 1, 0x48, 0x48, 0xe1, 0x14, 0x77, 0xe1, 0xf0, 0x14, 0xf0, 0x77);
    EXPECT(0xe1, 0x14, 0x77, 0xe1, 0xf0, 0x14, 0xf0, 0x77);
    // No PS/2 suffix for unmapped keys or Pause release.
    PACKET(1, 1, 0xc8, 0x48); expect(NULL, 0);
    PACKET(1, 2, 1, 0xff, 0x01, 0); expect(NULL, 0);
    PACKET(1, 3, 0, 0x10, 0x80, 0x80, 0); expect(NULL, 0);
    PACKET(1, 0, 0, 0); expect(NULL, 0);
    // Reject a truncated prefix instead of changing interpretation of next key.
    PACKET(1, 1, 0x4f, 0x4f, 0xe0); expect(NULL, 0);
    assert(dropped_reports == 1);

    // The final byte can be drained before CS rises. Foreground finalizes it.
    PACKET(1, 1, 5, 5, 0x32); EXPECT(0x32);
    // New packet marker also finalizes the previous packet, without foreground.
    PACKET(1, 1, 4, 4, 0x1c);
    PACKET(1, 1, 0x84, 4, 0xf0, 0x1c);
    EXPECT(0x1c);
    EXPECT(0xf0, 0x1c);

    reset();
    const uint8_t pause[] = {1, 1, 0x48, 0x48, 0xe1, 0x14, 0x77, 0xe1, 0xf0, 0x14, 0xf0, 0x77};
    packet(pause, sizeof(pause), 0); // Too late: first four bytes overwritten.
    expect(NULL, 0);
    assert(dropped_reports == 1);
    PACKET(1, 1, 4, 4, 0x1c); EXPECT(0x1c);
    // Keep packets intact when the foreground queue fills.
    reset();
    for (unsigned int i = 0; i < QUEUE_SIZE; i++)
        PACKET(1, 1, 4, 4, 0x1c);
    spi_hid_isr();
    assert(dropped_reports == 1);
    for (unsigned int i = 0; i < QUEUE_SIZE - 1; i++)
        EXPECT(0x1c);
    expect(NULL, 0);
    // Overwrite between head metadata and the consuming byte read: discard
    // that old marker, then recover at the next genuine packet boundary.
    reset();
    const uint8_t print[] = {1, 1, 0x46, 0x46, 0xe0, 0x12, 0xe0, 0x7c};
    packet(print, sizeof(print), 0);
    overwrite_on_read = 1;
    expect(NULL, 0);
    assert(dropped_reports == 1);
    PACKET(1, 1, 4, 4, 0x1c); EXPECT(0x1c);
    // Overwrite generation wrapping still invalidates a partial report.
    reset();
    hw_overruns = 0x7ffffffu;
    last_overrun = hw_overruns << 5;
    packet(print, sizeof(print), 0);
    byte(0xaa, 0, 0);
    expect(NULL, 0);
    assert(dropped_reports == 1 && hw_overruns == 0);
    PACKET(1, 1, 4, 4, 0x1c); EXPECT(0x1c);
    // Unsigned producer arithmetic survives the 32-bit count wrapping.
    reset();
    produced = UINT32_MAX - 1;
    PACKET(1, 1, 4, 4, 0x1c); EXPECT(0x1c);
    assert(produced == 3);
    // Companion digital direction bits are reversed relative to core/USB.
    reset();
    const uint16_t mapped_bits[] = {8, 4, 2, 1, 16, 32, 64, 128};
    for (unsigned int port = 0; port < 2; port++) {
        for (unsigned int bit_index = 0; bit_index < 8; bit_index++) {
            const uint8_t p[] = {1, 3, port, 1u << bit_index, 0x80, 0x80, 0};
            packet(p, sizeof(p), bit_index & 1);
            expect(NULL, 0);
            assert(joy_state[port] == mapped_bits[bit_index]);
            assert(joy_state[port ^ 1] == (port ? 128u : 0u));
        }
    }
    PACKET(1, 3, 0, 0x15, 0, 0xff, 0x0c); expect(NULL, 0);
    assert(joy_state[0] == 0x31a && joy_state[1] == 128);
    PACKET(1, 3, 1, 0xff, 0, 0, 0xf3); expect(NULL, 0);
    assert(joy_state[1] == 0xff); // Ignore shoulders, triggers and stick clicks.
    // Complete states replace old states: neutral reports release all buttons.
    PACKET(1, 3, 0, 0, 0x80, 0x80, 0); expect(NULL, 0);
    assert(joy_state[0] == 0 && joy_state[1] == 0xff);
    PACKET(1, 3, 1, 0, 0x80, 0x80, 0); expect(NULL, 0);
    assert(joy_state[1] == 0);
    unsigned int writes = joy_writes[0] + joy_writes[1];
    PACKET(1, 3, 2, 0xff, 0x80, 0x80, 0x0c); expect(NULL, 0);
    PACKET(1, 3, 0, 0xff, 0x80, 0x80); expect(NULL, 0);
    PACKET(1, 3, 0, 0xff, 0x80, 0x80, 0, 0); expect(NULL, 0);
    assert(joy_writes[0] + joy_writes[1] == writes && dropped_reports == 3);
    // Joystick reports are applied even when the keyboard queue is full.
    for (unsigned int i = 0; i < QUEUE_SIZE; i++)
        PACKET(1, 1, 4, 4, 0x1c);
    PACKET(1, 3, 1, 0x12, 0x80, 0x80, 0);
    spi_hid_isr();
    assert(joy_state[1] == 0x14);
    puts("PASS: companion keyboard and joystick reports, filtering, wrap, overrun, queue, deferred CS");
    return 0;
}
