// ---------------------------------------------------------------------------
// Copyright 2026 Mateusz Nalewajski
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: GPL-3.0-or-later
// ---------------------------------------------------------------------------

#include <stdio.h>
#include <stdint.h>

#include <libbase/i2c.h>

#include "power.h"

#define INA219_ADDR             0x43

#define INA219_REG_CONFIG       0x00
#define INA219_REG_SHUNTVOLTAGE 0x01
#define INA219_REG_BUSVOLTAGE   0x02
#define INA219_REG_POWER        0x03
#define INA219_REG_CURRENT      0x04
#define INA219_REG_CALIBRATION  0x05

#define INA219_CAL_VALUE        26868
#define INA219_CURRENT_LSB_PA   152400
#define INA219_POWER_LSB_UW     3048
#define INA219_CONFIG_VALUE     0xEEF

static int ina219_write_reg(uint8_t reg, uint16_t value)
{
    uint8_t buf[2];
    buf[0] = (value >> 8) & 0xFF;
    buf[1] = value & 0xFF;
    return i2c_write(INA219_ADDR, reg, buf, 2, 1);
}

static int ina219_read_reg(uint8_t reg, uint16_t *value)
{
    uint8_t buf[2];
    if (!i2c_read(INA219_ADDR, reg, buf, 2, true, 1))
        return 0;
    *value = ((uint16_t)buf[0] << 8) | buf[1];
    return 1;
}

static int ina219_init(void)
{
    if (!ina219_write_reg(INA219_REG_CALIBRATION, INA219_CAL_VALUE))
        return 0;
    if (!ina219_write_reg(INA219_REG_CONFIG, INA219_CONFIG_VALUE))
        return 0;
    return 1;
}

int power_report(void)
{
    uint16_t raw;
    int64_t sraw;
    int bus_mv, shunt_uv, current_ma, power_mw;

    if (!ina219_init()) {
        printf("power: INA219 not found at 0x%02x\n", INA219_ADDR);
        return -1;
    }

    if (!ina219_write_reg(INA219_REG_CALIBRATION, INA219_CAL_VALUE)) {
        printf("power: calibration write failed\n");
        return -1;
    }

    if (!ina219_read_reg(INA219_REG_BUSVOLTAGE, &raw)) {
        printf("power: bus voltage read failed\n");
        return -1;
    }
    sraw = (int64_t)raw;
    bus_mv = ((int)(raw >> 3)) * 4;

    if (!ina219_read_reg(INA219_REG_SHUNTVOLTAGE, &raw)) {
        printf("power: shunt voltage read failed\n");
        return -1;
    }
    sraw = (int64_t)raw;
    shunt_uv = ((int)sraw * 10);

    if (!ina219_write_reg(INA219_REG_CALIBRATION, INA219_CAL_VALUE)) {
        printf("power: calibration write failed\n");
        return -1;
    }

    if (!ina219_read_reg(INA219_REG_CURRENT, &raw)) {
        printf("power: current read failed\n");
        return -1;
    }
    sraw = (int64_t)raw;
    if (sraw > 32767)
        sraw -= 65535;
    current_ma = ((int)(sraw * (int64_t)INA219_CURRENT_LSB_PA) / 1000000);

    if (!ina219_read_reg(INA219_REG_POWER, &raw)) {
        printf("power: power read failed\n");
        return -1;
    }
    sraw = (int64_t)raw;
    if (sraw > 32767)
        sraw -= 65535;
    power_mw = ((int)(sraw * (int64_t)INA219_POWER_LSB_UW) / 1000);

    printf("Battery Voltage: %d.%03d V\n", bus_mv / 1000, bus_mv % 1000);
    printf("Shunt Voltage:   %d.%03d mV\n", shunt_uv / 1000, shunt_uv % 1000);
    printf("Current:         %d mA\n", current_ma);
    printf("Power:           %d mW\n", power_mw);

    return 0;
}
