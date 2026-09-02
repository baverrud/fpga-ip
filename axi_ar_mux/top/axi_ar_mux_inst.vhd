-----------------------------------------------------------------------
--Filename         : axi_ar_mux_inst.vhd
--Description      : Instantiation template for axi_ar_mux_top.
--                 : client-to-native data-width and ARLEN conversion.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
-----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;  -- slv_array_t, slv8_array_t

entity axi_ar_mux_inst is
  generic (
    GC_NUM_CLIENTS         : positive := 4;
    GC_ADDR_WIDTH          : positive := 32;
    GC_ID_WIDTH            : positive := 4;
    GC_CLIENT_DATA_WIDTH   : positive := 512;
    GC_NATIVE_DATA_WIDTH   : positive := 128;
    GC_CLIENT_ARLEN_WIDTH  : positive := 6;
    GC_NATIVE_ARLEN_WIDTH  : positive range 1 to 8 := 8;
    GC_FIFO_DEPTH          : positive range 2 to positive'high := 32;
    GC_R_BEATS_PER_POP     : positive := 1;
    GC_BURST_TYPE          : std_logic_vector(1 downto 0) := "01"
  );
end entity axi_ar_mux_inst;

architecture rtl of axi_ar_mux_inst is
  signal aclk : std_logic;
  signal aresetn : std_logic;
  signal req_addr : slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_ADDR_WIDTH-1 downto 0);
  signal req_len : slv_array_t(0 to GC_NUM_CLIENTS-1)(GC_CLIENT_ARLEN_WIDTH-1 downto 0);
  signal req_valid : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal req_ready : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal r_pop : std_logic_vector(0 to GC_NUM_CLIENTS-1);
  signal ar_id : std_logic_vector(GC_ID_WIDTH-1 downto 0);
  signal ar_addr : std_logic_vector(GC_ADDR_WIDTH-1 downto 0);
  signal ar_len : std_logic_vector(GC_NATIVE_ARLEN_WIDTH-1 downto 0);
  signal ar_size : std_logic_vector(2 downto 0);
  signal ar_burst : std_logic_vector(1 downto 0);
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;

  constant C_RATIO       : positive := GC_CLIENT_DATA_WIDTH / GC_NATIVE_DATA_WIDTH;
  constant C_RATIO_LOG2  : natural := log2ceil(C_RATIO);
  constant C_NATIVE_SIZE : natural := log2ceil(GC_NATIVE_DATA_WIDTH / 8);

  signal core_req_len   : slv8_array_t(0 to GC_NUM_CLIENTS-1);
  signal core_ar_len    : std_logic_vector(7 downto 0);

  function f_native_arlen(client_arlen : std_logic_vector(7 downto 0))
    return std_logic_vector is
    variable native_beats : natural;
  begin
    native_beats := (to_integer(unsigned(client_arlen)) + 1) * C_RATIO;
    return std_logic_vector(to_unsigned(native_beats - 1, GC_NATIVE_ARLEN_WIDTH));
  end function;
begin

  assert GC_CLIENT_DATA_WIDTH >= GC_NATIVE_DATA_WIDTH
    report "axi_ar_mux_top: client data width must be >= native data width"
    severity failure;
  assert (GC_CLIENT_DATA_WIDTH mod GC_NATIVE_DATA_WIDTH) = 0
    report "axi_ar_mux_top: client/native data width ratio must be integral"
    severity failure;
  assert is_power_of_two(C_RATIO)
    report "axi_ar_mux_top: client/native data width ratio must be a power of two"
    severity failure;
  assert (GC_CLIENT_DATA_WIDTH mod 8) = 0 and
         (GC_NATIVE_DATA_WIDTH mod 8) = 0
    report "axi_ar_mux_top: data widths must be byte multiples"
    severity failure;
  assert is_power_of_two(GC_CLIENT_DATA_WIDTH / 8) and
         is_power_of_two(GC_NATIVE_DATA_WIDTH / 8)
    report "axi_ar_mux_top: data widths in bytes must be powers of two"
    severity failure;
  assert C_NATIVE_SIZE <= 7
    report "axi_ar_mux_top: AXI ARSIZE cannot encode the configured data width"
    severity failure;
  assert GC_CLIENT_ARLEN_WIDTH <= 8
    report "axi_ar_mux_top: client ARLEN width cannot exceed the core width"
    severity failure;
  assert GC_CLIENT_ARLEN_WIDTH + C_RATIO_LOG2 <= GC_NATIVE_ARLEN_WIDTH
    report "axi_ar_mux_top: native ARLEN width is too small for the conversion"
    severity failure;

  p_convert : process(all)
  begin
    for i in 0 to GC_NUM_CLIENTS-1 loop
      core_req_len(i) <= (others => '0');
      core_req_len(i)(GC_CLIENT_ARLEN_WIDTH-1 downto 0) <= req_len(i);
    end loop;
  end process;

  ar_len <= f_native_arlen(core_ar_len);
  ar_size <= std_logic_vector(to_unsigned(C_NATIVE_SIZE, 3));
  ar_burst <= GC_BURST_TYPE;

  u_core : entity work.axi_ar_mux
    generic map (
      GC_NUM_CLIENTS     => GC_NUM_CLIENTS,
      GC_ADDR_WIDTH      => GC_ADDR_WIDTH,
      GC_ID_WIDTH        => GC_ID_WIDTH,
      GC_FIFO_DEPTH      => GC_FIFO_DEPTH,
      GC_R_BEATS_PER_POP => GC_R_BEATS_PER_POP
    )
    port map (
      aclk      => aclk,
      aresetn   => aresetn,
      req_addr  => req_addr,
      req_len   => core_req_len,
      req_valid => req_valid,
      req_ready => req_ready,
      r_pop     => r_pop,
      ar_id     => ar_id,
      ar_addr   => ar_addr,
      ar_len    => core_ar_len,
      ar_valid  => ar_valid,
      ar_ready  => ar_ready
    );

end architecture;
