//-----------------------------------------------------------------------
//Filename         : axi_read_tester_top.sv
//Description      : SystemVerilog wrapper for the axi_read_tester_top
//                 : integration.  The arrayed ports (AXI4-Lite slaves, LEDs,
//                 : native masters) are packed with the index in the OUTER
//                 : dimension; this wrapper reverses the outer dimension so
//                 : SV index j maps to VHDL index j (same idiom as
//                 : axi_ar_mux_top.sv).  Every AXI4-Lite slave index is an
//                 : independent interface; the highest index (16 with the
//                 : default generics) is the local global axilite_io.  The
//                 : integration logic (local axilite, global_time counter,
//                 : pulse_extender aperture, stat_rst/err_rst pulses) lives
//                 : in the VHDL top, which this wrapper instantiates
//                 : (mixed-language binding).
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module axi_read_tester_top #(
    parameter int unsigned GC_NUM_TESTERS       = 4,
    parameter int unsigned GC_NUM_CLIENTS       = 4,
    parameter int unsigned GC_ADDR_WIDTH        = 32,
    parameter int unsigned GC_ID_WIDTH          = 4,
    parameter int unsigned GC_CLIENT_DATA_BYTES = 64,
    parameter int unsigned GC_NATIVE_DATA_BYTES = 16,
    parameter int unsigned GC_NATIVE_ARLEN_WIDTH = 8,
    parameter int unsigned GC_MAX_BURST         = 32,
    parameter int unsigned GC_CLIENT_FIFO_DEPTH = 32,
    parameter int unsigned GC_CDC_DEPTH         = 8,
    parameter int unsigned GC_SYNC_STAGES       = 2,
    parameter int unsigned GC_MON_SB_DEPTH      = 256,
    parameter int unsigned GC_MON_TIME_WIDTH    = 48,
    parameter int unsigned GC_PULSE_LEN         = 1024
) (
    input  logic             aclk,
    input  logic             mem_aclk,
    input  logic             aresetn,

    // Arrayed AXI4-Lite slaves: index 0..N_T*N_C-1 = client axilite_io
    // (tester t, client c -> t*N_C+c), index N_T*N_C = local axilite_io.
    input  logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0][15:0] s_axi_awaddr,
    input  logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0][2:0]  s_axi_awprot,
    input  logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0]       s_axi_awvalid,
    output logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0]       s_axi_awready,
    input  logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0][31:0] s_axi_wdata,
    input  logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0][3:0]  s_axi_wstrb,
    input  logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0]       s_axi_wvalid,
    output logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0]       s_axi_wready,
    output logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0][1:0]  s_axi_bresp,
    output logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0]       s_axi_bvalid,
    input  logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0]       s_axi_bready,
    input  logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0][15:0] s_axi_araddr,
    input  logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0][2:0]  s_axi_arprot,
    input  logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0]       s_axi_arvalid,
    output logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0]       s_axi_arready,
    output logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0][31:0] s_axi_rdata,
    output logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0][1:0]  s_axi_rresp,
    output logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0]       s_axi_rvalid,
    input  logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0]       s_axi_rready,

    // Combined LEDs: index 0..N_TESTERS*N_CLIENTS-1 = per-client LEDs,
    // highest index = local axilite LED.
    output logic [GC_NUM_TESTERS*GC_NUM_CLIENTS:0] led,

    // Native AXI read masters, one per tester
    output logic [GC_NUM_TESTERS-1:0][GC_ID_WIDTH-1:0]            ar_id,
    output logic [GC_NUM_TESTERS-1:0][GC_ADDR_WIDTH-1:0]          ar_addr,
    output logic [GC_NUM_TESTERS-1:0][GC_NATIVE_ARLEN_WIDTH-1:0]  ar_len,
    output logic [GC_NUM_TESTERS-1:0][2:0]                        ar_size,
    output logic [GC_NUM_TESTERS-1:0]                             ar_valid,
    input  logic [GC_NUM_TESTERS-1:0]                             ar_ready,
    input  logic [GC_NUM_TESTERS-1:0][GC_ID_WIDTH-1:0]            r_id,
    input  logic [GC_NUM_TESTERS-1:0][8*GC_NATIVE_DATA_BYTES-1:0] r_data,
    input  logic [GC_NUM_TESTERS-1:0][1:0]                        r_resp,
    input  logic [GC_NUM_TESTERS-1:0]                             r_last,
    input  logic [GC_NUM_TESTERS-1:0]                             r_valid,
    output logic [GC_NUM_TESTERS-1:0]                             r_ready
);

    localparam int unsigned C_LAST   = GC_NUM_TESTERS * GC_NUM_CLIENTS;     // 16
    localparam int unsigned C_AXIL_W = GC_NUM_TESTERS * GC_NUM_CLIENTS + 1; // 17

    // Reversed internal vectors feeding the VHDL integration top.
    logic [C_AXIL_W-1:0][15:0] s_axi_awaddr_v;
    logic [C_AXIL_W-1:0][2:0]  s_axi_awprot_v;
    logic [C_AXIL_W-1:0]       s_axi_awvalid_v;
    logic [C_AXIL_W-1:0]       s_axi_awready_v;
    logic [C_AXIL_W-1:0][31:0] s_axi_wdata_v;
    logic [C_AXIL_W-1:0][3:0]  s_axi_wstrb_v;
    logic [C_AXIL_W-1:0]       s_axi_wvalid_v;
    logic [C_AXIL_W-1:0]       s_axi_wready_v;
    logic [C_AXIL_W-1:0][1:0]  s_axi_bresp_v;
    logic [C_AXIL_W-1:0]       s_axi_bvalid_v;
    logic [C_AXIL_W-1:0]       s_axi_bready_v;
    logic [C_AXIL_W-1:0][15:0] s_axi_araddr_v;
    logic [C_AXIL_W-1:0][2:0]  s_axi_arprot_v;
    logic [C_AXIL_W-1:0]       s_axi_arvalid_v;
    logic [C_AXIL_W-1:0]       s_axi_arready_v;
    logic [C_AXIL_W-1:0][31:0] s_axi_rdata_v;
    logic [C_AXIL_W-1:0][1:0]  s_axi_rresp_v;
    logic [C_AXIL_W-1:0]       s_axi_rvalid_v;
    logic [C_AXIL_W-1:0]       s_axi_rready_v;
    logic [GC_NUM_TESTERS-1:0][GC_ID_WIDTH-1:0]            ar_id_v;
    logic [GC_NUM_TESTERS-1:0][GC_ADDR_WIDTH-1:0]          ar_addr_v;
    logic [GC_NUM_TESTERS-1:0][GC_NATIVE_ARLEN_WIDTH-1:0]  ar_len_v;
    logic [GC_NUM_TESTERS-1:0][2:0]                        ar_size_v;
    logic [GC_NUM_TESTERS-1:0]                             ar_valid_v;
    logic [GC_NUM_TESTERS-1:0]                             ar_ready_v;
    logic [GC_NUM_TESTERS-1:0][GC_ID_WIDTH-1:0]            r_id_v;
    logic [GC_NUM_TESTERS-1:0][8*GC_NATIVE_DATA_BYTES-1:0] r_data_v;
    logic [GC_NUM_TESTERS-1:0][1:0]                        r_resp_v;
    logic [GC_NUM_TESTERS-1:0]                             r_last_v;
    logic [GC_NUM_TESTERS-1:0]                             r_valid_v;
    logic [GC_NUM_TESTERS-1:0]                             r_ready_v;
    logic [C_LAST:0]                                       led_v;

    genvar t;
    genvar i;
    generate
        for (i = 0; i <= C_LAST; i++) begin : g_rev_axil
            assign s_axi_awaddr_v[C_LAST - i]  = s_axi_awaddr[i];
            assign s_axi_awprot_v[C_LAST - i]  = s_axi_awprot[i];
            assign s_axi_awvalid_v[C_LAST - i] = s_axi_awvalid[i];
            assign s_axi_awready[i] = s_axi_awready_v[C_LAST - i];
            assign s_axi_wdata_v[C_LAST - i]   = s_axi_wdata[i];
            assign s_axi_wstrb_v[C_LAST - i]   = s_axi_wstrb[i];
            assign s_axi_wvalid_v[C_LAST - i]  = s_axi_wvalid[i];
            assign s_axi_wready[i] = s_axi_wready_v[C_LAST - i];
            assign s_axi_bresp[i] = s_axi_bresp_v[C_LAST - i];
            assign s_axi_bvalid[i] = s_axi_bvalid_v[C_LAST - i];
            assign s_axi_bready_v[C_LAST - i]  = s_axi_bready[i];
            assign s_axi_araddr_v[C_LAST - i]  = s_axi_araddr[i];
            assign s_axi_arprot_v[C_LAST - i]  = s_axi_arprot[i];
            assign s_axi_arvalid_v[C_LAST - i] = s_axi_arvalid[i];
            assign s_axi_arready[i] = s_axi_arready_v[C_LAST - i];
            assign s_axi_rdata[i] = s_axi_rdata_v[C_LAST - i];
            assign s_axi_rresp[i] = s_axi_rresp_v[C_LAST - i];
            assign s_axi_rvalid[i] = s_axi_rvalid_v[C_LAST - i];
            assign s_axi_rready_v[C_LAST - i]  = s_axi_rready[i];
        end
        for (t = 0; t < GC_NUM_TESTERS; t++) begin : g_rev
            assign ar_id_v[GC_NUM_TESTERS-1-t]    = ar_id[t];
            assign ar_addr_v[GC_NUM_TESTERS-1-t]  = ar_addr[t];
            assign ar_len_v[GC_NUM_TESTERS-1-t]   = ar_len[t];
            assign ar_size_v[GC_NUM_TESTERS-1-t]  = ar_size[t];
            assign ar_valid_v[GC_NUM_TESTERS-1-t] = ar_valid[t];
            assign ar_ready[t] = ar_ready_v[GC_NUM_TESTERS-1-t];
            assign r_id_v[GC_NUM_TESTERS-1-t]     = r_id[t];
            assign r_data_v[GC_NUM_TESTERS-1-t]   = r_data[t];
            assign r_resp_v[GC_NUM_TESTERS-1-t]   = r_resp[t];
            assign r_last_v[GC_NUM_TESTERS-1-t]   = r_last[t];
            assign r_valid_v[GC_NUM_TESTERS-1-t]  = r_valid[t];
            assign r_ready[t] = r_ready_v[GC_NUM_TESTERS-1-t];
        end
        for (t = 0; t <= C_LAST; t++) begin : g_rev_led
            assign led[t] = led_v[C_LAST - t];
        end
    endgenerate

    // Instantiates the VHDL axi_read_tester_top integration core.
    axi_read_tester_top #(
        .GC_NUM_TESTERS       (GC_NUM_TESTERS),
        .GC_NUM_CLIENTS       (GC_NUM_CLIENTS),
        .GC_ADDR_WIDTH        (GC_ADDR_WIDTH),
        .GC_ID_WIDTH          (GC_ID_WIDTH),
        .GC_CLIENT_DATA_BYTES (GC_CLIENT_DATA_BYTES),
        .GC_NATIVE_DATA_BYTES (GC_NATIVE_DATA_BYTES),
        .GC_NATIVE_ARLEN_WIDTH (GC_NATIVE_ARLEN_WIDTH),
        .GC_MAX_BURST         (GC_MAX_BURST),
        .GC_CLIENT_FIFO_DEPTH (GC_CLIENT_FIFO_DEPTH),
        .GC_CDC_DEPTH         (GC_CDC_DEPTH),
        .GC_SYNC_STAGES       (GC_SYNC_STAGES),
        .GC_MON_SB_DEPTH      (GC_MON_SB_DEPTH),
        .GC_MON_TIME_WIDTH    (GC_MON_TIME_WIDTH),
        .GC_PULSE_LEN         (GC_PULSE_LEN)
    ) u_core (
        .aclk  (aclk),
        .mem_aclk     (mem_aclk),
        .aresetn      (aresetn),
        .s_axi_awaddr (s_axi_awaddr_v),
        .s_axi_awprot (s_axi_awprot_v),
        .s_axi_awvalid(s_axi_awvalid_v),
        .s_axi_awready(s_axi_awready_v),
        .s_axi_wdata  (s_axi_wdata_v),
        .s_axi_wstrb  (s_axi_wstrb_v),
        .s_axi_wvalid (s_axi_wvalid_v),
        .s_axi_wready (s_axi_wready_v),
        .s_axi_bresp  (s_axi_bresp_v),
        .s_axi_bvalid (s_axi_bvalid_v),
        .s_axi_bready (s_axi_bready_v),
        .s_axi_araddr (s_axi_araddr_v),
        .s_axi_arprot (s_axi_arprot_v),
        .s_axi_arvalid(s_axi_arvalid_v),
        .s_axi_arready(s_axi_arready_v),
        .s_axi_rdata  (s_axi_rdata_v),
        .s_axi_rresp  (s_axi_rresp_v),
        .s_axi_rvalid (s_axi_rvalid_v),
        .s_axi_rready (s_axi_rready_v),
        .led      (led_v),
        .ar_id    (ar_id_v),
        .ar_addr  (ar_addr_v),
        .ar_len   (ar_len_v),
        .ar_size  (ar_size_v),
        .ar_valid (ar_valid_v),
        .ar_ready (ar_ready_v),
        .r_id     (r_id_v),
        .r_data   (r_data_v),
        .r_resp   (r_resp_v),
        .r_last   (r_last_v),
        .r_valid  (r_valid_v),
        .r_ready  (r_ready_v)
    );

endmodule
