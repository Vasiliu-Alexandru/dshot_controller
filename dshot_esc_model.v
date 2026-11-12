import dshot_pkg::*;

module dshot_esc_model #(
  parameter int CLK_FREQ_HZ = 120_000_000
)(
  input logic clk,
  input logic rst_n,
  inout logic dshot_io,
  input logic [31:0] target_period_us,

  output logic [10:0] received_throttle,
  output logic 	      received_req_telem,
  output logic        frame_valid,
  output dshot_speed_t detected_speed
);
  
  function automatic int rx_bit_cycles(dshot_speed_t s);
    case (s)
      DSHOT_150:  return int'((longint'(CLK_FREQ_HZ) * 6670) / 1_000_000_000);
      DSHOT_300:  return int'((longint'(CLK_FREQ_HZ) * 3330) / 1_000_000_000);
      DSHOT_600:  return int'((longint'(CLK_FREQ_HZ) * 1670) / 1_000_000_000);
      DSHOT_1200: return int'((longint'(CLK_FREQ_HZ) *  835) / 1_000_000_000);
    endcase
  endfunction
	
  function automatic int tx_bit_cycles(dshot_speed_t s);
    return (rx_bit_cycles(s) * 4) / 5; // 1.25x faster baud rate (4/5 period)
  endfunction
  
  
  localparam int MAX_BIT_TIMER_CYCLES = (rx_bit_cycles(DSHOT_150) * 12) / 10;
  localparam int MHZ_CLOCK = CLK_FREQ_HZ / 1_000_000; // clock frequency in MHz, compile-time constant
  
  localparam int IDLE_THRESHOLD_CYCLES = MHZ_CLOCK * 4;

  typedef enum logic [3:0] {
    WAIT_FOR_IDLE           = 4'b0000,
    DETECT_BITRATE               = 4'b0001,
    DETECT_BITRATE_BIDIRECTIONAL = 4'b0010,
    DETERMINE_DSHOT_SPEED   = 4'b0011,
    WAIT_FOR_FRAME          = 4'b0100,
    SEND_TELEMETRY          = 4'b0101
  } fsm_state_t;

  logic [$clog2(IDLE_THRESHOLD_CYCLES):0] idle_timer_ff, idle_timer_nxt;


  fsm_state_t state_ff, state_nxt;
  logic dshot_out_ff, dshot_out_nxt;
  logic dshot_oe_ff, dshot_oe_nxt;
  logic rx_sync1, rx_sync2, rx_sync3, rx_sync4;
  logic received_throttle_ff, received_throttle_nxt;
  assign received_throttle = received_throttle_ff;
  logic [$clog2(MAX_BIT_TIMER_CYCLES)-1:0] bit_timer_ff, bit_timer_nxt;
  logic edge_count_nxt, edge_count_ff;
  dshot_speed_t detected_speed_ff , detected_speed_nxt;
  
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_ff <= WAIT_FOR_IDLE;
      dshot_out_ff <= 1'b0;
      dshot_oe_ff <= 1'b0;
      rx_sync1 <= 1'b0;
      rx_sync2 <= 1'b0;
      rx_sync3 <= 1'b0;
      rx_sync4 <= 1'b0;
      received_throttle_ff <= 11'd0;
edge_count_ff <= 1'b0;
      idle_timer_ff <= '0;
bit_timer_ff <= '0;
detected_speed_ff <= UNDEFINED;
    end else begin
      state_ff <= state_nxt;
      dshot_out_ff <= dshot_out_nxt;
      dshot_oe_ff <= dshot_oe_nxt;
      rx_sync1 <= dshot_io;
      rx_sync2 <= rx_sync1;
      rx_sync3 <= rx_sync2;
      rx_sync4 <= rx_sync3;
      received_throttle_ff <= received_throttle_nxt;
      bit_timer_ff <= bit_timer_nxt;
      edge_count_ff <= edge_count_nxt;
	  detected_speed_ff <= detected_speed_nxt;
	  idle_timer_ff <= idle_timer_nxt;
  end
end
  assign dshot_io = dshot_oe_ff ? dshot_out_ff : 1'bz;



  
  always_comb begin
    state_nxt = state_ff;
    dshot_out_nxt = dshot_out_ff;
    dshot_oe_nxt = dshot_oe_ff;
    received_throttle_nxt = received_throttle_ff;
	idle_timer_nxt = idle_timer_ff;
