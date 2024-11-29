`timescale 1ns / 1ps
//Date : 2024-11-14
//Author :shawg
//Module Name: [File Name] - [Module Name]
//Target Device: [Target FPGA or ASIC Device]
//Tool versions: [EDA Tool Version]
//Revision Historyc :
//Revision :
//    Revision 0.01 - File Created
//Description :A brief description of what the module does. Describe its
//             functionality, inputs, outputs, and any important behavior.
//
//Dependencies:
//         List any modules or files this module depends on, or any
//            specific conditions required for this module to function 
//             correctly.
//	
//Company : ncai Technology .Inc
//Copyright(c) 1999, ncai Technology Inc, All right reserved
//
//wavedom

`timescale 1ns / 1ps
//`define VCS_SIM 
module Tb_Sync_FIFO ();

parameter        INPUT_WIDTH       = 64;
//The width parameter for reading data
parameter        OUTPUT_WIDTH      = 64;
//The depth parameter of writing mem,if INPUT_WIDTH < OUTPUT_WIDTH, WR_DEPTH = (OUTPUT_WIDTH/INPUT_WIDTH) * RD_DEPTH
parameter        WR_DEPTH          = 1024;
//The depth parameter of reading mem,if INPUT_WIDTH > OUTPUT_WIDTH, RD_DEPTH = (INPUT_WIDTH/OUTPUT_WIDTH) * WR_DEPTH
parameter        RD_DEPTH          = 1024;
//The parameter of reading method
parameter        MODE              = "Standard";
//Is data stored from high bits or from low bits
parameter        DIRECTION         = "MSB";
//Set error correction function,INPUT_WIDTH must equal to OUTPUT_WIDTH
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

parameter CLOCK_FREQ = 40e6;

integer                     seed;
`ifdef VCS_SIM
int                         fsdbDump;
`endif
logic                       clk;
logic                       rst;

logic                       wren;
logic                       wr_ready;
logic [INPUT_WIDTH-1:0]     wdata;

logic                       rden;
wire  [OUTPUT_WIDTH-1:0]    rdata;
wire                        rddata_valid;

wire                        fifo_full;
wire                        fifo_empty;

logic                       sample_full;
logic                       sample_empty;

wire                        fifo_almost_full;
wire                        fifo_almost_empty;

wire                        prog_full;
wire                        prog_empty;

wire                        overflow;
wire                        underflow;

wire                        wr_ack;

wire                        sbiterr;
wire                        dbiterr;

wire [$clog2(WR_DEPTH) : 0] wr_data_count;

wire [$clog2(WR_DEPTH) : 0] wr_data_space;

wire [$clog2(RD_DEPTH) : 0] rd_data_count;

wire [$clog2(RD_DEPTH) : 0] rd_data_space;



logic [INPUT_WIDTH-1:0]     wdata_array[ $];
logic [OUTPUT_WIDTH-1:0]    rdata_array[ $];

integer                     wr_cnt;
integer                     wr_data_cnt;
integer                     rd_cnt;
integer                     rd_data_cnt;
integer                     cnt;

int                         file_wr;
int                         file_rd;

//setting format of time reporting
initial     $timeformat(-9, 3, "ns", 0);
initial begin
    if(!$value$plusargs("seed=%d", seed))
        seed = 100;
    `ifdef VCS_SIM
        $srandom(seed); 
    `endif
    $display("seed = %d\n", seed);

    `ifdef VCS_SIM
    if(!$value$plusargs("fsdbDump = %d", fsdbDump))
        fsdbDump = 1;
    if(fsdbDump) begin
        $fsdbDumpfile("Tb_Sync_FIFO.fsdb");
        $fsdbDumpvar(0);
        $fsdbDumpMDA("Tb_Sync_FIFO.u_Sync_FIFO.fifo_ram");
    end
    `endif
end

initial begin
    clk = 1'b0;
    $display("%t:clock is activated, period is %0d Hz", $time,CLOCK_FREQ);
    forever begin
        #(1e9/(2*CLOCK_FREQ)) clk = ~clk;
    end
end

initial begin
    rst = 1'b1;
    #30
    rst = 1'b0;
    $display("%t:reset high finish", $time);
end

