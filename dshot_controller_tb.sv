// Code your testbench here
// or browse Examples
`timescale 1ns / 1ps
module dshot_controller_tb();
	import dshot_pkg::*;

	logic rst_n, esc_rst_n;
	logic clk, clk_120Mhz;
	wire dshot_io;
	logic tx_start;
	dshot_speed_t dshot_speed;
			pullup(dshot_io);
	initial begin
		dshot_speed = DSHOT_1200;
		rst_n = 1'b0;
		esc_rst_n = 1'b0;
		clk = 1'b0;
		clk_120Mhz = 1'b0;
		tx_start = 1;

		#10;
		
		rst_n = 1'b1;
		#30
		esc_rst_n = 1'b1;
		#1000000;
		$stop;
	end
	
	always begin
		#2.5 clk =~clk;
	end
	
	always begin 
		#4.16 clk_120Mhz =~clk_120Mhz;
	end
	
	dshot_controller #(
		.CLK_FREQ_HZ(200_000_000) 
	) dut (
		.clk (clk),
		.rst_n(rst_n),
		.dshot_speed(dshot_speed),
		.bidirectional_en(1'b1),
		.tx_start(tx_start),
		.throttle(11'b10101010101),
		.req_telemetry(1'b1),
		.dshot_io(dshot_io),
		.rx_data(),
		.rx_valid(),
		.busy(),
		.rx_crc_err(), 
		.rx_timeout()
	);
	
	dshot_esc_model #(
	    .CLK_FREQ_HZ(120_000_000)
	) esc_dut (
		.clk (clk_120Mhz),
	    .rst_n(esc_rst_n),
		.dshot_io(dshot_io),
		.target_period_us(1000),
		.received_throttle(),
		.received_req_telem(),
		.frame_valid(),
		.detected_speed()
	);
  /*
  initial begin
          $dumpfile("dump.vcd"); $dumpvars;
  end*/
endmodule
