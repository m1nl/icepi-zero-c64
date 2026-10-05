#ifndef SPI_HID_H
#define SPI_HID_H

#include <stdint.h>

typedef void (*spi_hid_key_handler)(uint8_t event, uint8_t usage, const uint8_t *ps2, uint8_t length);

void spi_hid_init(void);
void spi_hid_isr(void);
void spi_hid_service(spi_hid_key_handler handle_key);

#endif