task wr_data_fun_ver;
begin
    if(wr_data_cnt <= WR_DEPTH)
        wr_data_cnt = wr_data_cnt + 1;
    else
        wr_data_cnt = 0;
    if(wr_data_cnt != wr_data_count)
        $display("%t:wr_data_cnt = %0d, wr_data_count = %0d", $time,wr_data_cnt,wr_data_count);
    if(wr_data_cnt + wr_data_space != WR_DEPTH)
        $display("%t:wr_data_cnt + wr_data_space = %0d", $time, wr_data_cnt + wr_data_space);
end
endtask

task rd_data_fun_ver;
begin
    if(rd_data_cnt <= RD_DEPTH)
        rd_data_cnt = rd_data_cnt + 1;
    else
        rd_data_cnt = 0;
    if(rd_data_cnt != rd_data_count)
        $display("%t:rd_data_cnt = %0d, rd_data_count = %0d", $time,rd_data_cnt,rd_data_count);
    if(rd_data_cnt + rd_data_space != RD_DEPTH)
        $display("%t:rd_data_cnt + rd_data_space = %0d", $time, rd_data_cnt + rd_data_space);
end
endtask

initial begin
    wren = 1'b0;
    rden = 1'b0;
    wdata = 0;
    wr_data_cnt = 0;
    wr_cnt = 0;
    rd_cnt = 0;
    rd_data_cnt = 0;
    cnt=0;
    sample_full = 0;
    sample_empty = 0;

    @(negedge rst);

    repeat(1e4) begin
        @(posedge clk);
        sample_full = fifo_full;
        sample_empty = fifo_empty;

        if(rddata_valid) begin
            rdata_array[rd_cnt] = rdata;
            rd_cnt = rd_cnt + 1;
//            rd_data_fun_ver;
        end

        #1
        wren = 0;
        if(rden)
        rden = 0;

        wren = {$random(seed)} %2;
        rden = {$random(seed)} %2;

        if((~sample_full) & wren) begin
            wdata_array[wr_cnt] = {$random(seed)} %(2**INPUT_WIDTH);
            wdata = wdata_array[wr_cnt];
            wr_cnt = wr_cnt + 1;
 //           wr_data_fun_ver;
        end
        else
            wren = 0;

        if(~(~sample_empty & rden))
            rden = 0;    
    end
    file_wr = $fopen("wdata.txt", "w");
    file_rd = $fopen("rdata.txt", "w");
    for (cnt=0;cnt<rd_cnt;cnt=cnt+1) begin
        if(rdata_array[cnt] != wdata_array[cnt])
            $display("ERROR: address is %0d",cnt);

        $fdisplay(file_wr,"%x",wdata_array[cnt]);
        $fdisplay(file_rd,"%x",rdata_array[cnt]); 
    end
    $fclose(file_wr);
    $fclose(file_rd);

    $finish;
end


sync_fifo #(
	.INPUT_WIDTH       	( INPUT_WIDTH       ),
	.OUTPUT_WIDTH      	( OUTPUT_WIDTH        ),
	.WR_DEPTH          	( WR_DEPTH      ),
	.RD_DEPTH          	( RD_DEPTH      ),
	.MODE              	( MODE    ),
	.DIRECTION         	( DIRECTION    ),
	.ECC_MODE          	( ECC_MODE  ),
	.PROG_EMPTY_THRESH 	( PROG_EMPTY_THRESH        ),
	.PROG_FULL_THRESH  	( PROG_FULL_THRESH        ),
	.USE_ADV_FEATURES  	( USE_ADV_FEATURES  ))
u_sync_fifo(
	.clock         	( clk              ),
	.reset         	( rst              ),
	.wr_en         	( wren             ),
	.wr_ready      	( wr_ready         ),
	.din           	( wdata            ),
	.rd_en         	( rden             ),
	.valid         	( rddata_valid     ),
	.dout          	( rdata            ),
	.full          	( fifo_full        ),
	.empty         	( fifo_empty       ),
	.wr_data_count 	( wr_data_count    ),
	.wr_data_space 	( wr_data_space    ),
	.rd_data_count 	( rd_data_count    ),
	.rd_data_space 	( rd_data_space    ),
	.almost_full   	( fifo_almost_full ),
	.almost_empty  	( ),
	.prog_full     	( prog_full        ),
	.prog_empty    	( prog_empty       ),
	.overflow      	( overflow         ),
	.underflow     	( underflow        ),
	.wr_ack        	( wr_ack           ),
	.sbiterr       	( sbiterr          ),
	.dbiterr       	( dbiterr          )
);

    
endmodule //moduleName