bit_timer_nxt = bit_timer_ff;
edge_count_nxt = edge_count_ff;
detected_speed_nxt = detected_speed_ff;
    case(state_ff)

     WAIT_FOR_IDLE: begin
        

        if ((rx_sync4 ^ rx_sync3) ==1'b1) begin
          idle_timer_nxt = '0;
        end else begin
          idle_timer_nxt = idle_timer_ff + 1'b1;
        end

        // Wait for exactly 4us of NO edges
        if (idle_timer_ff == IDLE_THRESHOLD_CYCLES) begin
          if (rx_sync4 == 1'b1) begin
            state_nxt = DETECT_BITRATE_BIDIRECTIONAL; // Line idles high
          end else begin
            state_nxt = DETECT_BITRATE;               // Line idles low
          end
        end 
      end

DETECT_BITRATE: begin
      if (~rx_sync4 && rx_sync3) begin 
        // We detected a RISING edge!
        
        if (edge_count_ff == 1'b0) begin
          // First detected rising edge (start of bit 1)
          bit_timer_nxt = 1; 
          edge_count_nxt = 1'b1;
        end else begin
          // Second rising edge (the bit has finished transmitting)
          
          if (bit_timer_ff <= (rx_bit_cycles(DSHOT_1200) + (rx_bit_cycles(DSHOT_1200)/5))) begin
            detected_speed_nxt = DSHOT_1200;
            state_nxt = WAIT_FOR_FRAME;
            
          end else if (bit_timer_ff <= (rx_bit_cycles(DSHOT_600) + (rx_bit_cycles(DSHOT_600)/5))) begin
            detected_speed_nxt = DSHOT_600;
            state_nxt = WAIT_FOR_FRAME;
            
          end else if (bit_timer_ff <= (rx_bit_cycles(DSHOT_300) + (rx_bit_cycles(DSHOT_300)/5))) begin
            detected_speed_nxt = DSHOT_300;
            state_nxt = WAIT_FOR_FRAME;
            
          end else if (bit_timer_ff <= (rx_bit_cycles(DSHOT_150) + (rx_bit_cycles(DSHOT_150)/5))) begin
            detected_speed_nxt = DSHOT_150;
            state_nxt = WAIT_FOR_FRAME;
            
          end else begin
            // ERROR: The pulse was longer than DShot150 + 20%. 
            // This is an invalid frame or noise. Abort and start over.
            state_nxt = WAIT_FOR_IDLE;
          end
        end

      end else if (edge_count_ff == 1'b1) begin
        // The line is holding steady between the first and second edge. Count up!
        bit_timer_nxt = bit_timer_ff + 1'b1;
      end
    end

    DETECT_BITRATE_BIDIRECTIONAL: begin
      if (rx_sync4 && ~rx_sync3) begin 
	    // we detected a falling edge
		if (edge_count_ff == 1'b0) begin
		// first detected falling edge
			bit_timer_nxt = 1; // start the timer
			edge_count_nxt = 1'b1;
		end else begin
		// second falling edge	(the bit has finished transmitting)
		

if (bit_timer_ff <= (rx_bit_cycles(DSHOT_1200) + (rx_bit_cycles(DSHOT_1200)/5))) begin
              detected_speed_nxt = DSHOT_1200;
              state_nxt = WAIT_FOR_FRAME;
              
            end else if (bit_timer_ff <= (rx_bit_cycles(DSHOT_600) + (rx_bit_cycles(DSHOT_600)/5))) begin
              detected_speed_nxt = DSHOT_600;
              state_nxt = WAIT_FOR_FRAME;
              
            end else if (bit_timer_ff <= (rx_bit_cycles(DSHOT_300) + (rx_bit_cycles(DSHOT_300)/5))) begin
              detected_speed_nxt = DSHOT_300;
              state_nxt = WAIT_FOR_FRAME;
              
            end else if (bit_timer_ff <= (rx_bit_cycles(DSHOT_150) + (rx_bit_cycles(DSHOT_150)/5))) begin
              detected_speed_nxt = DSHOT_150;
              state_nxt = WAIT_FOR_FRAME;
              
            end else begin
              // ERROR: The pulse was longer than DShot150 + 20%. 
              // This is an invalid frame or noise. Abort and start over.
              state_nxt = WAIT_FOR_IDLE;
            end
		end
	 end else begin
		if (bit_timer_ff != 0)
			bit_timer_nxt = bit_timer_ff + 1'b1;
	  end
	   
    end
	

	
    endcase
  end
  
  assign detected_speed = detected_speed_ff;
endmodule
