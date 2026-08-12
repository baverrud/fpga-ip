-----------------------------------------------------------------------
--Filename         : axi_r_demux.vhd
--Description      : AXI Read Data Channel Demultiplexer with per-ID
--                 : elastic buffering (instantiates axis_fifo per client):
--                 :  - Routes incoming r_data, r_last, and r_resp based on r_id.
--                 :  - Registered r_ready with a one-beat skid register, so
--                 :    the input ready has no combinational path from r_id /
--                 :    r_valid and no beat is lost when a target FIFO is full.
--                 :  - Unpacks stored payload for client response interfaces.
--                 :  - Fully registered r_pop credit return pulses.
--                 :  - Two-process record-based state architecture.
--                 :  - Fully synchronous active-low reset logic (aresetn).
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;  -- slv_array_t, slv2_array_t

entity axi_r_demux is
  generic (
    GC_NUM_CLIENTS : positive := 4;
    GC_DATA_BYTES  : positive := 4;                           -- data width in bytes (e.g. 4 = 32-bit)
    GC_ID_WIDTH    : positive := 4;
    GC_FIFO_DEPTH  : positive range 2 to positive'high := 32  -- per-client FIFO depth
  );
  port (
    aclk    : in std_logic;
    aresetn : in std_logic;  -- synchronous, active low

    -- AXI Read Data Channel (interconnect -> demux)
    r_id    : in  std_logic_vector(GC_ID_WIDTH-1 downto 0);
    r_data  : in  std_logic_vector(8*GC_DATA_BYTES-1 downto 0);
    r_resp  : in  std_logic_vector(1 downto 0);
    r_last  : in  std_logic;
    r_valid : in  std_logic;
    r_ready : out std_logic;

    -- Demuxed client response interfaces
    rsp_data  : out slv_array_t(0 to GC_NUM_CLIENTS-1)(8*GC_DATA_BYTES-1 downto 0);
    rsp_resp  : out slv2_array_t(0 to GC_NUM_CLIENTS-1);
    rsp_last  : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    rsp_valid : out std_logic_vector(0 to GC_NUM_CLIENTS-1);
    rsp_ready : in  std_logic_vector(0 to GC_NUM_CLIENTS-1);

    -- Credit return pulses (1-cycle registered pulse per popped beat;
    -- connects to the AR credit mux)
    r_pop : out std_logic_vector(0 to GC_NUM_CLIENTS-1)
  );
end entity axi_r_demux;

architecture arch of axi_r_demux is

  -- Total payload width packed into each axis_fifo:
  -- Payload layout: [ r_resp (2 bits) | r_last (1 bit) | r_data (8*GC_DATA_BYTES bits) ]
  constant C_DATA_BITS    : positive := 8 * GC_DATA_BYTES;
  constant C_PAYLOAD_BITS : positive := C_DATA_BITS + 3;

  type payload_array_t is array (0 to GC_NUM_CLIENTS-1) of std_logic_vector(C_PAYLOAD_BITS-1 downto 0);

  -- "to fifo" signals (FIFO slave interface)
  signal tf_data  : payload_array_t;
  signal tf_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal tf_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1);

  -- "from fifo" signals (FIFO master interface)
  signal ff_data  : payload_array_t;
  signal ff_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal ff_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1);

  -- State record definition for two-process method.
  -- The one-beat skid holds an accepted beat whose target FIFO is full. The
  -- one-hot skid_dest is also the occupancy flag: all zeroes means empty.
  type rec_t is record
    skid_payload : std_logic_vector(C_PAYLOAD_BITS-1 downto 0);  -- held beat payload
    skid_dest    : std_logic_vector(0 to GC_NUM_CLIENTS-1);      -- one-hot target client
    r_ready      : std_logic;                                    -- registered input ready
    r_pop        : std_logic_vector(0 to GC_NUM_CLIENTS-1);      -- registered credit pulses
  end record;

  -- State record default and reset value
  constant C_REC_DEFAULT : rec_t := (
    skid_payload => (others => '0'),
    skid_dest    => (others => '0'),
    r_ready      => '1',
    r_pop        => (others => '0')
  );

  signal r : rec_t := C_REC_DEFAULT;  -- current state
  signal r_in : rec_t;  -- next state

