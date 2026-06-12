# esp-gyrologger for M5StickC Plus2

Port of [VladimirP1/esp-gyrologger](https://github.com/VladimirP1/esp-gyrologger) (branch `lcd_st7789`) to the **M5StickC Plus2**.

## What changed from the original

| Feature | Plus (original) | Plus2 (this port) |
|---|---|---|
| Power IC | AXP192 (I²C) | SGM2578 — GPIO4 must be held HIGH |
| Display DC | GPIO23 | GPIO14 |
| Display RST | GPIO18 | GPIO12 |
| Display backlight | AXP192 LDO3 | GPIO27 (active HIGH) |
| Battery voltage | AXP192 register | GPIO38 (ADC1 channel 2) |
| Display type setting | 3 | **5** |

## Build & Flash

```bash
chmod +x build_plus2.sh && ./build_plus2.sh
./firmware/flash_plus2.sh
```

## After flashing — set in `/settings`

| Setting | Value |
|---|---|
| `display_type` | **5** |
| `sda_pin` | **21** |
| `scl_pin` | **22** |
| `btn_pin` | **37** |
| `led_pin` | **19** |

## Usage

- **Power on** — hold Button C (side) 2 seconds
- **Start/stop logging** — Button A (front)
- **Download files** — connect to `esplog-XXXX` WiFi → `http://192.168.4.1`
- **Power off** — hold Button C 6 seconds
