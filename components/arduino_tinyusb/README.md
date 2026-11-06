# arduino_tinyusb (for the framework rebuild)

pioarduino rebuilds the ESP-IDF libraries when `custom_sdkconfig` is set in
platformio.ini, but it has no copy of Arduino's TinyUSB component (that lives
in esp32-arduino-lib-builder, not the component registry). Without it the
rebuilt framework has no `CONFIG_TINYUSB_*` settings, and USB (the serial log,
the USB drive, keyboard and mouse) compiles out. This folder puts it back.

Taken from the versions the prebuilt framework lists in its versions.txt:

- `CMakeLists.txt`, `Kconfig.projbuild`, `include/`: esp32-arduino-lib-builder
  6671d0b, `components/arduino_tinyusb/`
- `tinyusb/`: hathach/tinyusb 88c7f0b81 with lib-builder's
  `patches/tinyusb/0001-host-esp32s2s3-lowspeed-hub.diff` applied. Only `src/`
  (portable drivers other than synopsys/dwc2 removed), `hw/bsp/*` top-level
  files and LICENSE are kept.

The class settings (which TinyUSB classes are built, buffer sizes) are
`CONFIG_TINYUSB_*` lines in platformio.ini's `custom_sdkconfig`.