begin

  assert GC_ID_WIDTH >= log2ceil(GC_NUM_CLIENTS)
    report "axi_r_demux: GC_ID_WIDTH cannot encode GC_NUM_CLIENTS clients"
    severity failure;

  -- Combinational next-state / output process (two-process method).
  --
  -- PERFORMANCE NOTE: r_ready is registered and depends only on the skid
  -- occupancy and the FIFOs' registered ready - never on r_id/r_valid - so
  -- the input handshake has no combinational input-to-output path. The
  -- one-beat skid absorbs a beat whose target FIFO is full, so the
  -- registered ready can never over-commit.
  p_logic : process(all)
    variable v             : rec_t;
    variable client_idx    : integer;
    variable id_onehot     : std_logic_vector(0 to GC_NUM_CLIENTS-1);
    variable id_in_range   : boolean;
    variable packed_s      : std_logic_vector(C_PAYLOAD_BITS-1 downto 0);
    variable v_skid_load   : boolean;
    variable skid_present  : boolean;
    variable skid_drains   : boolean;
  begin
    -- (1) default: recover current state.
    v := r;

    packed_s := r_resp & r_last & r_data;

    -- Decode the incoming r_id into a one-hot client vector. This decoder
    -- feeds only the (registered) accept path - the skid stores the decoded
    -- one-hot, so the FIFO write path never re-decodes and has no carry
    -- chain on the critical path.
    client_idx  := to_integer(unsigned(r_id));
    id_in_range := (client_idx >= 0) and (client_idx < GC_NUM_CLIENTS);
    id_onehot   := (others => '0');
    if id_in_range then
      id_onehot(client_idx) := '1';
    end if;

    -- Defaults.
    tf_valid <= (others => '0');
    r_ready  <= r.r_ready;
    for i in 0 to GC_NUM_CLIENTS-1 loop
      tf_data(i) <= packed_s;
    end loop;
    v_skid_load := false;
    skid_present := r.skid_dest /= (r.skid_dest'range => '0');
    skid_drains := false;

    -- (2) next-state and output logic.

    -- Write path: if the skid holds a beat, push it to its target FIFO.
    -- One-hot skid_dest selects the FIFO directly - no decoder.
    if skid_present then
      for i in 0 to GC_NUM_CLIENTS-1 loop
        if r.skid_dest(i) = '1' then
          tf_data(i) <= r.skid_payload;
          if tf_ready(i) = '1' then
            tf_valid(i) <= '1';
            skid_drains := true;
          end if;
        end if;
      end loop;
      if skid_drains then
        v.skid_dest := (others => '0');  -- skid drains
      end if;
    end if;

    -- Accept an incoming beat when the registered ready is high. It is
    -- written straight to its target FIFO when that FIFO is ready and is not
    -- already receiving the draining skid beat; otherwise it is held in the
    -- one-beat skid (free here because it was empty or just drained).
    if (r_valid = '1') and (r.r_ready = '1') and id_in_range then
      if skid_present and (r.skid_dest(client_idx) = '1') then
        v_skid_load := true;  -- same FIFO: hand the beat to the skid
      elsif tf_ready(client_idx) = '1' then
        -- Direct write, no skid (drive the one-hot target).
        for i in 0 to GC_NUM_CLIENTS-1 loop
          if id_onehot(i) = '1' then
            tf_valid(i) <= '1';
          end if;
        end loop;
      else
        v_skid_load := true;  -- target FIFO full: hold in the skid
      end if;
    end if;

    -- Out-of-range r_id cannot be routed. Flag it loudly in simulation;
    -- in hardware the beat is dropped (ready stays high) so the R
    -- channel is not deadlocked on a bad ID.
    if (r_valid = '1') and (r.r_ready = '1') and (not id_in_range) then
      assert false
        report "axi_r_demux: r_id out of range (" &
               integer'image(client_idx) & ")"
        severity failure;
    end if;

    if v_skid_load then
      v.skid_payload := packed_s;
      v.skid_dest    := id_onehot;
    end if;

    -- Registered input ready: accept a new beat next cycle only when the
    -- skid will be empty then (empty now and nothing skidded, or it drains
    -- now and nothing is handed off). Depends only on registered state and
    -- the FIFOs' registered ready - never on r_id/r_valid.
    v.r_ready := '0';
    if not v_skid_load then
      if not skid_present then
        v.r_ready := '1';
      elsif skid_drains then
        v.r_ready := '1';  -- skid drains this cycle
      end if;
    end if;

    -- Output unpacking and handshaking ("from fifo" signals).
    for i in 0 to GC_NUM_CLIENTS-1 loop
      ff_ready(i)  <= rsp_ready(i);
      rsp_valid(i) <= ff_valid(i);

      rsp_data(i) <= ff_data(i)(C_DATA_BITS-1 downto 0);
      rsp_last(i) <= ff_data(i)(C_DATA_BITS);
      rsp_resp(i) <= ff_data(i)(C_PAYLOAD_BITS-1 downto C_DATA_BITS+1);

      -- Registered credit return pulse generation.
      v.r_pop(i) := ff_valid(i) and rsp_ready(i);
    end loop;

    -- Drive registered r_pop output port.
    r_pop <= r.r_pop;

    -- (3) store next state.
    r_in <= v;
  end process;

  -- Register process: global reset handled here only.
  p_reg : process(aclk)
  begin
    if rising_edge(aclk) then
      if aresetn = '0' then
        r <= C_REC_DEFAULT;
      else
        r <= r_in;
      end if;
    end if;
  end process;

  -- Per-client elastic buffers.
  gen_client_fifos : for i in 0 to GC_NUM_CLIENTS-1 generate

    i_client_fifo : entity work.axis_fifo
      generic map (
        GC_TDATA_WIDTH => C_PAYLOAD_BITS,
        GC_FIFO_DEPTH  => GC_FIFO_DEPTH
      )
      port map (
        aclk    => aclk,
        aresetn => aresetn,

        -- Slave interface ("to fifo")
        s_axis_tdata  => tf_data(i),
        s_axis_tvalid => tf_valid(i),
        s_axis_tready => tf_ready(i),

        -- Master interface ("from fifo")
        m_axis_tdata  => ff_data(i),
        m_axis_tvalid => ff_valid(i),
        m_axis_tready => ff_ready(i),

        fifo_count => open  -- unused
      );

  end generate gen_client_fifos;

end architecture;
