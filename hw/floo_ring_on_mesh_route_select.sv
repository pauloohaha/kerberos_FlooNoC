// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Michael Rogenmoser <michaero@iis.ee.ethz.ch>

`include "common_cells/registers.svh"

module floo_ring_on_mesh_route_select
  import floo_pkg::*;
#(
  parameter int unsigned NumRoutes     = 0,
  parameter int unsigned NumNodes      = 16,
  parameter type         flit_t        = logic,
  parameter route_algo_e RouteAlgo     = IdTable,
  parameter bit          LockRouting   = 1'b1,
  /// Used for ID-based and XY routing
  parameter int unsigned IdWidth       = 0,
  /// Used for ID-based routing
  parameter int unsigned NumAddrRules  = 0,
  parameter type         addr_rule_t   = logic,
  parameter type         id_t          = logic[IdWidth-1:0],
  /// Used for source-based routing
  parameter int unsigned RouteSelWidth = $clog2(NumRoutes)
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,

  input  id_t                           xy_id_i,
  input  addr_rule_t [NumAddrRules-1:0] id_route_map_i,

  input  logic [$clog2(NumNodes)-1:0]   ring_on_mesh_id_i,
  input  logic [RouteSelWidth-1:0]      ring_on_mesh_up_port_i,
  input  logic [RouteSelWidth-1:0]      ring_on_mesh_down_port_i,

  input  flit_t                         channel_i,
  input  logic                          valid_i,
  input  logic                          ready_i,
  output flit_t                         channel_o,
  output logic [NumRoutes-1:0]          route_sel_o, // One-hot route
  output logic [RouteSelWidth-1:0]      route_sel_id_o
);

  logic [NumRoutes-1:0] route_sel;
  logic [RouteSelWidth-1:0] route_sel_id;

    if (RouteAlgo == IdTable) begin : gen_id_table
        // Routing based on an ID table passed into the router (TBD parameter or signal)
        // Assumes an ID field present in the flit_t

        logic [RouteSelWidth-1:0] id_table_result;
        assign channel_o = channel_i;

        addr_decode #(
          .NoIndices ( NumRoutes    ),
          .NoRules   ( NumAddrRules ),
          .addr_t    ( id_t         ),
          .rule_t    ( addr_rule_t  ),
          .Napot     ( 0            )
        ) i_id_decode (
          .addr_i           ( channel_i.hdr.dst_id  ),
          .addr_map_i       ( id_route_map_i    ),
          .idx_o            ( id_table_result   ),
          .dec_valid_o      (),
          .dec_error_o      (),
          .default_idx_i    ('0),
          .en_default_idx_i ('0)
        );

        // One-hot encoding of the decoded route
        always_comb begin : proc_route_sel
          route_sel_id = id_table_result;
          route_sel = '0;
          route_sel[id_table_result] = 1'b1;
        end

      end else if (RouteAlgo == SourceRouting) begin : gen_consumption
        // Routing based on a consumable header in the flit
        always_comb begin
            if (channel_i.hdr.ring_on_mesh_mcast == 1'b0) begin
                  route_sel_id = channel_i.hdr.dst_id[RouteSelWidth-1:0];
                  route_sel = '0;
                  route_sel[route_sel_id] = 1'b1;
                  channel_o = channel_i;
                  channel_o.hdr.dst_id = channel_i.hdr.dst_id >> RouteSelWidth;
                
            end else begin
                //ring on mesh mcast
                  route_sel = '0;
                  route_sel_id = '0; //Piao: no used in rong on mesh mcast
                  if(channel_i.hdr.dst_id != ring_on_mesh_id_i) begin
                      //need to forward
                      if(channel_i.hdr.up_down_traffic) begin
                          route_sel[ring_on_mesh_up_port_i] = 1'b1;
                      end else begin
                          route_sel[ring_on_mesh_down_port_i] = 1'b1;
                      end  
                  end
                  if(channel_i.hdr.ring_on_mesh_dst_mask[ring_on_mesh_id_i] == 1'b1) begin
                      //current node is in dst
                      route_sel[0] = 1'b1; // receive port
                  end
                  channel_o = channel_i;
            end
        end

      end else if (RouteAlgo == XYRouting) begin : gen_xy_routing
        // Routing based on simple XY routing
        // Assumes an even-bit ID field in the flit_t used for xy
        // assert ((IdWidth/2)*2 == IdWidth);
        // assert (NumRoutes == 5);

        // Port map:
        //   - 0: target/destination
        //   - 1: upper bits decreasing (South)
        //   - 2: lower bits decreasing (West )
        //   - 3: upper bits increasing (North)
        //   - 4: lower bits increasing (East )

        // One-hot encoding of the decoded route
        id_t id_in;
        assign id_in = id_t'(channel_i.hdr.dst_id);

        always_comb begin
            if (channel_i.hdr.ring_on_mesh_mcast == 1'b0) begin
                //normal unicast, xy routing
                route_sel_id = East;
                if (id_in.x == xy_id_i.x && id_in.y == xy_id_i.y) begin
                  route_sel_id = Eject + channel_i.hdr.dst_id.port_id;
                end else if (id_in.x == xy_id_i.x) begin
                  if (id_in.y < xy_id_i.y) begin
                    route_sel_id = South;
                  end else begin
                    route_sel_id = North;
                  end
                end else begin
                  if (id_in.x < xy_id_i.x) begin
                    route_sel_id = West;
                  end else begin
                    route_sel_id = East;
                  end
                end
                route_sel = '0;
                route_sel[route_sel_id] = 1'b1;
                
                channel_o = channel_i;
            end else begin
                //ring on mesh mcast
                route_sel = '0;
                route_sel_id = '0; //Piao: no used in rong on mesh mcast
                if(channel_i.hdr.dst_id != ring_on_mesh_id_i) begin
                    //need to forward
                    if(channel_i.hdr.up_down_traffic) begin
                        route_sel[ring_on_mesh_up_port_i] = 1'b1;
                    end else begin
                        route_sel[ring_on_mesh_down_port_i] = 1'b1;
                    end  
                end
                if(channel_i.hdr.ring_on_mesh_dst_mask[ring_on_mesh_id_i] == 1'b1) begin
                    //current node is in dst, need to recv
                    route_sel[0] = 1'b1; // receive port
                end
                channel_o = channel_i;
            end
        end
      end else begin : gen_err
        // Unknown or unimplemented routing otherwise
        initial begin
          $fatal(1, "Routing algorithm unknown");
        end
      end


  if (LockRouting) begin : gen_lock
    logic locked_route_d, locked_route_q;

    always_comb begin
      locked_route_d = locked_route_q;

      if (ready_i && valid_i) begin
        locked_route_d = ~channel_i.hdr.last;
      end
    end

    logic [NumRoutes-1:0] route_sel_q;
    logic [RouteSelWidth-1:0] route_sel_id_q;

    // Use previous route selection if locked
    assign route_sel_o = locked_route_q ? route_sel_q : route_sel;
    assign route_sel_id_o = locked_route_q ? route_sel_id_q : route_sel_id;

    `FF(locked_route_q, locked_route_d, '0)
    `FFL(route_sel_q, route_sel, ~locked_route_q, '0)
    `FFL(route_sel_id_q, route_sel_id, ~locked_route_q, '0)

    `ifndef TARGET_SYNTHESIS
      always @(posedge clk_i) begin
        if (ready_i && valid_i && locked_route_q &&
                ((route_sel_id_q != route_sel_id) || (route_sel_q != route_sel)))
          $warning("Mismatch in route selection!");
      end
    `endif
  end else begin : gen_no_lock
    assign route_sel_o = route_sel;
    assign route_sel_id_o = route_sel_id;
  end

endmodule
