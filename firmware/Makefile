include $(BUILD_DIR)/software/include/generated/variables.mak
include $(SOC_DIRECTORY)/software/common.mak

LIBS := $(filter-out liblitesdcard libfatfs,$(LIBS))
PACKAGES := $(filter-out liblitesdcard libfatfs,$(PACKAGES))

OBJECTS = crt0.o main.o embedded_cli.o heap.o tlsf.o spisdcard.o ff.o ffunicode.o ffsystem.o input.o c64_disk.o c64_tape.o power.o strstr.o
CFLAGS += -Os -flto

all: icepi-zero-c64.bin

%.bin: %.elf
	$(OBJCOPY) -O binary $< $@
ifneq ($(OS),Windows_NT)
	chmod -x $@
endif

vpath %.a $(PACKAGES:%=../%)

icepi-zero-c64.elf: $(OBJECTS)
	$(CC) $(LDFLAGS) -T linker.ld -N -o $@ \
		$(OBJECTS) \
		$(PACKAGES:%=-L$(BUILD_DIR)/software/%) \
		-Wl,--start-group \
		$(LIBS:lib%=-l%) \
		-Wl,--end-group \
		-Wl,--gc-sections \
		-Wl,-Map,$@.map

ifneq ($(OS),Windows_NT)
	chmod -x $@
endif

# pull in dependency info for *existing* .o files
-include $(OBJECTS:.o=.d)

tlsf.o: CFLAGS += -U__GNUC__

VPATH = $(BIOS_DIRECTORY):$(BIOS_DIRECTORY)/cmds:$(CPU_DIRECTORY)

%.o: %.cpp
	$(compilexx)

%.o: %.c
	$(compile)

%.o: %.S
	$(assemble)

clean:
	$(RM) $(OBJECTS) icepi-zero-c64.elf icepi-zero-c64.bin .*~ *~

.PHONY: all clean
