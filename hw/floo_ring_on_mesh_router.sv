// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Michael Rogenmoser <michaero@iis.ee.ethz.ch>

`include "common_cells/assertions.svh"
`include "common_cells/registers.svh"

/// A simple router with configurable number of ports, physical and virtual channels, and input/output buffers
/// Extended for ring on mesh multicasting
module floo_ring_on_mesh_router
  import floo_pkg::*;
#(
  parameter int unsigned NumRoutes        = 0,
  parameter int unsigned NumVirtChannels  = 0,
  parameter int unsigned NumPhysChannels  = 1,
  parameter int unsigned NumNodes         = 16,
  parameter type         flit_t           = logic,
  parameter int unsigned InFifoDepth      = 0,
  parameter int unsigned OutFifoDepth     = 0,
  parameter route_algo_e RouteAlgo        = IdTable,
  /// Used for ID-based and XY routing
  parameter int unsigned IdWidth          = 0,
  parameter type         id_t             = logic[IdWidth-1:0],
  /// Used for ID-based routing
  parameter int unsigned NumAddrRules     = 1,
  parameter type         addr_rule_t      = logic,
  /// Configuration parameters for special network topologies
  parameter int unsigned NumInput         = NumRoutes,
  parameter int unsigned NumOutput        = NumRoutes,
  parameter bit          XYRouteOpt       = 1'b0, //disable xy route opt for ring connections
  parameter bit          NoLoopback       = 1'b1
) (
  input  logic                                       clk_i,
  input  logic                                       rst_ni,
  input  logic                                       test_enable_i,

  input  id_t                                        xy_id_i,        // if unused assign to '0
  input  addr_rule_t [NumAddrRules-1:0]              id_route_map_i, // if unused assign to '0

  input  logic [$clog2(NumNodes)-1:0]                ring_on_mesh_id_i,
  input  logic [$clog2(NumRoutes)-1:0]               ring_on_mesh_up_port_i,
  input  logic [$clog2(NumRoutes)-1:0]               ring_on_mesh_down_port_i,

  input  logic  [NumInput-1:0][NumVirtChannels-1:0]  valid_i, // NOT AXI, requires ready first
  output logic  [NumInput-1:0][NumVirtChannels-1:0]  ready_o, // NOT AXI, requires ready first
  input  flit_t [NumInput-1:0][NumPhysChannels-1:0]  data_i,

  output logic  [NumOutput-1:0][NumVirtChannels-1:0] valid_o, // NOT AXI, requires ready first
  input  logic  [NumOutput-1:0][NumVirtChannels-1:0] ready_i, // NOT AXI, requires ready first
  output flit_t [NumOutput-1:0][NumPhysChannels-1:0] data_o
);

  // TODO MICHAERO: assert NumPhysChannels <= NumVirtChannels

  flit_t [NumInput-1:0][NumVirtChannels-1:0] in_data, in_routed_data;
  logic  [NumInput-1:0][NumVirtChannels-1:0] in_valid, in_ready;

  logic  [NumInput-1:0][NumVirtChannels-1:0][NumOutput-1:0] route_mask;

  // Router input part
  for (genvar in_route = 0; in_route < NumInput; in_route++) begin : gen_input
    for (genvar v_chan = 0; v_chan < NumVirtChannels; v_chan++) begin : gen_virt_input

      logic [cf_math_pkg::idx_width(NumPhysChannels)-1:0] in_phys_channel;
      if (NumPhysChannels == 1) begin : gen_single_phys
        assign in_phys_channel = '0;
      end else if (NumPhysChannels == NumVirtChannels) begin : gen_virt_eq_phys
        assign in_phys_channel = v_chan;
      end else begin : gen_odd_phys
        $fatal(1, "unimplemented");
      end

      (* ungroup *)
      stream_fifo_optimal_wrap #(
        .Depth  ( InFifoDepth ),
        .type_t ( flit_t      )
      ) i_stream_fifo (
        .clk_i      ( clk_i         ),
        .rst_ni     ( rst_ni        ),
        .testmode_i ( test_enable_i ),
        .flush_i    ( 1'b0   ),
        .usage_o    (  ),
        .data_i     ( data_i  [in_route][in_phys_channel] ),
        .valid_i    ( valid_i [in_route][v_chan]          ),
        .ready_o    ( ready_o [in_route][v_chan]          ),
        .data_o     ( in_data [in_route][v_chan]          ),
        .valid_o    ( in_valid[in_route][v_chan]          ),
        .ready_i    ( in_ready[in_route][v_chan]          )
      );

      floo_ring_on_mesh_route_select #(
        .NumRoutes    ( NumOutput    ),
        .NumNodes     ( NumNodes     ),
        .flit_t       ( flit_t       ),
        .RouteAlgo    ( RouteAlgo    ),
        .IdWidth      ( IdWidth      ),
        .id_t         ( id_t         ),
        .NumAddrRules ( NumAddrRules ),
        .addr_rule_t  ( addr_rule_t  )
      ) i_ring_on_mesh_route_select (
        .clk_i,
        .rst_ni,

        .xy_id_i        ( xy_id_i                          ),
        .id_route_map_i ( id_route_map_i                   ),
        .ring_on_mesh_id_i,
        .ring_on_mesh_up_port_i,
        .ring_on_mesh_down_port_i,
        .channel_i      ( in_data       [in_route][v_chan] ),
        .valid_i        ( in_valid      [in_route][v_chan] ),
        .ready_i        ( in_ready      [in_route][v_chan] ),
        .channel_o      ( in_routed_data[in_route][v_chan] ),
        .route_sel_o    ( route_mask    [in_route][v_chan] ),
        .route_sel_id_o (                                  )
      );

    end
  end

  localparam int unsigned NumInputLimited = NoLoopback ? NumInput-1 : NumInput;

  logic [NumOutput-1:0][NumVirtChannels-1:0][NumInputLimited-1:0] masked_valid, masked_ready;
  logic [NumInput-1:0][NumVirtChannels-1:0][NumOutput-1:0] masked_all_ready;

  flit_t [NumOutput-1:0][NumVirtChannels-1:0][NumInputLimited-1:0] masked_data;

  //ring on mesh ctrl
  logic [NumInput-1:0][NumVirtChannels-1:0][NumOutput-1:0] finished_req_q, finished_req_d;

  // TODO MICHAERO: reduce connections if (RouteAlgo == XYRouting)
  for (genvar in_route = 0; in_route < NumInput; in_route++) begin : gen_hs_input
    for (genvar v_chan = 0; v_chan < NumVirtChannels; v_chan++) begin : gen_hs_virt
      for (genvar out_route = 0; out_route < NumOutput; out_route++) begin : gen_hs_output
        localparam int unsigned ModInRoute =
          in_route < out_route && NoLoopback ? in_route : in_route-1;
        if (in_route == out_route && NoLoopback) begin : gen_inout_identical
          assign masked_all_ready[in_route][v_chan][out_route] = '0;
          // TODO MICHAERO: assert no loopback routing!!!
        end else if ((RouteAlgo == XYRouting) && XYRouteOpt &&
                    (in_route == South || in_route == North) &&
                    (out_route == East || out_route == West)) begin : gen_xy_opt
          assign masked_all_ready[in_route][v_chan][out_route] = '0;
          assign masked_valid[out_route][v_chan][ModInRoute] = '0;
          assign masked_data[out_route][v_chan][ModInRoute] = '0;
        end else begin : gen_default
          assign masked_all_ready[in_route][v_chan][out_route] =
            masked_ready[out_route][v_chan][ModInRoute];

          always_comb begin
              if(in_routed_data[in_route][v_chan].hdr.ring_on_mesh_mcast == 1'b0) begin
                  masked_valid[out_route][v_chan][ModInRoute] =
                    in_valid[in_route][v_chan] & route_mask[in_route][v_chan][out_route];
              end else begin
                  //only send un requested dir in mcast case
                  masked_valid[out_route][v_chan][ModInRoute] =
                    in_valid[in_route][v_chan] & route_mask[in_route][v_chan][out_route] & ~finished_req_q[in_route][v_chan][out_route];
              end
          end

          assign masked_data[out_route][v_chan][ModInRoute] =
            in_routed_data[in_route][v_chan];
        end
      end

      // ring on mesh: finished_req_q initialized as 0
      // when request to one of the dir is finished, set the respective bit in finished_req_q to 1
      // finished_req_q is reset to 0 when a mcast req is finished (in_ready is high)
      // masked valid is only high when in
      `FF(finished_req_q[in_route][v_chan], finished_req_d[in_route][v_chan], '0)

      always_comb begin
          if(in_ready[in_route][v_chan]) begin
              finished_req_d[in_route][v_chan] = '0;
          end else begin
              finished_req_d[in_route][v_chan] = finished_req_q[in_route][v_chan] | (masked_all_ready[in_route][v_chan] & route_mask[in_route][v_chan]);
          end
      end

      always_comb begin
          if(in_routed_data[in_route][v_chan].hdr.ring_on_mesh_mcast == 1'b0) begin
              in_ready[in_route][v_chan] =
                |(masked_all_ready[in_route][v_chan] & route_mask[in_route][v_chan]);
          end else begin
              //ring on mesh multi casting
              //if all (current cycle requested and accepted dir, un requested dir, previous cycle requested and accepeted dir) are done, mcast finished
              in_ready[in_route][v_chan] =
                &((masked_all_ready[in_route][v_chan] & route_mask[in_route][v_chan]) | ~route_mask[in_route][v_chan] | finished_req_q[in_route][v_chan]);
          end
      end
    end
  end


  flit_t [NumOutput-1:0][NumVirtChannels-1:0] out_data, out_buffered_data;
  logic  [NumOutput-1:0][NumVirtChannels-1:0] out_valid, out_ready;
  logic  [NumOutput-1:0][NumVirtChannels-1:0] out_buffered_valid, out_buffered_ready;

  for (genvar out_route = 0; out_route < NumOutput; out_route++) begin : gen_output

    // arbitrate input fifos per virtual channel
    for (genvar v_chan = 0; v_chan < NumVirtChannels; v_chan++) begin : gen_virt_output

      floo_wormhole_arbiter #(
        .NumRoutes  ( NumInputLimited ),
        .flit_t     ( flit_t          )
      ) i_wormhole_arbiter (
        .clk_i,
        .rst_ni,

        .valid_i ( masked_valid[out_route][v_chan] ),
        .ready_o ( masked_ready[out_route][v_chan] ),
        .data_i  ( masked_data [out_route][v_chan] ),

        .valid_o ( out_valid[out_route][v_chan] ),
        .ready_i ( out_ready[out_route][v_chan] ),
        .data_o  ( out_data [out_route][v_chan] )
      );

      if (OutFifoDepth > 0) begin : gen_out_fifo
        (* ungroup *)
        stream_fifo_optimal_wrap #(
          .Depth  ( OutFifoDepth  ),
          .type_t ( flit_t        )
        ) i_stream_fifo (
          .clk_i      ( clk_i         ),
          .rst_ni     ( rst_ni        ),
          .testmode_i ( test_enable_i ),
          .flush_i    ( 1'b0   ),
          .usage_o    (  ),
          .data_i     ( out_data          [out_route][v_chan] ),
          .valid_i    ( out_valid         [out_route][v_chan] ),
          .ready_o    ( out_ready         [out_route][v_chan] ),
          .data_o     ( out_buffered_data [out_route][v_chan] ),
          .valid_o    ( out_buffered_valid[out_route][v_chan] ),
          .ready_i    ( out_buffered_ready[out_route][v_chan] )
        );
      end else begin : gen_no_out_fifo
        assign out_buffered_data [out_route][v_chan] = out_data          [out_route][v_chan];
        assign out_buffered_valid[out_route][v_chan] = out_valid         [out_route][v_chan];
        assign out_ready         [out_route][v_chan] = out_buffered_ready[out_route][v_chan];
      end
    end

    // Arbitrate virtual channels onto the physical channel
    floo_vc_arbiter #(
      .NumVirtChannels ( NumVirtChannels ),
      .flit_t          ( flit_t          ),
      .NumPhysChannels ( NumPhysChannels )
    ) i_vc_arbiter (
      .clk_i,
      .rst_ni,

      .valid_i ( out_buffered_valid[out_route] ),
      .ready_o ( out_buffered_ready[out_route] ),
      .data_i  ( out_buffered_data [out_route] ),

      .ready_i ( ready_i  [out_route] ),
      .valid_o ( valid_o  [out_route] ),
      .data_o  ( data_o   [out_route] )
    );
  end

  for (genvar i = 0; i < NumInput; i++) begin : gen_input_assert
    for (genvar v = 0; v < NumVirtChannels; v++) begin : gen_virt_assert
      // Assert that the input data is stable when valid is asserted
      // `ASSERT(StableDataIn, valid_i[i][v] && !ready_o[i][v] |=> $stable(data_i[i][v]))
      // Assert that valid is stable when ready is not asserted
      `ASSERT(StableValidIn, valid_i[i][v] && !ready_o[i][v] |=> $stable(valid_i[i][v]))
    end
  end

  for (genvar o = 0; o < NumOutput; o++) begin : gen_output_assert
    for (genvar v = 0; v < NumVirtChannels; v++) begin : gen_virt_assert
      // Assert that the input data is stable when valid is asserted
      // `ASSERT(StableDataOut, valid_o[o][v] && !ready_i[o][v] |=> $stable(data_o[o][v]))
      // Assert that valid is stable when ready is not asserted
      `ASSERT(StableValidOut, valid_o[o][v] && !ready_i[o][v] |=> $stable(valid_o[o][v]))
    end
  end

  // If XYRouting optimization is enabled, assert that not Y->X routing occurs
  if ((RouteAlgo == XYRouting) && XYRouteOpt) begin : gen_xy_opt_assert
    for (genvar v = 0; v < NumVirtChannels; v++) begin : gen_virt
      `ASSERT(XYDirectionNotAllowed,
          !(in_valid[South][v] && route_mask[South][v][East]) &&
          !(in_valid[South][v] && route_mask[South][v][West]) &&
          !(in_valid[North][v] && route_mask[North][v][East]) &&
          !(in_valid[North][v] && route_mask[North][v][West]))
    end
  end

endmodule
