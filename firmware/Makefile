# Firmware for the Guition ESP32-S3-4848S040 desk panel.
# Requires PlatformIO Core (`brew install platformio` or `pip install platformio`).
#
# Before the first build, create your secrets header:
#   cp include/secrets.h.example include/secrets.h   # then edit WiFi + BRIDGE_URL

PIO := pio
SECRETS := include/secrets.h

.PHONY: build flash install monitor clean secrets

# Compile the firmware.
build: $(SECRETS)
	$(PIO) run

# Build + upload to a connected board over USB (CH340 serial).
flash install: $(SECRETS)
	$(PIO) run -t upload

# Open the serial monitor (115200 baud).
monitor:
	$(PIO) device monitor

clean:
	$(PIO) run -t clean

# Scaffold secrets.h from the example on first build if it is missing.
$(SECRETS):
	@echo "include/secrets.h is missing — creating it from the example."
	@echo "Edit it with your WiFi credentials and bridge URL, then rebuild."
	@cp include/secrets.h.example $(SECRETS)
	@false
