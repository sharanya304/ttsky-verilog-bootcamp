<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

SPI Mode 0 master. Transmits 8 bits MSB-first on MOSI, toggling SCLK
(idle low, sample on rising edge). SS_n is asserted low for the duration
of the transfer. SCLK runs at clk/4 (2.5 MHz at 10 MHz system clock).

## How to test

Set `ui_in[7:0]` to the byte you want to transmit.
Pulse `uio_in[0]` (start) high for one clock cycle.
Monitor `uo_out[1]` (SCLK) and `uo_out[0]` (MOSI) on a logic analyser.
`uo_out[3]` (busy) goes high for the duration of the transfer.
`uo_out[2]` (ss_n) goes low during the transfer.

## External hardware

SPI slave device: connect MOSI, SCLK, SS_n to the slave.
