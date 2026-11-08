/*https://verilogguide.readthedocs.io/en/latest/verilog/package.html
https://nuttx.apache.org/docs/latest/os/drivers/character/timers/dshot.html
*/

typedef enum logic [1:0] {
    DSHOT_150  = 2'b00,
    DSHOT_300  = 2'b01,
    DSHOT_600  = 2'b10,
    DSHOT_1200 = 2'b11
} dshot_speed_t;


module dshot_controller #(
    parameter int CLK_FREQ_HZ = 200_000_000 // Default clock frequency 200MHz
)(
    input logic         clk,   // system clock
    input logic         rst_n, // asynchronous reset, active low

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

	logic dshot_out_ff, dshot_out_nxt;
	logic dshot_oe_ff, dshot_oe_nxt;
	logic [2:0] state_ff, state_nxt;
	logic [3:0] bit_idx_ff, bit_idx_nxt;
	logic [9:0] counter_ff, counter_nxt;
	logic [15:0] dshot_frame_ff, dshot_frame_nxt;
	
	assign dshot_io = dshot_oe_ff ? dshot_out_ff : 1'bz;

	function automatic int bit_ns(dshot_rate_e r);
		case (r)
			DSHOT150:  return 6670;
			DSHOT300:  return 3330;
			DSHOT600:  return 1670;
			DSHOT1200: return 835;
		endcase
	endfunction


	// Timing parameters calculated dynamically based on CLK_FREQ_HZ
    localparam int BIT_CYCLES_DSHOT600 = int'((longint'(CLK_FREQ_HZ) * 1670) / 1_000_000_000); // Overall bit period (TH + TL) = 1670ns
	
    localparam int T0H_CYCLES_DSHOT600 = int'((longint'(CLK_FREQ_HZ) *  630) / 1_000_000_000); // Logic ‘0’ high is 630ns
    localparam int T0L_CYCLES_DSHOT600 = int'((longint'(CLK_FREQ_HZ) * 1040) / 1_000_000_000); // Logic ‘0’ low is 1040ns
	
    localparam int T1H_CYCLES = int'((longint'(CLK_FREQ_HZ) * 1250) / 1_000_000_000); // Logic ‘1’ high is 1250ns
    localparam int T1L_CYCLES = int'((longint'(CLK_FREQ_HZ) *  420) / 1_000_000_000); // Logic ‘1’ low is 420ns
	
	
	
	
	
	typedef enum logic [2:0] {
		IDLE     = 3'b000,
		TRANSMIT = 3'b001
	} fsm_state_t;
	
	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			dshot_out_ff <= 1'b0;
			dshot_oe_ff <= 1'b1;
			state_ff <= IDLE;
			bit_idx_ff <= 4'd0;
			counter_ff <= 10'd0;
			dshot_frame_ff <= 16'd0;
		end else begin
			dshot_out_ff <= dshot_out_nxt;
			dshot_oe_ff <= dshot_oe_nxt;
			state_ff <= state_nxt;
			counter_ff <= counter_nxt;
			dshot_frame_ff <= dshot_frame_nxt;
			bit_idx_ff <= bit_idx_nxt;
		end
	end
	
	always_comb begin
		dshot_oe_nxt = dshot_oe_ff;
		state_nxt = state_ff;
		bit_idx_nxt = bit_idx_ff;
		dshot_frame_nxt = dshot_frame_ff;
		counter_nxt = counter_ff;
		dshot_out_nxt = dshot_out_ff;
		
		case(state_ff)
			IDLE: begin
				dshot_oe_nxt = 1'b0;
				if (tx_start) begin
					state_nxt = TRANSMIT;
					bit_idx_nxt = 4'd15;
					counter_nxt = 10'd0;
					dshot_oe_nxt = 1'b0;
					dshot_out_nxt = 1'b0;
					dshot_frame_nxt = {throttle, 5'd0};
				end
			end
			
			TRANSMIT: begin
				counter_nxt = counter_ff + 1'b1;
				dshot_oe_nxt = 1'b1;
				
				if (dshot_frame_ff[bit_idx_ff] == 1'b1) begin
					if (counter_ff < T1H_CYCLES) begin
						dshot_out_nxt = 1'b1;
					end else begin
						if (counter_ff < BIT_CYCLES) begin
							dshot_out_nxt = 1'b0;
						end
					end
				end else begin
					if (counter_ff < T0H_CYCLES) begin
						dshot_out_nxt = 1'b1;
					end else begin
						if (counter_ff < BIT_CYCLES) begin
							dshot_out_nxt = 1'b0;
						end
					end
				end



				if (counter_ff == BIT_CYCLES - 1) begin
				    
					counter_nxt = 0;
					
					if (bit_idx_ff != 0) bit_idx_nxt = bit_idx_ff - 1'b1;
					
					if (bit_idx_ff == 0) 
						state_nxt = IDLE;
				end
				

			end
		endcase
	end

endmodule
