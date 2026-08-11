-----------------------------------------------------------------------
--Filename         : axilite_io.vhd
--Description      : AXI4-Lite Slave to Register & Stream Bridge with:
--                 :  - Single-beat AXI4-Lite slave, 16-bit addr, 32-bit data.
--                 :  - Output registers (NUM_ODATA x 32-bit) writable via
--                 :    AXI4-Lite with byte-enable support (wstrb).
--                 :  - Input ports (NUM_IDATA x 32-bit) readable from bus.
--                 :  - AXI-Stream output channels (NUM_OSTREAM): write to
--                 :    address region 0x4000+ to push data.
--                 :  - AXI-Stream input channels (NUM_ISTREAM): read from
--                 :    address region 0xC000+ to pop data.
--                 :  - Address map: o_data at 0x0000, stream push at 0x4000,
--                 :    i_data at 0x8000, stream pop at 0xC000.
--Author           : Rune Baeverrud
--Current Revision : 1.00
--Licensing        : Zero-Clause BSD (0BSD)
--                 : Permission to use, copy, modify, and/or distribute this
--                 : software for any purpose with or without fee is hereby granted.
-----------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity axilite_io is
  generic (
    GC_NUM_ODATA   : natural := 2; -- Number of o_data register outputs
    GC_NUM_IDATA   : natural := 2; -- Number of i_data inputs
    GC_NUM_OSTREAM : natural := 2; -- Number of axi-stream outputs
    GC_NUM_ISTREAM : natural := 2  -- Number of axi-stream inputs
  );
  port (
    aclk          : in  std_logic;
    aresetn       : in  std_logic;

    s_axi_awaddr  : in  std_logic_vector(15 downto 0);
    s_axi_awprot  : in  std_logic_vector( 2 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;

    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector( 3 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;

    s_axi_bresp   : out std_logic_vector( 1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;

    s_axi_araddr  : in  std_logic_vector(15 downto 0);
    s_axi_arprot  : in  std_logic_vector( 2 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;

    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector( 1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;

    -- o_data registered outputs and i_data unregistered inputs
    o_data        : out slv32_array_t(0 to GC_NUM_ODATA-1);
    i_data        : in  slv32_array_t(0 to GC_NUM_IDATA-1);

    -- AXI-Stream outputs
    m_axis_tdata  : out std_logic_vector(31 downto 0);
    m_axis_tvalid : out std_logic_vector(GC_NUM_OSTREAM-1 downto 0);
  --m_axis_tready : in  std_logic; -- NOT IMPLEMENTED

    -- AXI-Stream inputs
    s_axis_tdata  : in  slv32_array_t(0 to GC_NUM_ISTREAM-1);
  --s_axis_tvalid : in  std_logic; -- NOT IMPLEMENTED
    s_axis_tready : out std_logic_vector(GC_NUM_ISTREAM-1 downto 0)
  );
end entity;

architecture rtl of axilite_io is

  -- Internal array type for the oregs storage
  subtype t_oregs_array is slv_array_t(0 to GC_NUM_ODATA-1)(31 downto 0);

  type t_rec is record
    oregs  : t_oregs_array;
    rdata  : std_logic_vector(31 downto 0);
    rvalid : std_logic;
    bvalid : std_logic;
  end record;

  constant C_REC_DEFAULT : t_rec := (
    oregs  => (others => (others => '0')),
    rdata  => (others => 'X'),
    rvalid => '0',
    bvalid => '0'
  );

  signal r, r_in : t_rec := C_REC_DEFAULT;

begin

  p_logic : process(all)
    variable v : t_rec;
  begin
    v := r;

    -- all input readys default de-asserted
    s_axi_awready <= '0';
    s_axi_wready  <= '0';
    s_axi_arready <= '0';
    s_axis_tready <= (others => '0');

    -- all output valids are default de-asserted
    m_axis_tdata  <= (others => 'X');
    m_axis_tvalid <= (others => '0');

    -- s_axi_r* output
    s_axi_rdata  <= r.rdata;
    s_axi_rresp  <= (others => '0');
    s_axi_rvalid <= r.rvalid;

    -- s_axi_b* output
    s_axi_bresp  <= (others => '0');
    s_axi_bvalid <= r.bvalid;

    -- if WRITE OPERATION
    if s_axi_awvalid = '1' and s_axi_wvalid = '1' and r.bvalid = '0' then
      -- *always* ack write command
      s_axi_awready <= '1';
      s_axi_wready  <= '1';
      v.bvalid      := '1'; -- write OK

      -- write to register with byte enables
      case s_axi_awaddr(15 downto 14) is
        when "00" =>
          for i in 0 to 3 loop
            if s_axi_wstrb(i) = '1' then
              v.oregs(to_integer(unsigned(
                s_axi_awaddr(log2ceil(GC_NUM_ODATA)+1 downto 2)
              )))(i*8+7 downto i*8) := s_axi_wdata(i*8+7 downto i*8);
            end if;
          end loop;

        when "01" =>
          m_axis_tdata  <= s_axi_wdata;
          m_axis_tvalid(to_integer(unsigned(
            s_axi_awaddr(log2ceil(GC_NUM_OSTREAM)+1 downto 2)
          ))) <= '1';

        when others => null;
      end case;
    end if;

    -- if READ OPERATION
    if s_axi_arvalid = '1' and r.rvalid = '0' then
      case s_axi_araddr(15 downto 14) is
        when "00" =>
          v.rdata := r.oregs(to_integer(unsigned(
            s_axi_araddr(log2ceil(GC_NUM_ODATA)+1 downto 2)
          )));

        when "01" =>
          v.rdata := (others => '0');

        when "10" =>
          v.rdata := i_data(to_integer(unsigned(
            s_axi_araddr(log2ceil(GC_NUM_IDATA)+1 downto 2)
          )));

        when "11" =>
          v.rdata := s_axis_tdata(to_integer(unsigned(
            s_axi_araddr(log2ceil(GC_NUM_ISTREAM)+1 downto 2)
          )));
          s_axis_tready(to_integer(unsigned(
            s_axi_araddr(log2ceil(GC_NUM_ISTREAM)+1 downto 2)
          ))) <= '1';

        when others => null;
      end case;
      v.rvalid      := '1';
      s_axi_arready <= '1';
    end if;

    if r.bvalid = '1' and s_axi_bready = '1' then v.bvalid := '0'; end if;
    if r.rvalid = '1' and s_axi_rready = '1' then v.rvalid := '0'; end if;

    o_data <= r.oregs;

    r_in <= v;
  end process;

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

end architecture;
