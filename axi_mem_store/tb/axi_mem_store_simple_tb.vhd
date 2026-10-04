-----------------------------------------------------------------------
--Filename         : axi_mem_store_simple_tb.vhd
--Description      : Small waveform-oriented smoke test for axi_mem_store.
--Author           : Rune Baeverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.axis_bfm_pkg.all;

entity axi_mem_store_simple_tb is
end entity;

architecture sim of axi_mem_store_simple_tb is
  constant C_CLK_PERIOD : time := 10 ns;
  signal aclk : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal done : boolean := false;
  -- Packed write stream used by axis_bfm_pkg.  The DUT port map connects
  -- its address and data slices directly to the mem_wr_* ports.
  signal mem_wr_tdata : std_logic_vector(23 downto 0) := (others => '0');
  signal mem_wr_tvalid : std_logic := '0';
  signal mem_wr_tready : std_logic;
  signal mem_wr_error : std_logic;
  signal ar_id : std_logic_vector(3 downto 0) := (others => '0');
  signal ar_addr : std_logic_vector(15 downto 0) := (others => '0');
  signal ar_len : std_logic_vector(7 downto 0) := (others => '0');
  signal ar_valid, ar_ready : std_logic := '0';
  signal r_id : std_logic_vector(3 downto 0);
  signal r_data : std_logic_vector(31 downto 0);
  signal r_resp : std_logic_vector(1 downto 0);
  signal r_last, r_valid : std_logic;
  signal r_ready : std_logic := '1';
  signal base_latency, base_beat_gap : std_logic_vector(7 downto 0) := (others => '0');
begin
  aclk <= not aclk after C_CLK_PERIOD / 2 when not done else '0';

  u_dut : entity work.axi_mem_store
    generic map (GC_DATA_BYTES => 4, GC_ADDR_WIDTH => 16,
      GC_ID_WIDTH => 4, GC_TIMER_WIDTH => 8,
      GC_AR_FIFO_DEPTH => 4, GC_R_FIFO_DEPTH => 4,
      GC_MEM_SIZE_BYTES => 64)
    port map (aclk => aclk, aresetn => aresetn,
      ar_base_enable => '0', ar_jitter_enable => '0',
      r_base_enable => '0', r_jitter_enable => '0',
      base_latency => base_latency, base_beat_gap => base_beat_gap,
      mem_wr_addr => mem_wr_tdata(23 downto 8),
      mem_wr_data => mem_wr_tdata(7 downto 0),
      mem_wr_valid => mem_wr_tvalid,
      mem_wr_ready => mem_wr_tready,
      mem_wr_error => mem_wr_error,
      ar_id => ar_id, ar_addr => ar_addr, ar_len => ar_len,
      ar_valid => ar_valid, ar_ready => ar_ready,
      r_id => r_id, r_data => r_data, r_resp => r_resp,
      r_last => r_last, r_valid => r_valid, r_ready => r_ready);

  p_test : process
    -- Small wrapper around the shared stream BFM for one memory byte write.
    procedure mem_wr(addr : natural; data : std_logic_vector(7 downto 0)) is
      variable v_write : std_logic_vector(23 downto 0);
    begin
      v_write := std_logic_vector(to_unsigned(addr, 16)) & data;
      axis_write(aclk, mem_wr_tdata, mem_wr_tvalid,
                 mem_wr_tready, v_write);
    end procedure;

    procedure read_one(id : natural; addr : natural;
                       expected_data : std_logic_vector(31 downto 0)) is
    begin
      ar_id    <= std_logic_vector(to_unsigned(id, ar_id'length));
      ar_addr  <= std_logic_vector(to_unsigned(addr, ar_addr'length));
      ar_len   <= x"00";
      ar_valid <= '1';
      loop
        wait until rising_edge(aclk);
        exit when ar_ready = '1';
      end loop;
      ar_valid <= '0';

      for timeout in 0 to 100 loop
        wait until rising_edge(aclk);
        exit when r_valid = '1';
      end loop;
      assert r_valid = '1'
        report "simple test: response did not arrive" severity failure;
      assert r_id = std_logic_vector(to_unsigned(id, r_id'length))
        report "simple test: response ID mismatch" severity failure;
      assert r_data = expected_data
        report "simple test: response data mismatch" severity failure;
      assert r_resp = "00" and r_last = '1'
        report "simple test: response fields mismatch" severity failure;
      wait until rising_edge(aclk);
    end procedure;
  begin
    wait for C_CLK_PERIOD * 3;
    aresetn <= '1';
    wait for C_CLK_PERIOD * 2;
    mem_wr(0, x"EF");
    mem_wr(1, x"BE");
    mem_wr(2, x"AD");
    mem_wr(3, x"DE");
    read_one(3, 0, x"DEADBEEF");
    done <= true;
    wait;
  end process;
end architecture;
