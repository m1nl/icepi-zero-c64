#ifndef MAIN_H
#define MAIN_H

#define C64_RAM_BASE 0x41800000
#define C64_RAM_SIZE 0xFFFF

#define C64_AR_BASE 0x41840000
#define C64_AR_SIZE 0xFFFF
#define C64_AR_PATH "/c64_roms/ar6_pal.bin"

#define FLAGS_JSON_PATH "/c64_flags.json"
#define FLAGS_JSON_MAX 1024

#define FLAG_CIA_MODEL 0
#define FLAG_SID_MODEL 1
#define FLAG_SID_DUAL 2
#define FLAG_SID_PAN 3
#define FLAG_SID_AUTO_MONO 4
#define FLAG_VA_DELAY 5
#define FLAG_OVERLAY 6
#define FLAG_JOY_INVERT 7
#define FLAG_JOY_BUTTON_SPACE 8
#define FLAG_JOY_KEYBOARD_CONTROL 9
#define FLAG_JOY_EMULATION_0 10
#define FLAG_JOY_EMULATION_1 11
#define FLAG_CART_PRESENT 12
#define FLAG_IEC_MASTER_DISCONNECT 13

enum {
    COMMAND_HELP = 0,
    COMMAND_REBOOT,
    COMMAND_SDCARD_RESET,
    COMMAND_LS,
    COMMAND_HEXDUMP,
    COMMAND_MOUNT,
    COMMAND_UMOUNT,
    COMMAND_SYNC,
    COMMAND_FORMAT,
    COMMAND_TAPE_LOAD,
    COMMAND_TAPE_EJECT,
    COMMAND_FLAGS,
    COMMAND_FLAG,
    COMMAND_CONSOLE,
    COMMAND_C64_RESET,
    COMMAND_C64_PAUSE,
    COMMAND_C64_RESUME,
    COMMAND_POWER,
    COMMAND_MAX
};

const char *commands[COMMAND_MAX] = {"help",   "reboot",  "sdcard_reset", "ls",        "hexdump",    "mount",
                                     "umount", "sync",    "format",       "tape_load", "tape_eject", "flags",
                                     "flag",   "console", "reset",        "pause",     "resume",     "power"};

const struct {
    const char *name;
    int bit;
    const char *desc;
} flag_defs[] = {
    {"cia_model", 0, "CIA model: 0=6526, 1=8521"},
    {"sid_model", 1, "SID model: 0=6581, 1=8580"},
    {"sid_dual", 2, "Dual SID: 0=single, 1=dual"},
    {"sid_pan", 3, "Apply Dual SID pan correction"},
    {"sid_auto_mono", 4, "Auto-mono if 2nd SID is idle"},
    {"va_delay", 5, "VA14/VA15 glitch delay (U14 emulation)"},
    {"overlay", 6, "Video terminal overlay enable"},
    {"joy_invert", 7, "Invert joystick ports"},
    {"joy_button_space", 8, "Joystick fire button maps to Space"},
    {"joy_keyboard_control", 9, "Joysticks mapped as keyboard"},
    {"joy_emulation_0", 10, "Joystick port 1 keyboard emulation"},
    {"joy_emulation_1", 11, "Joystick port 2 keyboard emulation"},
    {"cart_present", 12, "Cartridge present"},
    {"iec_master_disconnect", 13, "Disconnect C64 from IEC bus"},
};

#define FLAG_DEFS_COUNT ((int)(sizeof(flag_defs) / sizeof(flag_defs[0])))

#endif /* MAIN_H */
