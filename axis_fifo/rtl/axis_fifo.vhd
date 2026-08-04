-----------------------------------------------------------------------
--Filename         : axis_fifo.vhd
--Description      : Safe, Parameterizable Elastic Buffer (FBEB) with:
--                 :  - Inferring of shift-register LUTs (SRLs, on Xilinx 
--                 :    architectures) for depths > 2, or a double-buffer 
--                 :    if GC_FIFO_DEPTH = 2.
--                 :  - Simulation address-guarding for non-power-of-2 depths.
--                 :  - Unsigned occupancy level count output port (fifo_count).
--                 :  - Fully registered handshaking flow-control.
--                 :  - 100% combinational timing isolation between upstream and 
--                 :    downstream transaction domains (maximum Fmax).
--                 :  - Ports conforming strictly to AMBA AXI4-Stream specifications
--                 :    for direct automatic packaging into IP blocks.
--                 :  - VHDL-93 compliance for compatibility with Xilinx Vivado 
--                 :    block design tools and strict simulation environments.
--                 :  - Fully synchronous active-low reset logic (aresetn conforms
--                 :    to standard AXI clock-domain naming conventions).
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

entity axis_fifo is
  generic (
    GC_TDATA_WIDTH  : positive; -- Width of the unified AXI-Stream TDATA bus (can pack data + custom metadata)
    GC_FIFO_DEPTH   : positive range 2 to positive'high); 
  port (
    aclk            : in  std_logic;
    aresetn         : in  std_logic; -- Synchronous reset, active low (AMBA-compliant naming)
    
    -- Slave Interface (Input transaction payload)
    s_axis_tdata    : in  std_logic_vector (GC_TDATA_WIDTH-1 downto 0);
    s_axis_tvalid   : in  std_logic;
    s_axis_tready   : out std_logic;

    -- Master Interface (Output transaction payload)
    m_axis_tdata    : out std_logic_vector (GC_TDATA_WIDTH-1 downto 0);
    m_axis_tvalid   : out std_logic;
    m_axis_tready   : in  std_logic;

    fifo_count      : out unsigned (log2ceil(GC_FIFO_DEPTH) downto 0)); -- FIFO occupancy level
end entity;

architecture arch of axis_fifo is

  type t_srl is array (0 to GC_FIFO_DEPTH-1) of std_logic_vector (GC_TDATA_WIDTH-1 downto 0);

  -- state record definition
  type t_rec is record
    fifo_data      : t_srl;
    fifo_index     : signed (log2ceil(GC_FIFO_DEPTH) downto 0);
    s_axis_tready  : std_logic;
    m_axis_tvalid  : std_logic;
  end record;

  -- state record default and reset value
  -- NOTE: 'fifo_data' MUST be initialized to don't-care ('-') here.
  -- Zero-initializing (others => '0') would force the synthesis compiler to
  -- map the entire array using D-flip-flops (FDRE) containing hardware reset gates.
  -- Keeping it as don't-care allows the compiler to discard reset-routing 
  -- and infer highly compact Shift-Register LUT (SRL16E/SRL32E) primitives.
  constant C_REC_DEFAULT : t_rec := (
    fifo_data      => (others => (others => '-')), 
    fifo_index     => to_signed(-1, log2ceil(GC_FIFO_DEPTH) + 1),
    s_axis_tready  => '1',
    m_axis_tvalid  => '0');

  signal r    : t_rec := C_REC_DEFAULT; -- state
  signal r_in : t_rec;                  -- next state  
    
begin -- architecture

  -- Main Logic Process (Two-Process FSM/Register Style)
  p_logic: -- Explicit sensitivity list is VHDL93 compliant
           -- for compatibility with Vivado block design tools
  process(r, s_axis_tdata, s_axis_tvalid, m_axis_tready)
    variable v           : t_rec;
    variable read_index  : integer range 0 to GC_FIFO_DEPTH-1;
  begin
    -- recover stored state
    v := r;
    
    -- Safe address decoding to prevent out-of-range simulator crashes 
    -- in strict IEEE simulators when the FIFO is empty (r.fifo_index = -1)
    if r.fifo_index < 0 then
      read_index := 0;
    else
      read_index := to_integer(r.fifo_index);
    end if;

    -- Clean intermediate 32-bit integer conversion to prevent signed bit-width overflow warnings
    fifo_count      <= to_unsigned(to_integer(r.fifo_index) + 1, fifo_count'length);    
    m_axis_tdata    <= r.fifo_data(read_index);    
    s_axis_tready   <= r.s_axis_tready;
    m_axis_tvalid   <= r.m_axis_tvalid;
    
    -- --- Write and Shift Interface ---
    -- A push operation shifts the entire array forward, placing new data at index 0.
    -- This VHDL shift representation maps natively to Xilinx SRL primitives.
    if (s_axis_tvalid = '1') and (r.s_axis_tready = '1') then
      v.fifo_data(1 to GC_FIFO_DEPTH-1) := v.fifo_data (0 to GC_FIFO_DEPTH-2);
      v.fifo_data(0)                    := s_axis_tdata;
      
      -- If pushing without popping (increasing occupancy level)
      if (not ((m_axis_tready = '1') and (r.m_axis_tvalid = '1'))) then
        v.fifo_index := v.fifo_index + 1;  
      end if;

    -- --- Drain / Pop Interface ---
    -- If popping without pushing (decreasing occupancy level)
    elsif (m_axis_tready = '1') and (r.m_axis_tvalid = '1') then
      v.fifo_index := v.fifo_index - 1;        
    end if;
 
    -- --- Flow-Control Handshaking Flags generation ---
    -- Completely registered system flags: updates are latched on active clock edges.
    -- This isolates combinational paths, ensuring zero cascading path delays.
    -- AXI standard master drivers must keep valid high until ready asserts.
    if (v.fifo_index = GC_FIFO_DEPTH-1) then
      v.s_axis_tready  := '0'; -- FIFO is full, hold incoming writes
    else
      v.s_axis_tready  := '1';
    end if;
    
    if (v.fifo_index = -1) then
      v.m_axis_tvalid  := '0'; -- FIFO is empty, no data available
    else 
      v.m_axis_tvalid  := '1';
    end if;

    -- store state
    r_in <= v;
  end process;

  -- State-Holding Register Update Process
  p_reg:
  process(aclk)
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