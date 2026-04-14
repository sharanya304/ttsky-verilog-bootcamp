<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

UART–I2C bridge module. It receives serial data over UART and converts it into I2C transactions. Incoming UART bytes are decoded into I2C commands (start, address, read/write, data, stop). The UART operates asynchronously (start bit, 8 data bits, stop bit), while the I2C side generates SCL and SDA signals with proper start/stop conditions. SCL is generated internally from the system clock, and SDA is driven according to the I2C protocol (including ACK/NACK handling). The bridge manages the full transaction flow between UART input and I2C output.

## How to test

Provide UART data on the RX input to represent an I2C transaction. Observe SCL and SDA outputs using a logic analyzer. Verify correct start/stop conditions, data transmission, and ACK behavior. The busy signal indicates an active transfer.

## External hardware

Connect an I2C slave device (e.g., sensor or EEPROM) to SCL and SDA (with pull-up resistors). Provide UART input from a USB-to-serial interface or microcontroller.
