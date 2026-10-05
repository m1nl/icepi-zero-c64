#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "spi_hid.h"

static uint32_t flags, enabled;
static uint8_t native_key, native_modifiers;
static uint8_t ps2_bytes[256];
static unsigned int ps2_count, resets;
static char alt_key;
static uint8_t pending_event, pending_usage, pending_ps2[8], pending_length;
static int key_pending;
#include "input.c"

uint32_t c64_control_flags_read(void) { return flags; }
void c64_control_flags_write(uint32_t value) { flags = value; }
uint32_t c64_control_hid_key_0_read(void) { return native_key; }
uint32_t c64_control_hid_key_modifiers_read(void) { return native_modifiers; }
uint32_t c64_control_ev_enable_read(void) { return enabled; }
void c64_control_ev_enable_write(uint32_t value) { enabled = value; }
void c64_control_ps2_character_data_write(uint32_t value) { ps2_bytes[ps2_count++] = value; }
void c64_control_ps2_character_valid_write(uint32_t value) { (void)value; }
uint32_t c64_control_ps2_character_valid_read(void) { return 0; }
void busy_wait(unsigned int value) { (void)value; }
int readchar_nonblock(void) { return 0; }
void spi_hid_init(void) { }
void spi_hid_isr(void) { }
void spi_hid_service(spi_hid_key_handler handler) {
    if (key_pending) {
        key_pending = 0;
        handler(pending_event, pending_usage, pending_ps2, pending_length);
    }
}
static void reset_cpu(void) { resets++; }
static void alt_handler(char key) { alt_key = key; }
static void post(uint8_t event, uint8_t usage, const uint8_t *bytes, uint8_t length) {
    pending_event = event; pending_usage = usage; pending_length = length;
    if (length) memcpy(pending_ps2, bytes, length);
    key_pending = 1;
}
static void key(uint8_t event, uint8_t usage, const uint8_t *bytes, uint8_t length) {
    post(event, usage, bytes, length);
    input_service();
}
#define KEY(event, usage, ...) do { const uint8_t data[] = {__VA_ARGS__}; key(event, usage, data, sizeof(data)); } while (0)
#define EXPECT_PS2(...) do { const uint8_t data[] = {__VA_ARGS__}; assert(ps2_count == sizeof(data)); assert(memcmp(ps2_bytes, data, sizeof(data)) == 0); ps2_count = 0; } while (0)
static void expect_text(const char *text) {
    while (*text) assert(input_nonblock() == *text++);
    assert(input_nonblock() == 0);
}
static void print_make(void) { KEY(0x46, 0x46, 0xe0, 0x12, 0xe0, 0x7c); }
static void print_break(void) { KEY(0xc6, 0x46, 0xe0, 0xf0, 0x7c, 0xe0, 0xf0, 0x12); }
int main(void) {
    input_init();
    input_register_reset_callback(reset_cpu);
    input_register_alt_callback(alt_handler);
    // Core receives normal make/break packets when the overlay is closed.
    KEY(4, 4, 0x1c); EXPECT_PS2(0x1c);
    print_make(); assert(flags & OVERLAY_MASK);
    print_make(); assert(flags & OVERLAY_MASK); // Repeat cannot toggle twice.
    print_break(); assert(ps2_count == 0);
    // Release a key forwarded before opening; it must not remain stuck.
    KEY(0x84, 4, 0xf0, 0x1c); EXPECT_PS2(0xf0, 0x1c);
    KEY(4, 4, 0x1c); expect_text("a"); assert(ps2_count == 0);
    KEY(0x84, 4, 0xf0, 0x1c); expect_text(""); assert(ps2_count == 0);
    KEY(0x69, 1, 0x12); // LShift
    KEY(4, 4, 0x1c); expect_text("A"); assert(ps2_count == 0);
    KEY(0xe9, 1, 0xf0, 0x12);
    KEY(0x68, 0, 0x14); // LCtrl
    KEY(6, 6, 0x21); expect_text("\x03");
    KEY(0xe8, 0, 0xf0, 0x14);
    KEY(0x6a, 2, 0x11); // LAlt
    KEY(0x0d, 0x0d, 0x3b); assert(alt_key == 'j'); expect_text("");
    KEY(0xea, 2, 0xf0, 0x11);
    KEY(0x52, 0x52, 0xe0, 0x75); expect_text("\x1b[A");
    KEY(0x51, 0x51, 0xe0, 0x72); expect_text("\x1b[B");
    KEY(0x50, 0x50, 0xe0, 0x6b); expect_text("\x1b[D");
    KEY(0x4f, 0x4f, 0xe0, 0x74); expect_text("\x1b[C");
    KEY(0x3a, 0x3a, 5); expect_text("\x1b[11~"); assert(ps2_count == 0);
    KEY(0x28, 0x28, 0x5a); expect_text("\n");
    KEY(0x2a, 0x2a, 0x66); expect_text("\b");
    // A pending arrow sequence must unblock input_block(), too.
    const uint8_t arrow[] = {0xe0, 0x75};
    post(0x52, 0x52, arrow, sizeof(arrow));
    assert(input_block() == '\x1b'); expect_text("[A");
    // Native HID and SPI use the same console translator.
    native_key = 5; native_modifiers = 2;
    input_isr(EV_HID_KEY); expect_text("B");
    // Closing while Shift is held synchronizes the core modifier state.
    KEY(0x69, 1, 0x12); assert(ps2_count == 0);
    print_make(); assert(!(flags & OVERLAY_MASK)); EXPECT_PS2(0x12);
    print_break();
    KEY(0x84, 4, 0xf0, 0x1c); assert(ps2_count == 0); // Captured make has no core break.
    KEY(5, 5, 0x32); EXPECT_PS2(0x32);
    KEY(0x85, 5, 0xf0, 0x32); EXPECT_PS2(0xf0, 0x32);
    KEY(0xe9, 1, 0xf0, 0x12); EXPECT_PS2(0xf0, 0x12);
    // Pause resets once per make, and its header-only break rearms it.
    KEY(0x48, 0x48, 0xe1, 0x14, 0x77, 0xe1, 0xf0, 0x14, 0xf0, 0x77);
    assert(resets == 1 && ps2_count == 0);
    KEY(0x48, 0x48, 0xe1, 0x14, 0x77, 0xe1, 0xf0, 0x14, 0xf0, 0x77);
    assert(resets == 1);
    key(0xc8, 0x48, NULL, 0);
    print_make(); print_break(); assert(flags & OVERLAY_MASK);
    KEY(0x48, 0x48, 0xe1, 0x14, 0x77, 0xe1, 0xf0, 0x14, 0xf0, 0x77);
    assert(resets == 2 && ps2_count == 0);
    puts("PASS: overlay HID capture, modifiers, hotkeys, held-key transitions, native HID");
    return 0;
}
