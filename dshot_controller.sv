/*https://verilogguide.readthedocs.io/en/latest/verilog/package.html
https://nuttx.apache.org/docs/latest/os/drivers/character/timers/dshot.html
*/

package dshot_pkg;

	// DSHOT ESC communication protocol bitrates
    typedef enum logic [1:0] {
        DSHOT_150  = 2'b00, // 150  kbps
        DSHOT_300  = 2'b01, // 300  kbps
        DSHOT_600  = 2'b10, // 600  kbps
        DSHOT_1200 = 2'b11  // 1200 kbps
    } dshot_speed_t;
endpackage

import dshot_pkg::*; //compilation-unit level import of package containing DSHOT bitrates

module dshot_controller #(
    parameter int CLK_FREQ_HZ = 200_000_000 // Default clock frequency 200MHz
)(
    input logic         clk,   // system clock
    input logic         rst_n, // asynchronous reset, active low
	 
	// command interface
	input dshot_speed_t dshot_speed, // Protocol speed; latched right after reset
	input logic bidirectional_en,    // bidirectional communication enable; latched right after reset
    input logic         tx_start,    // send a DShot frame
    input logic [10:0]  throttle,    // 11-bit motor throttle value, 0 - 2047, values 0-47 are reserved
    input logic         req_telemetry, // req_telemetry bit sent in DShot frame

    // physical bidirectional pin
    inout logic         dshot_io,

    // Telemetry Receive Interface
    output logic [15:0] rx_data, // received data (includes eRPM) , only valid when rx_valid is asserted
    output logic        rx_valid, // received data is valid
    output logic        busy,	  // busy indicator flag
	output logic rx_crc_err, 	  // indicates received data has a CRC error
	output logic rx_timeout		  // indicates RX frame timeout
);
	// fsm states
	typedef enum logic [2:0] {
		GET_DSHOT_SPEED = 3'b000,
		IDLE            = 3'b001,
		TRANSMIT        = 3'b010,
		WAIT_RESP       = 3'b011,
		RECEIVE         = 3'b100,
		DECODE = 3'b101
	} fsm_state_t;
	
	localparam int MHZ_CLOCK = CLK_FREQ_HZ / 1_000_000; // clock frequency in MHz, compile-time constant
	
	
	// function to get number of c.c. for a rx timeout to occur
	function automatic int get_rx_timeout_cycles(input dshot_speed_t speed);
		int us_timeout;
		unique case (speed)
			DSHOT_150:  us_timeout = 150;
			DSHOT_300:  us_timeout = 80;
			DSHOT_600:  us_timeout = 40;
			DSHOT_1200: us_timeout = 25;
			default:    us_timeout = 80;
		endcase
		return MHZ_CLOCK * us_timeout;
	endfunction
	
	int rx_timeout_cycles_ff, rx_timeout_cycles_nxt; 	// Timeout cycle registers
	logic dshot_out_ff, dshot_out_nxt; 					// dshout signal output before tristate drivers
	logic dshot_oe_ff, dshot_oe_nxt;    				// dshot signal output enable : 1 -> enabled, 0 -> hiZ
	fsm_state_t state_ff, state_nxt;    				// fsm state registers
	logic [3:0] bit_idx_ff, bit_idx_nxt;				// contains bit index; indicates current bit being sent out of the 16-bit frame
	logic [4:0] rx_bit_idx_nxt, rx_bit_idx_ff;			// contains RX bit index; indicates current bit being read out of the 20-bit RX frame
	logic [15:0] dshot_frame_ff, dshot_frame_nxt;		// stores DShot frame to be sent
	logic bidirectional_en_ff, bidirectional_en_nxt;	// latched value of input bidirectional_en
	
	
	// three-stage input synchronizer to capture data from dshot_io
	logic rx_sync1_ff;
	logic rx_sync2_ff;
	logic rx_sync3_ff;
	
	logic [19:0] rx_shift_ff, rx_shift_nxt; //20-bit GCR received telemetry shift register
	
	
	logic rx_prev_ff, rx_prev_nxt;
	logic [15:0] rx_data_ff, rx_data_nxt;
	logic rx_valid_ff, rx_valid_nxt;
	logic rx_crc_err_ff, rx_crc_err_nxt, rx_timeout_ff, rx_timeout_nxt;
	assign rx_crc_err = rx_crc_err_ff;
	assign rx_timeout = rx_timeout_ff;

	
	assign rx_data  = rx_data_ff;
	assign rx_valid = rx_valid_ff;
	
	function automatic logic [3:0] calculate_dshot_crc(input logic [10:0] throttle, input logic req_telemetry);
		logic [11:0] packet;
		logic [3:0] crc;
    
		// Combine 11-bit throttle and 1-bit telemetry flag into a 12-bit value
		packet = {throttle, req_telemetry};
    
		// XOR nibbles: bits [11:8] ^ bits [7:4] ^ bits [3:0]
		crc = packet[11:8] ^ packet[7:4] ^ packet[3:0];
    
		// Invert the result to get the final 4-bit DShot CRC
		return bidirectional_en_ff? ~crc : crc;
	endfunction
	
	function automatic logic [4:0] gcr_dec(input logic [4:0] g);
		case (g)
			5'h19: return 5'h00;
			5'h1B: return 5'h01;
			5'h12: return 5'h02;
			5'h13: return 5'h03;
			5'h1D: return 5'h04;
			5'h15: return 5'h05;
			5'h16: return 5'h06;
			5'h17: return 5'h07;
			5'h1A: return 5'h08;
			5'h09: return 5'h09;
			5'h0A: return 5'h0A;
			5'h0B: return 5'h0B;
			5'h1E: return 5'h0C;
			5'h0D: return 5'h0D;
			5'h0E: return 5'h0E;
			5'h0F: return 5'h0F;
			default: return 5'h10;
		endcase
	endfunction
	
	assign dshot_io = dshot_oe_ff ? (dshot_out_ff ^ bidirectional_en_ff) : 1'bz;
	assign busy = (state_ff != IDLE);
	
	function automatic int bit_cycles(dshot_speed_t s);
		case (s)
			DSHOT_150:  return int'((longint'(CLK_FREQ_HZ) * 6670) / 1_000_000_000);
			DSHOT_300:  return int'((longint'(CLK_FREQ_HZ) * 3330) / 1_000_000_000);
			DSHOT_600:  return int'((longint'(CLK_FREQ_HZ) * 1670) / 1_000_000_000);
			DSHOT_1200: return int'((longint'(CLK_FREQ_HZ) *  835) / 1_000_000_000);
		endcase
	endfunction
	
	function automatic int rx_bit_cycles(dshot_speed_t s);
		return (bit_cycles(s) * 4) / 5; // 1.25x faster baud rate (4/5 period)
	endfunction
	
	
	localparam int CNT_W = $clog2(bit_cycles(DSHOT_150) + 1);
	localparam int TIMEOUT_W = CNT_W + 6; // Extra headroom for multi-bit timeouts

	logic [CNT_W-1:0] bit_cyc_ff, t0h_ff, t1h_ff, bit_cyc_nxt, t0h_nxt, t1h_nxt, rx_bit_cyc_ff, rx_bit_cyc_nxt;
	logic [TIMEOUT_W-1:0] counter_ff, counter_nxt;
	
	
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
		
			rx_timeout_cycles_ff <= MHZ_CLOCK * 150;
			
			
			dshot_out_ff <= 1'b0;
			dshot_oe_ff <= 1'b0;
			state_ff <= GET_DSHOT_SPEED;
			bit_idx_ff <= 4'd0;
			counter_ff <= '0;
			dshot_frame_ff <= 16'd0;
			bit_cyc_ff <= '0;
			t0h_ff     <= '0;
			t1h_ff     <= '0;
			rx_bit_cyc_ff <= '0;
			bidirectional_en_ff <= 1'b0;
			rx_sync1_ff <= 1'b1;
			rx_sync2_ff <= 1'b1;
			rx_sync3_ff <= 1'b1;
			rx_shift_ff <= '0;
			rx_prev_ff  <= 1'b0;
			rx_data_ff  <= '0;
			rx_valid_ff <= 1'b0;
			rx_bit_idx_ff <= '0;
			rx_crc_err_ff <= 1'b0;
			rx_timeout_ff <= 1'b0;
			

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
			rx_bit_cyc_ff <= rx_bit_cyc_nxt;

			rx_sync1_ff <= dshot_io;   // in else branch
			rx_sync2_ff <= rx_sync1_ff;
			rx_sync3_ff <= rx_sync2_ff;
			rx_shift_ff <= rx_shift_nxt;
			rx_prev_ff  <= rx_prev_nxt;
			rx_data_ff  <= rx_data_nxt;
			rx_valid_ff <= rx_valid_nxt;
			rx_bit_idx_ff <= rx_bit_idx_nxt;
			bidirectional_en_ff <= bidirectional_en_nxt;
			rx_crc_err_ff <= rx_crc_err_nxt;
			rx_timeout_ff <= rx_timeout_nxt;
			rx_timeout_cycles_ff <= rx_timeout_cycles_nxt;
		end
	end
	
	always_comb begin
		// hold previous values
		dshot_oe_nxt = dshot_oe_ff;
		state_nxt = state_ff;
		bit_idx_nxt = bit_idx_ff;
		dshot_frame_nxt = dshot_frame_ff;
		counter_nxt = counter_ff;
		dshot_out_nxt = dshot_out_ff;
		t1h_nxt = t1h_ff;
		t0h_nxt = t0h_ff;
		bit_cyc_nxt = bit_cyc_ff;
		rx_bit_cyc_nxt = rx_bit_cyc_ff;
		bidirectional_en_nxt = bidirectional_en_ff;
		rx_bit_idx_nxt = rx_bit_idx_ff;
		rx_shift_nxt = rx_shift_ff;
		rx_prev_nxt = rx_prev_ff;
		rx_data_nxt = rx_data_ff;
		
		
		rx_valid_nxt = 1'b0; 
		rx_crc_err_nxt = 1'b0;
		rx_timeout_nxt = 1'b0;
		rx_timeout_cycles_nxt = rx_timeout_cycles_ff;
		case(state_ff)
		
			GET_DSHOT_SPEED: begin
				bit_cyc_nxt = CNT_W'(bit_cycles(dshot_speed));
				rx_bit_cyc_nxt = CNT_W'(rx_bit_cycles(dshot_speed));
				t0h_nxt = CNT_W'((bit_cycles(dshot_speed) * 3) >> 3);
				t1h_nxt= CNT_W'((bit_cycles(dshot_speed) * 3) >> 2);
				bidirectional_en_nxt = bidirectional_en;
				state_nxt = IDLE;
				rx_timeout_cycles_nxt = get_rx_timeout_cycles(dshot_speed);
			end
		
		
			IDLE: begin
				dshot_oe_nxt = 1'b1;
				if (tx_start) begin
					state_nxt = TRANSMIT;
					bit_idx_nxt = 4'd15;
					counter_nxt = '0;
					dshot_out_nxt = 1'b1;
					dshot_frame_nxt = {throttle, req_telemetry, calculate_dshot_crc(throttle, req_telemetry)};
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
					if (counter_ff < t0h_ff - 1'b1) begin
						dshot_out_nxt = 1'b1;
					end else begin
						if (counter_ff < bit_cyc_ff) begin
							dshot_out_nxt = 1'b0;
						end
					end
				end

				if (counter_ff == bit_cyc_ff - 1) begin  
					counter_nxt = '0;
					
					if (bit_idx_ff != 0) 
						bit_idx_nxt = bit_idx_ff - 1'b1;
					else
						if (bidirectional_en_ff) begin
							state_nxt = WAIT_RESP; 
							dshot_oe_nxt = 1'b0;   
						end else begin
							state_nxt = IDLE;  
						end
				end
			end
			
			WAIT_RESP: begin
				dshot_oe_nxt = 1'b0;
				counter_nxt = counter_ff + 1'b1;
				
				if (rx_sync3_ff == 1'b0) begin
					state_nxt = RECEIVE;
					counter_nxt = '0;
					rx_bit_idx_nxt = 5'd19;
				end else
				
				if (counter_ff > rx_timeout_cycles_ff ) begin
					rx_timeout_nxt = 1'b1;
					state_nxt = IDLE;
					counter_nxt = '0;
				end
			end
			
			RECEIVE: begin
				dshot_oe_nxt = 1'b0;
				counter_nxt = counter_ff + 1'b1;

				if (counter_ff == (rx_bit_cyc_ff >> 1)) begin
					if (rx_bit_idx_ff == 5'd19) begin
						rx_prev_nxt = rx_sync3_ff;
					end else begin
						rx_shift_nxt = {rx_shift_ff[18:0], rx_sync3_ff ^ rx_prev_ff};
						rx_prev_nxt = rx_sync3_ff;
					end
				end

				if (counter_ff == rx_bit_cyc_ff - 1) begin
					counter_nxt = '0;
					if (rx_bit_idx_ff != 0)
						rx_bit_idx_nxt = rx_bit_idx_ff - 1'b1;
					else
						state_nxt = DECODE;
					end
				end

			DECODE: begin
				logic [4:0] d3, d2, d1, d0;
				logic [15:0] word;
				d3 = gcr_dec(rx_shift_ff[19:15]);
				d2 = gcr_dec(rx_shift_ff[14:10]);
				d1= gcr_dec(rx_shift_ff[9:5]);
				d0 = gcr_dec(rx_shift_ff[4:0]);
				word = {d3[3:0], d2[3:0], d1[3:0], d0[3:0]};
				if (!(d3[4] | d2[4] | d1[4] | d0[4]) && (word[3:0] == (~(word[15:12] ^ word[11:8] ^ word[7:4]) & 4'hF))) begin
					rx_data_nxt = word;
					rx_valid_nxt = 1'b1;
				end else begin
					rx_crc_err_nxt = 1'b1;
				end 
				state_nxt = IDLE;
			end
			
			default: begin
				state_nxt = IDLE;
			end	
		endcase
	end

endmodule

