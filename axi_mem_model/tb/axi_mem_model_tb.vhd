-----------------------------------------------------------------------
--Filename         : axi_mem_model_tb.vhd
--Description      : Multi-width testbench for axi_mem_model.
--                 : Tests GC_DATA_BYTES = 1,2,4,8,16,32,64,128 with
--                 : burst lengths 0,3,7,255 plus back-to-back ARs,
--                 : zero-latency, FIFO-full, R-backpressure, and
--                 : reset-in-flight — all in a single run.
--Author           : Rune Bæverrud
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity axi_mem_model_tb is
end entity;

architecture sim of axi_mem_model_tb is

  constant C_CLK_PERIOD  : time := 10 ns;
  constant C_ADDR_WIDTH  : positive := 32;
  constant C_ID_WIDTH    : positive := 4;
  constant C_AR_FIFO_DEPTH : positive := 8;
  constant C_TIMER_WIDTH : positive := 16;

  constant C_WCOUNT : natural := 8;

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal sim_done : boolean := false;

  signal s_ar_id   : std_logic_vector(C_ID_WIDTH-1 downto 0) := (others => '0');
  signal s_ar_addr : std_logic_vector(C_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal s_ar_len  : std_logic_vector(7 downto 0) := (others => '0');

  signal ar_valid    : std_logic_vector(0 to C_WCOUNT-1) := (others => '0');
  signal ar_ready    : std_logic_vector(0 to C_WCOUNT-1);
  signal enable      : std_logic_vector(0 to C_WCOUNT-1) := (others => '1');
  signal r_valid     : std_logic_vector(0 to C_WCOUNT-1);
  signal r_ready     : std_logic_vector(0 to C_WCOUNT-1) := (others => '1');
  signal r_last      : std_logic_vector(0 to C_WCOUNT-1);
  signal aresetn_dut : std_logic_vector(0 to C_WCOUNT-1) := (others => '0');

  -- Per-DUT r_id
  signal r_id_0  : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_id_1  : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_id_2  : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_id_3  : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_id_4  : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_id_5  : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_id_6  : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal r_id_7  : std_logic_vector(C_ID_WIDTH-1 downto 0);

  signal r_data_w1   : std_logic_vector(   7 downto 0);
  signal r_data_w2   : std_logic_vector(  15 downto 0);
  signal r_data_w4   : std_logic_vector(  31 downto 0);
  signal r_data_w8   : std_logic_vector(  63 downto 0);
  signal r_data_w16  : std_logic_vector( 127 downto 0);
  signal r_data_w32  : std_logic_vector( 255 downto 0);
  signal r_data_w64  : std_logic_vector( 511 downto 0);
  signal r_data_w128 : std_logic_vector(1023 downto 0);

  signal base_latency  : std_logic_vector(C_TIMER_WIDTH-1 downto 0) := (others => '0');
  signal base_beat_gap : std_logic_vector(C_TIMER_WIDTH-1 downto 0) := (others => '0');

  type name_t is array(0 to C_WCOUNT-1) of string(1 to 4);
  constant C_WCFG_NAME : name_t := (
    "w1  ","w2  ","w4  ","w8  ","w16 ","w32 ","w64 ","w128");

begin

  aclk <= not aclk after C_CLK_PERIOD / 2 when not sim_done else '0';

  -- DUTs

  u_w1 : entity work.axi_mem_model
    generic map (GC_DATA_BYTES=>1,GC_ADDR_WIDTH=>C_ADDR_WIDTH,
      GC_ID_WIDTH=>C_ID_WIDTH,GC_AR_FIFO_DEPTH=>C_AR_FIFO_DEPTH,
      GC_TIMER_WIDTH=>C_TIMER_WIDTH)
    port map (aclk=>aclk,aresetn=>aresetn_dut(0),ar_base_enable=>enable(0),
      ar_jitter_enable=>enable(0),r_base_enable=>enable(0),r_jitter_enable=>enable(0),
      base_latency=>base_latency,base_beat_gap=>base_beat_gap,
      ar_valid=>ar_valid(0),ar_ready=>ar_ready(0),
      ar_id=>s_ar_id,ar_addr=>s_ar_addr,ar_len=>s_ar_len,
      r_valid=>r_valid(0),r_ready=>r_ready(0),
      r_id=>r_id_0,r_data=>r_data_w1,r_resp=>open,r_last=>r_last(0));

  u_w2 : entity work.axi_mem_model
    generic map (GC_DATA_BYTES=>2,GC_ADDR_WIDTH=>C_ADDR_WIDTH,
      GC_ID_WIDTH=>C_ID_WIDTH,GC_AR_FIFO_DEPTH=>C_AR_FIFO_DEPTH,
      GC_TIMER_WIDTH=>C_TIMER_WIDTH)
    port map (aclk=>aclk,aresetn=>aresetn_dut(1),ar_base_enable=>enable(1),
      ar_jitter_enable=>enable(1),r_base_enable=>enable(1),r_jitter_enable=>enable(1),
      base_latency=>base_latency,base_beat_gap=>base_beat_gap,
      ar_valid=>ar_valid(1),ar_ready=>ar_ready(1),
      ar_id=>s_ar_id,ar_addr=>s_ar_addr,ar_len=>s_ar_len,
      r_valid=>r_valid(1),r_ready=>r_ready(1),
      r_id=>r_id_1,r_data=>r_data_w2,r_resp=>open,r_last=>r_last(1));

  u_w4 : entity work.axi_mem_model
    generic map (GC_DATA_BYTES=>4,GC_ADDR_WIDTH=>C_ADDR_WIDTH,
      GC_ID_WIDTH=>C_ID_WIDTH,GC_AR_FIFO_DEPTH=>C_AR_FIFO_DEPTH,
      GC_TIMER_WIDTH=>C_TIMER_WIDTH)
    port map (aclk=>aclk,aresetn=>aresetn_dut(2),ar_base_enable=>enable(2),
      ar_jitter_enable=>enable(2),r_base_enable=>enable(2),r_jitter_enable=>enable(2),
      base_latency=>base_latency,base_beat_gap=>base_beat_gap,
      ar_valid=>ar_valid(2),ar_ready=>ar_ready(2),
      ar_id=>s_ar_id,ar_addr=>s_ar_addr,ar_len=>s_ar_len,
      r_valid=>r_valid(2),r_ready=>r_ready(2),
      r_id=>r_id_2,r_data=>r_data_w4,r_resp=>open,r_last=>r_last(2));

  u_w8 : entity work.axi_mem_model
    generic map (GC_DATA_BYTES=>8,GC_ADDR_WIDTH=>C_ADDR_WIDTH,
      GC_ID_WIDTH=>C_ID_WIDTH,GC_AR_FIFO_DEPTH=>C_AR_FIFO_DEPTH,
      GC_TIMER_WIDTH=>C_TIMER_WIDTH)
    port map (aclk=>aclk,aresetn=>aresetn_dut(3),ar_base_enable=>enable(3),
      ar_jitter_enable=>enable(3),r_base_enable=>enable(3),r_jitter_enable=>enable(3),
      base_latency=>base_latency,base_beat_gap=>base_beat_gap,
      ar_valid=>ar_valid(3),ar_ready=>ar_ready(3),
      ar_id=>s_ar_id,ar_addr=>s_ar_addr,ar_len=>s_ar_len,
      r_valid=>r_valid(3),r_ready=>r_ready(3),
      r_id=>r_id_3,r_data=>r_data_w8,r_resp=>open,r_last=>r_last(3));

  u_w16 : entity work.axi_mem_model
    generic map (GC_DATA_BYTES=>16,GC_ADDR_WIDTH=>C_ADDR_WIDTH,
      GC_ID_WIDTH=>C_ID_WIDTH,GC_AR_FIFO_DEPTH=>C_AR_FIFO_DEPTH,
      GC_TIMER_WIDTH=>C_TIMER_WIDTH)
    port map (aclk=>aclk,aresetn=>aresetn_dut(4),ar_base_enable=>enable(4),
      ar_jitter_enable=>enable(4),r_base_enable=>enable(4),r_jitter_enable=>enable(4),
      base_latency=>base_latency,base_beat_gap=>base_beat_gap,
      ar_valid=>ar_valid(4),ar_ready=>ar_ready(4),
      ar_id=>s_ar_id,ar_addr=>s_ar_addr,ar_len=>s_ar_len,
      r_valid=>r_valid(4),r_ready=>r_ready(4),
      r_id=>r_id_4,r_data=>r_data_w16,r_resp=>open,r_last=>r_last(4));

  u_w32 : entity work.axi_mem_model
    generic map (GC_DATA_BYTES=>32,GC_ADDR_WIDTH=>C_ADDR_WIDTH,
      GC_ID_WIDTH=>C_ID_WIDTH,GC_AR_FIFO_DEPTH=>C_AR_FIFO_DEPTH,
      GC_TIMER_WIDTH=>C_TIMER_WIDTH)
    port map (aclk=>aclk,aresetn=>aresetn_dut(5),ar_base_enable=>enable(5),
      ar_jitter_enable=>enable(5),r_base_enable=>enable(5),r_jitter_enable=>enable(5),
      base_latency=>base_latency,base_beat_gap=>base_beat_gap,
      ar_valid=>ar_valid(5),ar_ready=>ar_ready(5),
      ar_id=>s_ar_id,ar_addr=>s_ar_addr,ar_len=>s_ar_len,
      r_valid=>r_valid(5),r_ready=>r_ready(5),
      r_id=>r_id_5,r_data=>r_data_w32,r_resp=>open,r_last=>r_last(5));

  u_w64 : entity work.axi_mem_model
    generic map (GC_DATA_BYTES=>64,GC_ADDR_WIDTH=>C_ADDR_WIDTH,
      GC_ID_WIDTH=>C_ID_WIDTH,GC_AR_FIFO_DEPTH=>C_AR_FIFO_DEPTH,
      GC_TIMER_WIDTH=>C_TIMER_WIDTH)
    port map (aclk=>aclk,aresetn=>aresetn_dut(6),ar_base_enable=>enable(6),
      ar_jitter_enable=>enable(6),r_base_enable=>enable(6),r_jitter_enable=>enable(6),
      base_latency=>base_latency,base_beat_gap=>base_beat_gap,
      ar_valid=>ar_valid(6),ar_ready=>ar_ready(6),
      ar_id=>s_ar_id,ar_addr=>s_ar_addr,ar_len=>s_ar_len,
      r_valid=>r_valid(6),r_ready=>r_ready(6),
      r_id=>r_id_6,r_data=>r_data_w64,r_resp=>open,r_last=>r_last(6));

  u_w128 : entity work.axi_mem_model
    generic map (GC_DATA_BYTES=>128,GC_ADDR_WIDTH=>C_ADDR_WIDTH,
      GC_ID_WIDTH=>C_ID_WIDTH,GC_AR_FIFO_DEPTH=>C_AR_FIFO_DEPTH,
      GC_TIMER_WIDTH=>C_TIMER_WIDTH)
    port map (aclk=>aclk,aresetn=>aresetn_dut(7),ar_base_enable=>enable(7),
      ar_jitter_enable=>enable(7),r_base_enable=>enable(7),r_jitter_enable=>enable(7),
      base_latency=>base_latency,base_beat_gap=>base_beat_gap,
      ar_valid=>ar_valid(7),ar_ready=>ar_ready(7),
      ar_id=>s_ar_id,ar_addr=>s_ar_addr,ar_len=>s_ar_len,
      r_valid=>r_valid(7),r_ready=>r_ready(7),
      r_id=>r_id_7,r_data=>r_data_w128,r_resp=>open,r_last=>r_last(7));

  -- =================================================================
  -- Main process
  -- =================================================================
  process
    variable l : line;
    variable rbuf : std_logic_vector(1023 downto 0);

    type r_id_array_t is array(0 to C_WCOUNT-1) of
      std_logic_vector(C_ID_WIDTH-1 downto 0);

    -- Build an array view of the r_id signals for indexed access
    impure function rid_sig return r_id_array_t is
      variable a : r_id_array_t;
    begin
      a(0):=r_id_0; a(1):=r_id_1; a(2):=r_id_2; a(3):=r_id_3;
      a(4):=r_id_4; a(5):=r_id_5; a(6):=r_id_6; a(7):=r_id_7;
      return a;
    end function;

    procedure send_ar(
      idx : natural; id : std_logic_vector;
      addr : std_logic_vector; len : std_logic_vector; tag : string
    ) is
    begin
      wait until rising_edge(aclk);
      s_ar_id <= id; s_ar_addr <= addr; s_ar_len <= len;
      ar_valid(idx) <= '1';
      wait until rising_edge(aclk) and ar_ready(idx) = '1';
      ar_valid(idx) <= '0';
      write(output, tag & "  AR: id=0x" & to_hstring(id) &
        " addr=0x" & to_hstring(addr) &
        " len=" & integer'image(to_integer(unsigned(len))) & CR);
    end procedure;

    procedure cap_rdata(dbytes : positive) is
    begin
      rbuf := (others => '0');
      case dbytes is
        when  1 => rbuf(  7 downto 0) := r_data_w1;
        when  2 => rbuf( 15 downto 0) := r_data_w2;
        when  4 => rbuf( 31 downto 0) := r_data_w4;
        when  8 => rbuf( 63 downto 0) := r_data_w8;
        when 16 => rbuf(127 downto 0) := r_data_w16;
        when 32 => rbuf(255 downto 0) := r_data_w32;
        when 64 => rbuf(511 downto 0) := r_data_w64;
        when 128 => rbuf                := r_data_w128;
        when others => null;
      end case;
    end procedure;

    procedure check_data(dbytes : positive; beat_base : unsigned(31 downto 0);
                         bidx : natural; tag : string) is
    begin
      if dbytes >= 4 then
        if rbuf(31 downto 0) /= std_logic_vector(beat_base) then
          report tag & " FAIL: data[31:0] beat " &
            integer'image(bidx) severity error;
        end if;
      elsif dbytes = 2 then
        if rbuf(15 downto 0) /= std_logic_vector(beat_base(15 downto 0)) then
          report tag & " FAIL: data[15:0] beat " &
            integer'image(bidx) severity error;
        end if;
      else
        if rbuf(7 downto 0) /= std_logic_vector(beat_base(7 downto 0)) then
          report tag & " FAIL: data[7:0] beat " &
            integer'image(bidx) severity error;
        end if;
      end if;
    end procedure;

    procedure drain(
      idx, dbytes, nbeats : natural;
      eid : std_logic_vector; eaddr : unsigned(31 downto 0); tag : string
    ) is
      variable bb : unsigned(31 downto 0);
      variable el : std_logic;
      variable rids : r_id_array_t;
    begin
      for b in 0 to nbeats - 1 loop
        wait until rising_edge(aclk) and r_valid(idx) = '1';
        cap_rdata(dbytes);
        rids := rid_sig;
        el := '0'; if b = nbeats - 1 then el := '1'; end if;
        if rids(idx) /= eid then
          report tag & " FAIL: id beat " & integer'image(b) severity error;
        end if;
        if r_last(idx) /= el then
          report tag & " FAIL: last beat " & integer'image(b) severity error;
        end if;
        bb := eaddr + b * dbytes;
        check_data(dbytes, bb, b, tag);
        if b = 0 or el = '1' then
          write(output, tag & "  beat " & integer'image(b) &
            " last=" & std_logic'image(r_last(idx)) & " OK" & CR);
        end if;
      end loop;
    end procedure;

    procedure run(idx, dbytes : natural; tag : string) is
      variable i : natural;
    begin
      write(output, tag & " (" & integer'image(dbytes) & " B)" & CR);

      -- P1
      write(output, tag & " P1 len=0" & CR);
      send_ar(idx, X"1", X"00001000", X"00", tag);
      drain  (idx, dbytes, 1, X"1", X"00001000", tag);

      -- P2
      write(output, tag & " P2 len=3" & CR);
      send_ar(idx, X"2", X"00002000", X"03", tag);
      drain  (idx, dbytes, 4, X"2", X"00002000", tag);

      -- P3
      write(output, tag & " P3 len=7" & CR);
      send_ar(idx, X"3", X"00003000", X"07", tag);
      drain  (idx, dbytes, 8, X"3", X"00003000", tag);

      -- P4 back-to-back
      write(output, tag & " P4 back-to-back" & CR);
      base_beat_gap <= std_logic_vector(to_unsigned(2, C_TIMER_WIDTH));
      wait for C_CLK_PERIOD;
      send_ar(idx, X"4", X"00004000", X"01", tag);
      send_ar(idx, X"5", X"00005000", X"02", tag);
      send_ar(idx, X"6", X"00006000", X"03", tag);
      drain  (idx, dbytes, 2, X"4", X"00004000", tag);
      drain  (idx, dbytes, 3, X"5", X"00005000", tag);
      drain  (idx, dbytes, 4, X"6", X"00006000", tag);
      base_beat_gap <= std_logic_vector(to_unsigned(3, C_TIMER_WIDTH));

      -- P5 zero-latency
      write(output, tag & " P5 zero-latency" & CR);
      enable(idx) <= '0';
      wait for C_CLK_PERIOD * 3;
      send_ar(idx, X"7", X"00007000", X"02", tag);
      drain  (idx, dbytes, 3, X"7", X"00007000", tag);
      enable(idx) <= '1';
      wait for C_CLK_PERIOD * 3;

      -- P6 max burst
      write(output, tag & " P6 len=255" & CR);
      base_beat_gap <= std_logic_vector(to_unsigned(2, C_TIMER_WIDTH));
      wait for C_CLK_PERIOD;
      send_ar(idx, X"8", X"00008000", X"FF", tag);
      drain  (idx, dbytes, 256, X"8", X"00008000", tag);
      base_beat_gap <= std_logic_vector(to_unsigned(3, C_TIMER_WIDTH));
      wait for C_CLK_PERIOD * 3;

      -- P7 FIFO-full
      write(output, tag & " P7 FIFO-full" & CR);
      base_beat_gap <= std_logic_vector(to_unsigned(4, C_TIMER_WIDTH));
      wait for C_CLK_PERIOD;
      for i in 0 to C_AR_FIFO_DEPTH-1 loop
        send_ar(idx,
          std_logic_vector(to_unsigned(i, C_ID_WIDTH)),
          std_logic_vector(to_unsigned(16#9000#+i*256, C_ADDR_WIDTH)),
          X"00", tag);
      end loop;
      wait until rising_edge(aclk);
      s_ar_id   <= std_logic_vector(
        to_unsigned(C_AR_FIFO_DEPTH, C_ID_WIDTH));
      s_ar_addr <= std_logic_vector(
        to_unsigned(16#9000#+C_AR_FIFO_DEPTH*256, C_ADDR_WIDTH));
      s_ar_len  <= X"00";
      ar_valid(idx) <= '1';
      wait until rising_edge(aclk);
      if ar_ready(idx) = '0' then
        write(output, tag & "  FIFO full OK" & CR);
      end if;
      wait until rising_edge(aclk) and ar_ready(idx) = '1';
      ar_valid(idx) <= '0';
      write(output, tag & "  last AR accepted" & CR);
      for i in 0 to C_AR_FIFO_DEPTH loop
        drain(idx, dbytes, 1,
          std_logic_vector(to_unsigned(i, C_ID_WIDTH)),
          to_unsigned(16#9000#+i*256, C_ADDR_WIDTH), tag);
      end loop;
      base_beat_gap <= std_logic_vector(to_unsigned(3, C_TIMER_WIDTH));

      -- P8 R-backpressure
      write(output, tag & " P8 R-backpressure" & CR);
      r_ready(idx) <= '0';
      wait for C_CLK_PERIOD;
      send_ar(idx, X"9", X"00009000", X"00", tag);
      for i in 0 to 60 loop
        wait until rising_edge(aclk);
        if r_valid(idx) = '1' then exit; end if;
      end loop;
      if r_valid(idx) = '0' then
        report tag & " FAIL: bp beat never arrived" severity error;
      else
        write(output, tag & "  beat arrived, held OK" & CR);
      end if;
      wait for C_CLK_PERIOD * 6;
      if r_valid(idx) = '1' then
        write(output, tag & "  r_valid held OK" & CR);
      else
        report tag & " FAIL: r_valid dropped" severity error;
      end if;
      r_ready(idx) <= '1';
      wait until rising_edge(aclk);
      write(output, tag & "  backpressure released OK" & CR);

      -- P9 reset-in-flight
      write(output, tag & " P9 reset-in-flight" & CR);
      send_ar(idx, X"E", X"0000E000", X"03", tag);
      wait until rising_edge(aclk) and r_valid(idx) = '1';
      write(output, tag & "  burst started, resetting" & CR);
      aresetn_dut(idx) <= '0';
      wait for C_CLK_PERIOD * 5;
      aresetn_dut(idx) <= '1';
      wait for C_CLK_PERIOD * 5;
      send_ar(idx, X"F", X"0000F000", X"00", tag);
      drain  (idx, dbytes, 1, X"F", X"0000F000", tag);
      write(output, tag & "  recovery OK" & CR);

      write(output, tag & " all OK" & CR);
    end procedure;

  begin
    write(l, string'("=== Reset ===")); writeline(output, l);
    aresetn      <= '0';
    aresetn_dut  <= (others => '0');
    enable       <= (others => '1');
    base_latency  <= std_logic_vector(to_unsigned(5, C_TIMER_WIDTH));
    base_beat_gap <= std_logic_vector(to_unsigned(3, C_TIMER_WIDTH));
    ar_valid     <= (others => '0');
    r_ready      <= (others => '1');
    wait for C_CLK_PERIOD * 5;
    aresetn <= '1';
    aresetn_dut <= (others => '1');
    wait for C_CLK_PERIOD * 3;
    write(l, string'("  OK")); writeline(output, l);
    writeline(output, l);

    run(0, 1,   C_WCFG_NAME(0)); writeline(output, l);
    run(1, 2,   C_WCFG_NAME(1)); writeline(output, l);
    run(2, 4,   C_WCFG_NAME(2)); writeline(output, l);
    run(3, 8,   C_WCFG_NAME(3)); writeline(output, l);
    run(4, 16,  C_WCFG_NAME(4)); writeline(output, l);
    run(5, 32,  C_WCFG_NAME(5)); writeline(output, l);
    run(6, 64,  C_WCFG_NAME(6)); writeline(output, l);
    run(7, 128, C_WCFG_NAME(7)); writeline(output, l);

    write(output, string'("All tests passed." & CR));
    sim_done <= true;
    wait;
  end process;

end architecture;
