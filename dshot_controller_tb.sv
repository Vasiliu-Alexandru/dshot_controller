// Code your testbench here
// or browse Examples
`timescale 1ns / 1ps
module dshot_controller_tb();
	import dshot_pkg::*;

	logic rst_n;
	logic clk;
	wire dshot_io;
	logic tx_start;
	dshot_speed_t dshot_speed;
	
	initial begin
		dshot_speed = DSHOT_300;
		rst_n = 1'b0;
		clk = 1'b0;
		tx_start = 1;
		#10;
		rst_n = 1'b1;
		#1000000;
		$stop;
	end
	
	always begin
		#5 clk =~clk;
	end
	
	dshot_controller #(
		.CLK_FREQ_HZ(100_000_000) 
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
		.busy()
	);
  /*
  initial begin
          $dumpfile("dump.vcd"); $dumpvars;
  end*/
endmodule
