import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


@cocotb.test()
async def test_c1541_gcr_basic(dut):
    clock = Clock(dut.clk, 31.25, unit="ns")
    cocotb.start_soon(clock.start())

    dut.reset.value = 1
    dut.ce.value = 0
    dut.din.value = 0xFF
    dut.mode.value = 1
    dut.mtr.value = 1
    dut.freq.value = 0
    dut.track.value = 30
    dut.busy.value = 0
    dut.wps_n.value = 1
    dut.img_mounted.value = 0
    dut.disk_id.value = 0xAB

    dut.buff_dout.value = 0xDE

    await ClockCycles(dut.clk, 10)

    dut.reset.value = 0

    ce_state = 0
    count = 0
    for cycle in range(400000):
        await RisingEdge(dut.clk)
        dut.ce.value = ce_state
        ce_state = 1 - ce_state

        count += 1

        if count == 9300:
            dut.din.value = 0x55
        if count == 10500:
            dut.din.value = 0xFB
        if count == 380000:
            dut.din.value = 0xFF
