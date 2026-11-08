/*https://verilogguide.readthedocs.io/en/latest/verilog/package.html
https://nuttx.apache.org/docs/latest/os/drivers/character/timers/dshot.html
*/
package dshot_pkg;
    typedef enum logic [1:0] {
        DSHOT_150  = 2'b00,
        DSHOT_300  = 2'b01,
        DSHOT_600  = 2'b10,
        DSHOT_1200 = 2'b11
    } dshot_speed_t;
endpackage

import dshot_pkg::*;

module dshot_controller #(
    parameter int CLK_FREQ_HZ = 200_000_000 // Default clock frequency 200MHz
)(
    input logic         clk,   // system clock
    input logic         rst_n, // asynchronous reset, active low
	input dshot_speed_t dshot_speed,
    // command interface
    input logic         tx_start,
    input logic [10:0]  throttle,
    input logic         req_telemetry,

    // physical bidirectional pin
    inout logic         dshot_io,

    // Telemetry Receive Interface
    output logic [15:0] rx_data,
    output logic        rx_valid,
    output logic        busy
);
	typedef enum logic [2:0] {
		GET_DSHOT_SPEED = 3'b000,
		IDLE            = 3'b001,
		TRANSMIT        = 3'b010
	} fsm_state_t;
	
	logic dshot_out_ff, dshot_out_nxt;
	logic dshot_oe_ff, dshot_oe_nxt;
	fsm_state_t state_ff, state_nxt;
	logic [3:0] bit_idx_ff, bit_idx_nxt;
	logic [15:0] dshot_frame_ff, dshot_frame_nxt;
	
	assign dshot_io = dshot_oe_ff ? dshot_out_ff : 1'bz;
	
	function automatic int bit_cycles(dshot_speed_t s);
		case (s)
			DSHOT_150:  return int'((longint'(CLK_FREQ_HZ) * 6670) / 1_000_000_000);
			DSHOT_300:  return int'((longint'(CLK_FREQ_HZ) * 3330) / 1_000_000_000);
			DSHOT_600:  return int'((longint'(CLK_FREQ_HZ) * 1670) / 1_000_000_000);
			DSHOT_1200: return int'((longint'(CLK_FREQ_HZ) *  835) / 1_000_000_000);
		endcase
	endfunction
	
	localparam int CNT_W = $clog2(bit_cycles(DSHOT_150) + 1);

	logic [CNT_W-1:0] bit_cyc_ff, t0h_ff, t1h_ff, bit_cyc_nxt, t0h_nxt, t1h_nxt;
	logic [CNT_W-1:0] counter_ff, counter_nxt;

	

	
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			dshot_out_ff <= 1'b0;
			dshot_oe_ff <= 1'b0;
			state_ff <= GET_DSHOT_SPEED;
			bit_idx_ff <= 4'd0;
			counter_ff <= '0;
			dshot_frame_ff <= 16'd0;
			bit_cyc_ff <= '0;
			t0h_ff     <= '0;
			t1h_ff     <= '0;
		end else begin
			dshot_out_ff <= dshot_out_nxt;
			dshot_oe_ff <= dshot_oe_nxt;
			state_ff <= state_nxt;
			counter_ff <= counter_nxt;
			dshot_frame_ff <= dshot_frame_nxt;
			bit_idx_ff <= bit_idx_nxt;
			bit_cyc_ff <= bit_cyc_nxt;
			t0h_ff     <= t0h_nxt;
			t1h_ff     <= t1h_nxt;
		end
	end
	
	always_comb begin
		dshot_oe_nxt = dshot_oe_ff;
		state_nxt = state_ff;
		bit_idx_nxt = bit_idx_ff;
		dshot_frame_nxt = dshot_frame_ff;
		counter_nxt = counter_ff;
		dshot_out_nxt = dshot_out_ff;
		t1h_nxt = t1h_ff;
		t0h_nxt = t0h_ff;
		bit_cyc_nxt = bit_cyc_ff;
		
		case(state_ff)
		
			GET_DSHOT_SPEED: begin
				bit_cyc_nxt = CNT_W'(bit_cycles(dshot_speed));
				t0h_nxt = CNT_W'((bit_cycles(dshot_speed) * 3) >> 3);
				t1h_nxt= CNT_W'((bit_cycles(dshot_speed) * 3) >> 2);
				state_nxt = IDLE;
			end
		
		
			IDLE: begin
				dshot_oe_nxt = 1'b0;
				if (tx_start) begin
					state_nxt = TRANSMIT;
					bit_idx_nxt = 4'd15;
					counter_nxt = '0;
					dshot_out_nxt = 1'b0;
					dshot_frame_nxt = {throttle, 5'd0};
				end
			end
			
			TRANSMIT: begin
				counter_nxt = counter_ff + 1'b1;
				dshot_oe_nxt = 1'b1;
				
				if (dshot_frame_ff[bit_idx_ff] == 1'b1) begin
					if (counter_ff < t1h_ff) begin
						dshot_out_nxt = 1'b1;
					end else begin
						if (counter_ff < bit_cyc_ff) begin
							dshot_out_nxt = 1'b0;
						end
					end
				end else begin
					if (counter_ff < t0h_ff) begin
						dshot_out_nxt = 1'b1;
					end else begin
						if (counter_ff < bit_cyc_ff) begin
							dshot_out_nxt = 1'b0;
						end
					end
				end

				if (counter_ff == bit_cyc_ff - 1) begin  
					counter_nxt = '0;	
					if (bit_idx_ff != 0) bit_idx_nxt = bit_idx_ff - 1'b1;
					if (bit_idx_ff == 0) 
						state_nxt = IDLE;
				end
			end
			
			default begin
				state_nxt = IDLE;
			end	
		endcase
	end

endmodule
