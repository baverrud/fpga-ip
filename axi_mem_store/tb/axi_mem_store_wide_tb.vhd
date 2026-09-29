-----------------------------------------------------------------------
--Filename         : axi_mem_store_wide_tb.vhd
--Description      : Wide-bus testbench for axi_mem_store.
--                 : Runs the latency-enabled wrapper at GC_DATA_BYTES = 64
--                 : with the axi_mem_model bus geometry: a 49-bit address,
--                 : a 6-bit ID and a 1 KiB memory, so the whole hierarchy
--                 : carries a 512-bit R data bus.
--                 : Checks 64-byte little-endian beat assembly, the top
--                 : memory boundary, the wide-address wrap guard, R-field
--                 : stability under backpressure and R-side latency.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.axis_bfm_pkg.all;

entity axi_mem_store_wide_tb is
end entity;

architecture sim of axi_mem_store_wide_tb is

  constant C_CLK_PERIOD  : time     := 10 ns;
  constant C_DATA_BYTES  : positive := 64;
  constant C_ADDR_WIDTH  : positive := 49;
  constant C_ID_WIDTH    : positive := 6;
  constant C_TIMER_WIDTH : positive := 8;
  constant C_MEM_BYTES   : positive := 1024;
  constant C_RDATA_WIDTH : positive := 8 * C_DATA_BYTES;

  constant C_RDATA_ZERO : std_logic_vector(C_RDATA_WIDTH-1 downto 0) :=
    (others => '0');

  signal aclk     : std_logic := '0';
  signal aresetn  : std_logic := '0';
  signal sim_done : boolean := false;

  -- Packed write stream used by axis_bfm_pkg.  The DUT port map connects its
  -- address and data slices directly to the mem_wr_* ports.
  signal mem_wr_tdata  : std_logic_vector(C_ADDR_WIDTH+7 downto 0) :=
    (others => '0');
  signal mem_wr_tvalid : std_logic := '0';
  signal mem_wr_tready : std_logic;
  signal mem_wr_error  : std_logic;

  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0) := (others => '0');
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal ar_len   : std_logic_vector(7 downto 0) := (others => '0');
  signal ar_valid : std_logic := '0';
  signal ar_ready : std_logic;

  signal r_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_data  : std_logic_vector(C_RDATA_WIDTH-1 downto 0);
  signal r_resp  : std_logic_vector(1 downto 0);
  signal r_last  : std_logic;
  signal r_valid : std_logic;
  signal r_ready : std_logic := '0';

  signal ar_base_enable   : std_logic := '0';
  signal ar_jitter_enable : std_logic := '0';
  signal r_base_enable    : std_logic := '0';
  signal r_jitter_enable  : std_logic := '0';
  signal base_latency     : std_logic_vector(C_TIMER_WIDTH-1 downto 0) :=
    (others => '0');
  signal base_beat_gap    : std_logic_vector(C_TIMER_WIDTH-1 downto 0) :=
    (others => '0');

  function expected_byte(addr : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned((addr * 3 + 5) mod 256, 8));
  end function;

