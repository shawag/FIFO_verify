`timescale 1ns / 1ps

module Tb_Async_FIFO ();

parameter        INPUT_WIDTH       = 64;
//The width parameter for reading data
parameter        OUTPUT_WIDTH      = 64;
//The depth parameter of writing mem,if INPUT_WIDTH < 
parameter        WR_DEPTH          = 1024;
//The depth parameter of reading mem,if INPUT_WIDTH > 
parameter        RD_DEPTH          = 1024;
//The parameter of reading method
parameter        MODE              = "Standard";
//Is data stored from high bits or from low bits
parameter        DIRECTION         = "MSB";
//Set error correction function,INPUT_WIDTH must equal
parameter        ECC_MODE          = "no_ecc";
//Specify the value of the programmable null threshold
parameter        PROG_EMPTY_THRESH = 10;
//Specify the value of programmable full threshold
parameter        PROG_FULL_THRESH  = 10;
//Enable the corresponding signal
//USE_ADV_FEATURES[0]：拉高，可使用overflow；
//USE_ADV_FEATURES[1]：拉高，可使用prog_full；
//USE_ADV_FEATURES[3]：拉高，可使用almost_full；
//USE_ADV_FEATURES[8]：拉高，可使用underflow；
//USE_ADV_FEATURES[9]：拉高，可使用prog_empty；
//USE_ADV_FEATURES[11]：拉高，可使用almost_empty；
parameter [15:0] USE_ADV_FEATURES  = 16'h0B0B;

parameter  WR_CLOCK_FREQ = 40e6;
parameter  RD_CLOCK_FREQ = 30e6;
parameter  SAMPLE_CLOCK_FREQ = 1e9;

integer seed;
int                     fsdbDump        ;

    
logic                    wr_clk;
logic                    wr_rst_n;
    
logic                    rd_clk;
logic                    rd_rst_n;

logic					 sample_clk;
logic                    wr_clk_r        ;
logic                    rd_clk_r        ;
wire                     wr_clk_rise     ;
wire                     rd_clk_rise     ;


    
logic   [INPUT_WIDTH-1:0] wdata_array[$];
logic   [OUTPUT_WIDTH-1:0] rdata_array[$];

logic                    wren;
logic                    rden;

logic   [INPUT_WIDTH-1:0] wdata;
wire    [OUTPUT_WIDTH-1:0] rdata;
wire                       rddata_valid;
wire                       wrdata_ready;

wire                       fifo_full;
wire                       fifo_empty;
wire                       fifo_almost_full;
wire                       fifo_almost_empty;
wire                       fifo_prog_full;
wire                       fifo_prog_empty;

logic                      sample_full;
logic                      sample_empty;

wire                       overflow;
wire                       underflow;

wire                       wr_ack;

wire [$clog2(WR_DEPTH) : 0] wr_data_count;

wire [$clog2(WR_DEPTH) : 0] wr_data_space;

wire [$clog2(RD_DEPTH) : 0] rd_data_count;

wire [$clog2(RD_DEPTH) : 0] rd_data_space;


integer                    wr_cnt;
integer                    rd_cnt;
integer                    cnt;

int                        file1;
int                        file2;

initial    $timeformat(-9, 3, " ns", 0);
initial begin
	if (!$value$plusargs("seed=%d", seed))
		seed = 100;
	$srandom(seed);
	$display("seed = %d\n", seed);

	if(!$value$plusargs("fsdbDump=%d",fsdbDump))
		fsdbDump = 1;
	if (fsdbDump) begin
		$fsdbDumpfile("tb.fsdb");
		$fsdbDumpvars(0);
		$fsdbDumpMDA("tb.u_afifo.my_memory");
	end
end

initial begin
    sample_clk = 1'b0;
	$display("%t:sample_clock is activated, period is %0d Hz", $time,SAMPLE_CLOCK_FREQ);
    forever begin
        #(1e9/(2*SAMPLE_CLOCK_FREQ)) sample_clk = ~sample_clk;
    end
end

initial begin
    wr_clk = 1'b0;
	$display("%t:wr_clock is activated, period is %0d Hz", $time,WR_CLOCK_FREQ);
    forever begin
        #(1e9/(2*WR_CLOCK_FREQ)) wr_clk = ~wr_clk;
    end
end

initial begin
    rd_clk = 1'b0;
	$display("%t:wr_clock is activated, period is %0d Hz", $time,RD_CLOCK_FREQ);
    forever begin
        #(1e9/(2*RD_CLOCK_FREQ)) rd_clk = ~rd_clk;
    end
end

initial begin
	wr_rst_n = 0;
	#30 wr_rst_n = 1;
end

initial begin
	rd_rst_n     = 0;
	#40 rd_rst_n = 1;
end

initial begin
	wr_clk_r = 0;   

	forever begin
		@(posedge sample_clk);
		if (wr_clk)
			#0.1 wr_clk_r = 1;
		else
			#0.1 wr_clk_r = 0;
	end
end


initial begin
	rd_clk_r = 0;   

	forever begin
		@(posedge sample_clk);
		if (rd_clk)
			#0.1 rd_clk_r = 1;
		else
			#0.1 rd_clk_r = 0;
	end
end


assign wr_clk_rise = wr_clk & ~wr_clk_r;
assign rd_clk_rise = rd_clk & ~rd_clk_r;

initial begin
	wren = 1'b0;
	rden = 1'b0;
	wdata = 0;
	wr_cnt = 0;
	rd_cnt = 0;
	sample_full = 0;
	sample_empty = 0;

	@(posedge rd_rst_n);

	forever begin
		@(posedge sample_clk);
		if(rd_cnt > 1e3)
			break;
		
		fork
			begin
				if(wr_clk_rise) begin
					sample_full = fifo_full;
					#1;
					wren = {$random(seed)} %2;

					if(~(sample_full) & wren) begin
						wdata_array[wr_cnt] = {$random(seed)} %(2048);
						wdata = wdata_array[wr_cnt];
						wr_cnt = wr_cnt + 1;
					end
					else
					    wren = 0;
				end
			end

			begin
				if(rd_clk_rise) begin
					sample_empty = fifo_empty;
					if(rddata_valid) begin
						rdata_array[rd_cnt] = rdata;
						rd_cnt = rd_cnt + 1;
					end
					#1;
					rden = {$random(seed)} %2;
					if(~(~(sample_empty) &rden))
						rden = 0;
				end
			end
		join
	end
	file1 = $fopen("wdata.txt", "w");
	file2 = $fopen("rdata.txt", "w");
	for(cnt=0;cnt<rd_cnt;cnt=cnt+1) begin
		if(rdata_array[cnt] != wdata_array[cnt])
			$display("ERROR: address is %0d",cnt);
		$fdisplay(file1,"%x",wdata_array[cnt]);
		$fdisplay(file2,"%x",rdata_array[cnt]);
	end
	$fclose(file1);
	$fclose(file2);
	
	$finish;
end



async_fifo #(
	.INPUT_WIDTH       	( INPUT_WIDTH       ),
	.OUTPUT_WIDTH      	( OUTPUT_WIDTH        ),
	.WR_DEPTH          	( WR_DEPTH      ),
	.RD_DEPTH          	( RD_DEPTH      ),
	.MODE              	( MODE    ),
	.DIRECTION         	( DIRECTION     ),
	.ECC_MODE          	( ECC_MODE  ),
	.PROG_EMPTY_THRESH 	( PROG_EMPTY_THRESH        ),
	.PROG_FULL_THRESH  	( PROG_FULL_THRESH        ),
	.USE_ADV_FEATURES  	( USE_ADV_FEATURES    ))
u_async_fifo(
	.reset         	( ~wr_rst_n      ),
	.wr_clock      	( wr_clk       ),
	.wr_en         	( wren          ),
	.wr_ready      	( wr_ready       ),
	.din           	( wdata            ),
	.rd_clock      	( rd_clk       ),
	.rd_en         	( rden          ),
	.valid         	( rddata_valid          ),
	.dout          	( rdata           ),
	.full          	( fifo_full           ),
	.empty         	( fifo_empty          ),
	.wr_data_count 	( wr_data_count  ),
	.wr_data_space 	( wr_data_space  ),
	.rd_data_count 	( rd_data_count  ),
	.rd_data_space 	( rd_data_space  ),
	.almost_full   	( fifo_almost_full    ),
	.almost_empty  	( fifo_almost_empty   ),
	.prog_full     	( prog_full      ),
	.prog_empty    	( prog_empty     ),
	.overflow      	( overflow       ),
	.underflow     	( underflow      ),
	.wr_ack        	( wr_ack         )
);


    
endmodule //Tb_Async_FIFO