begin

  aclk <= not aclk after C_CLK_PERIOD / 2 when not sim_done else '0';

  p_watchdog : process
  begin
    wait for 200 us;
    assert sim_done report "axi_mem_store_wide_tb timeout" severity failure;
    wait;
  end process;

  u_dut : entity work.axi_mem_store
    generic map (
      GC_DATA_BYTES     => C_DATA_BYTES,
      GC_ADDR_WIDTH     => C_ADDR_WIDTH,
      GC_ID_WIDTH       => C_ID_WIDTH,
      GC_TIMER_WIDTH    => C_TIMER_WIDTH,
      GC_AR_FIFO_DEPTH  => 4,
      GC_R_FIFO_DEPTH   => 8,
      GC_MEM_SIZE_BYTES => C_MEM_BYTES
    )
    port map (
      aclk             => aclk,
      aresetn          => aresetn,
      ar_base_enable   => ar_base_enable,
      ar_jitter_enable => ar_jitter_enable,
      r_base_enable    => r_base_enable,
      r_jitter_enable  => r_jitter_enable,
      base_latency     => base_latency,
      base_beat_gap    => base_beat_gap,
      mem_wr_addr      => mem_wr_tdata(C_ADDR_WIDTH+7 downto 8),
      mem_wr_data      => mem_wr_tdata(7 downto 0),
      mem_wr_valid     => mem_wr_tvalid,
      mem_wr_ready     => mem_wr_tready,
      mem_wr_error     => mem_wr_error,
      ar_id            => ar_id,
      ar_addr          => ar_addr,
      ar_len           => ar_len,
      ar_valid         => ar_valid,
      ar_ready         => ar_ready,
      r_id             => r_id,
      r_data           => r_data,
      r_resp           => r_resp,
      r_last           => r_last,
      r_valid          => r_valid,
      r_ready          => r_ready
    );

  p_test : process

    -- Small byte addresses are converted here so the read helpers can take a
    -- natural number, while addresses above the integer range are driven as
    -- vectors directly.
    function addr_of(byte_addr : natural) return std_logic_vector is
    begin
      return std_logic_vector(to_unsigned(byte_addr, C_ADDR_WIDTH));
    end function;

    -- Drive one byte through the testbench population stream.  This is a
    -- helper for mem_wr_*, not a full AXI write-channel procedure.
    procedure mem_wr(addr : natural; data : std_logic_vector(7 downto 0)) is
      variable v_write : std_logic_vector(C_ADDR_WIDTH+7 downto 0);
    begin
      v_write := std_logic_vector(to_unsigned(addr, C_ADDR_WIDTH)) & data;
      axis_write(aclk, mem_wr_tdata, mem_wr_tvalid, mem_wr_tready, v_write);
    end procedure;

    procedure send_ar(
      id : natural;
      addr : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
      beats : natural) is
    begin
      ar_id    <= std_logic_vector(to_unsigned(id, C_ID_WIDTH));
      ar_addr  <= addr;
      ar_len   <= std_logic_vector(to_unsigned(beats - 1, 8));
      ar_valid <= '1';
      loop
        wait until rising_edge(aclk);
        exit when ar_ready = '1';
      end loop;
      ar_valid <= '0';
    end procedure;

    procedure wait_for_r_valid is
      variable got_beat : boolean := false;
    begin
      for timeout_idx in 0 to 200 loop
        wait until rising_edge(aclk);
        if r_valid = '1' then
          got_beat := true;
          exit;
        end if;
      end loop;
      assert got_beat
        report "timeout waiting for RVALID" severity failure;
    end procedure;

    procedure release_r is
    begin
      r_ready <= '1';
      wait until rising_edge(aclk);
      r_ready <= '0';
    end procedure;

    procedure check_beat_fields(
      id : natural;
      expected_resp : std_logic_vector(1 downto 0);
      expected_last : std_logic) is
    begin
      assert r_id = std_logic_vector(to_unsigned(id, C_ID_WIDTH))
        report "R ID mismatch" severity failure;
      assert r_last = expected_last
        report "R LAST mismatch" severity failure;
      assert r_resp = expected_resp
        report "R RESP mismatch" severity failure;
      if expected_resp = "10" then
        assert r_data = C_RDATA_ZERO
          report "SLVERR data was not zero" severity failure;
      end if;
    end procedure;

    procedure check_pattern_bytes(base : natural) is
    begin
      for byte_idx in 0 to C_DATA_BYTES-1 loop
        assert r_data(8*byte_idx+7 downto 8*byte_idx) =
               expected_byte(base + byte_idx)
          report "stored byte data mismatch" severity failure;
      end loop;
    end procedure;

    -- Read a burst from a byte address that fits in a natural number.
    procedure read_burst(
      id : natural; addr : natural; beats : natural;
      check_pattern : boolean) is
    begin
      send_ar(id, addr_of(addr), beats);
      r_ready <= '0';
      for beat_idx in 0 to beats-1 loop
        wait_for_r_valid;
        if beat_idx = beats-1 then
          check_beat_fields(id, "00", '1');
        else
          check_beat_fields(id, "00", '0');
        end if;
        if check_pattern then
          check_pattern_bytes(addr + beat_idx * C_DATA_BYTES);
        end if;
        release_r;
      end loop;
      r_ready <= '1';
    end procedure;

    -- Read a burst that must be answered with SLVERR on every beat.  The
    -- address is a vector so the top of the address space can be used.
    procedure read_bad_burst(
      id : natural;
      addr : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
      beats : natural) is
    begin
      send_ar(id, addr, beats);
      r_ready <= '0';
      for beat_idx in 0 to beats-1 loop
        wait_for_r_valid;
        if beat_idx = beats-1 then
          check_beat_fields(id, "10", '1');
        else
          check_beat_fields(id, "10", '0');
        end if;
        release_r;
      end loop;
      r_ready <= '1';
    end procedure;

    procedure check_stalled_response(id : natural) is
      variable saved_id   : std_logic_vector(C_ID_WIDTH-1 downto 0);
      variable saved_data : std_logic_vector(C_RDATA_WIDTH-1 downto 0);
      variable saved_resp : std_logic_vector(1 downto 0);
      variable saved_last : std_logic;
    begin
      send_ar(id, addr_of(0), 1);
      r_ready <= '0';
      wait_for_r_valid;
      saved_id   := r_id;
      saved_data := r_data;
      saved_resp := r_resp;
      saved_last := r_last;
      for stall_idx in 1 to 3 loop
        wait until rising_edge(aclk);
        assert r_valid = '1' and r_id = saved_id and
               r_data = saved_data and r_resp = saved_resp and
               r_last = saved_last
          report "R response changed during backpressure"
          severity failure;
      end loop;
      release_r;
      r_ready <= '1';
    end procedure;

  begin
    wait for C_CLK_PERIOD * 3;
    aresetn <= '1';
    wait for C_CLK_PERIOD * 2;
    assert mem_wr_tready = '1'
      report "memory write port did not become ready" severity failure;

    -- An accepted write at the first address outside memory pulses the error
    -- for one clock and stores nothing.  This also exercises the widened
    -- exclusive limit at the wide address geometry.
    mem_wr_tdata  <= addr_of(C_MEM_BYTES) & x"EE";
    mem_wr_tvalid <= '1';
    wait until rising_edge(aclk);
    mem_wr_tvalid <= '0';
    wait for 1 ns;
    assert mem_wr_error = '1'
      report "out-of-range write did not pulse mem_wr_error"
      severity failure;
    wait until rising_edge(aclk);
    wait for 1 ns;
    assert mem_wr_error = '0'
      report "mem_wr_error was not one clock wide" severity failure;

    -- Populate every byte so an address-derived pattern cannot pass.
    for addr in 0 to C_MEM_BYTES-1 loop
      mem_wr(addr, expected_byte(addr));
    end loop;

    -- Two 64-byte beats from address zero: every byte must match.
    read_burst(1, 0, 2, true);

    -- The final fully valid beat ends exactly at the top of memory.
    read_burst(2, C_MEM_BYTES - C_DATA_BYTES, 1, true);

    -- A beat that crosses the top of memory returns zero data and SLVERR.
    read_bad_burst(3, addr_of(C_MEM_BYTES - C_DATA_BYTES / 2), 1);

    -- The first address outside memory is also SLVERR.
    read_bad_burst(4, addr_of(C_MEM_BYTES), 1);

    -- Reads near the top of the 49-bit address space must not wrap into
    -- memory, and a wrapping burst must stay SLVERR for all of its beats.
    read_bad_burst(5, (others => '1'), 1);
    read_bad_burst(6, (others => '1'), 3);

    -- R payload fields must remain stable while the consumer is stalled.
    check_stalled_response(7);

    -- The R-side per-entry latency control also works at this width.
    r_base_enable <= '1';
    base_beat_gap <= std_logic_vector(to_unsigned(2, C_TIMER_WIDTH));
    read_burst(8, 0, 3, true);
    r_base_enable <= '0';
    base_beat_gap <= (others => '0');

    -- The AR-side base delay also works with the wide request payload.
    ar_base_enable <= '1';
    base_latency   <= std_logic_vector(to_unsigned(2, C_TIMER_WIDTH));
    read_burst(9, 0, 1, true);
    ar_base_enable <= '0';
    base_latency   <= (others => '0');

    report "axi_mem_store_wide_tb: all tests passed" severity note;
    sim_done <= true;
    wait;
  end process;

end architecture;
