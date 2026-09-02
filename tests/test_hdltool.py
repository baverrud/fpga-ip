import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "tools"))
import hdltool


class HdlToolTests(unittest.TestCase):
    def test_vhdl_integer_generics_preserve_tokens(self):
        source = (
            "entity demo is\n"
            "  generic (\n"
            "    GC_VALUE : integer := 7\n"
            "  );\n"
            "end entity;\n"
        )
        formatted = hdltool.prettify_text(
            source, False, lang="vhdl", style="moderate", indent_width=2
        )
        self.assertIn("GC_VALUE : integer := 7", formatted)
        self.assertTrue(
            hdltool._check_invariant(source.splitlines(), formatted.splitlines())
        )

    def test_hdltool_preserves_vhdl_blank_lines_and_tokens(self):
        source = (
            "entity demo is\n"
            "\n"
            "\n"
            "  port (\n"
            "    data : in std_logic_vector (31 downto 0)\n"
            "  );\n"
            "\n"
            "end entity;\n"
        )
        formatted = hdltool.prettify_text(
            source, False, lang="vhdl", style="extreme", indent_width=2
        )
        self.assertEqual(source.count("\n\n"), formatted.count("\n\n"))
        self.assertTrue(
            hdltool._check_invariant(source.splitlines(), formatted.splitlines())
        )

    def test_vhdl_map_aligns_parentheses(self):
        lines = [
            "      a(31 downto 0) => a(31 downto 0),",
            "      longer_name(0) => longer_name(0),",
        ]
        rows = hdltool._align_vhd_map(
            lines, hdltool._STYLE_CFGS["extreme"]["vhd_map"]
        )
        text = rows
        self.assertEqual(len({line.index("(") for line in text}), 1)
        self.assertEqual(
            len({line.index("(", line.index("=>") + 2) for line in text}), 1
        )

    def test_systemverilog_extension_selects_sv_formatter(self):
        source = (
            "module demo (\n"
            "  input logic [7:0] data,\n"
            "  output logic ready\n"
            ");\n"
            "endmodule\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "demo.sv"
            path.write_text(source, encoding="utf-8")
            before, after, ok = hdltool.prettify_file(
                path, style="collapsed", indent_width=2
            )
        self.assertEqual(before, source)
        self.assertTrue(ok)
        self.assertIn("input logic [7:0] data", after)

    def test_directory_expansion_skips_generated_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.vhd"
            generated = root / "design.gen" / "generated.vhd"
            cached = root / "demo.cache" / "cached.vhd"
            source.write_text("entity source is end entity;\n", encoding="utf-8")
            generated.parent.mkdir()
            generated.write_text("entity generated is end entity;\n", encoding="utf-8")
            cached.parent.mkdir()
            cached.write_text("entity cached is end entity;\n", encoding="utf-8")
            expanded = hdltool.expand_format_paths([root])
            self.assertEqual(expanded, [source])

    def test_check_only_reads_and_analyzes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.vhd"
            path.write_text(
                "entity source is\n  port (data : in std_logic);\nend entity;\n",
                encoding="utf-8",
            )
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = hdltool.format_hdl([path], "extreme", True, 2)
            self.assertEqual(result, 0)
            self.assertIn("ok", output.getvalue())
            self.assertIn("port (data : in std_logic)", path.read_text(encoding="utf-8"))

    def test_search_wrappers_uses_xpr_bd_reference_and_scan(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / "demo.xpr"
            external = root / "external" / "design_1.bd"
            external.parent.mkdir()
            external.write_text("", encoding="utf-8")
            project.write_text(
                "<File Path=\"$PPRDIR/external/design_1.bd\"/>\n"
                "<File Path=\"$PPRDIR/design_1_wrapper.vhd\"/>\n",
                encoding="utf-8",
            )
            wrapper = root / "design_1_wrapper.vhd"
            wrapper.write_text("entity design_1_wrapper is end entity;\n", encoding="utf-8")
            _, references, scanned = hdltool.find_wrapper_references(project)
            self.assertEqual(len(references), 1)
            self.assertEqual(references[0][1], True)
            self.assertIn("design_1", scanned)
            self.assertEqual(references[0][3][0][1], "xpr")

    def test_analyze_identifies_master_names(self):
        source = (
            "entity demo_wrapper is\n"
            "  port (\n"
            "    pl_clk0 : out std_logic;\n"
            "    pl_resetn0 : out std_logic;\n"
            "    M00_AXI_0_awaddr : out std_logic_vector (39 downto 0); -- address\n"
            "    M00_AXI_0_awvalid : out std_logic_vector (0 to 0);\n"
            "    M00_AXI_0_awready : in std_logic_vector (0 to 0);\n"
            "    M01_AXI_0_awaddr : out std_logic_vector (39 downto 0);\n"
            "    M01_AXI_0_awvalid : out std_logic_vector (0 to 0);\n"
            "    M01_AXI_0_awready : in std_logic_vector (0 to 0);\n"
            "    M_AXI_HPM0_FPD_0_awaddr : out std_logic_vector (39 downto 0);\n"
            "    M_AXI_HPM0_FPD_0_awlen : out std_logic_vector (7 downto 0);\n"
            "    S_AXI_HP0_FPD_0_awaddr : in std_logic_vector (39 downto 0);\n"
            "    IIC_0_0_scl_io : inout std_logic;\n"
            "    SPI_0_0_io0_io : inout std_logic;\n"
            "    GPIO_0_tri_io : inout std_logic;\n"
            "    UART_0_rxd : in std_logic;\n"
            "    CAN_0_0_rx : in std_logic\n"
            "  );\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "demo_wrapper.vhd"
            path.write_text(source, encoding="utf-8")
            data = hdltool.analyze_wrapper(path)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = hdltool.command_analyze_wrapper(
                    type("Args", (), {"paths": [str(path)]})(), None
                )
            analysis_path = Path(directory) / "analysis.json"
            analysis_output = io.StringIO()
            with contextlib.redirect_stdout(analysis_output):
                analysis_result = hdltool.command_analyze_wrapper(
                    type(
                        "Args",
                        (),
                        {"paths": [str(path)], "analysis": str(analysis_path)},
                    )(),
                    None,
                )
            full_analysis = json.loads(analysis_path.read_text(encoding="utf-8"))
            name_map_path = Path(directory) / "name_map.json"
            map_output = io.StringIO()
            with contextlib.redirect_stdout(map_output):
                map_result = hdltool.command_analyze_wrapper(
                    type(
                        "Args",
                        (),
                        {"paths": [str(path)], "name_map": str(name_map_path)},
                    )(),
                    None,
                )
            saved_name_map = json.loads(name_map_path.read_text(encoding="utf-8"))

        self.assertEqual(result, 0)
        self.assertEqual(analysis_result, 0)
        self.assertEqual(map_result, 0)
        self.assertEqual(data["entity"], "demo_wrapper")
        self.assertEqual(
            data["master_names"],
            {
                "M00_AXI_0": "axilite0",
                "M01_AXI_0": "axilite1",
                "M_AXI_HPM0_FPD_0": "hpm0_fpd",
            },
        )
        self.assertEqual(
            data["master_arrays"]["axilite"]["members"]["0"]["name"],
            "axilite0",
        )
        self.assertEqual(
            data["master_arrays"]["axilite"]["members"]["1"]["original"],
            "M01_AXI_0",
        )
        self.assertEqual(
            set(data["peripheral_arrays"]), {"can", "gpio", "i2c", "spi", "uart"}
        )
        self.assertEqual(data["axi_buses"]["S_AXI_HP0_FPD_0"]["role"], "slave")
        self.assertEqual(json.loads(output.getvalue()), hdltool._analysis_name_map_file(data))
        self.assertIn("axi_buses", full_analysis)
        self.assertNotIn("clocks_reset", full_analysis)
        self.assertNotIn("interrupts", full_analysis)
        self.assertEqual(
            saved_name_map["_interfaces"]["M[]_AXI_0"], "axilite[]"
        )
        self.assertEqual(
            saved_name_map["_indexable"]["SPI_[]_0"], "spi[]"
        )
        self.assertEqual(
            saved_name_map["_non_indexable"]["pl_clk[]"], "ps_clk[]"
        )
        self.assertNotIn("_comments", saved_name_map)
        self.assertEqual(
            hdltool.resolve_name_mapping("M01_AXI_0", saved_name_map), "axilite1"
        )
        self.assertEqual(
            hdltool.resolve_name_mapping("SPI_1_0_io0_io", saved_name_map),
            "spi1_io0_io",
        )
        self.assertEqual(
            hdltool.resolve_name_mapping("M01_AXI_0_awaddr", saved_name_map),
            "axilite1_awaddr",
        )
        self.assertEqual(
            hdltool.resolve_name_mapping("pl_resetn0", saved_name_map),
            "ps_srstn0",
        )
        self.assertNotIn("axi_buses", saved_name_map)
        self.assertIn("wrote", map_output.getvalue())

    def test_json_output_aligns_colons_per_object(self):
        value = {
            "short": "value",
            "longer_key": {"a": 1, "longer": 2},
        }
        rendered = hdltool._json_dumps_aligned(value)
        parsed = json.loads(rendered)
        self.assertEqual(parsed, value)

        top_level = [line for line in rendered.splitlines() if line.startswith('  "')]
        nested = [line for line in rendered.splitlines() if line.startswith('    "')]
        self.assertEqual(len({line.index(":") for line in top_level}), 1)
        self.assertEqual(len({line.index(":") for line in nested}), 1)

        name_map = {
            "_non_indexable": {"FCLK_CLK[]": "ps_clk[]"},
            "_indexable": {
                "CAN_[]_0": "can[]",
                "S_AXI_HP[]_0": "hp[]",
            },
        }
        rendered_map = hdltool._json_dumps_aligned(name_map)
        pattern_lines = [
            line for line in rendered_map.splitlines()
            if any(pattern in line for pattern in ("FCLK_CLK[]", "CAN_[]_0", "S_AXI_HP[]_0"))
        ]
        self.assertEqual(len({line.index(":") for line in pattern_lines}), 1)

    def test_load_name_map_validates_patterns_and_collisions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "name_map.json"
            path.write_text(
                '{"_patterns": {"SPI_[]_0": "spi[]"}, "special": "custom"}',
                encoding="utf-8",
            )
            mapping = hdltool.load_name_map(
                path, source_names=["SPI_0_0_sck_io", "special", "untouched"]
            )
        self.assertEqual(
            hdltool.resolve_name_mapping("SPI_1_0_sck_io", mapping),
            "spi1_sck_io",
        )
        self.assertEqual(hdltool.resolve_name_mapping("untouched", mapping), "untouched")

        with self.assertRaises(ValueError):
            hdltool.validate_name_map({"_patterns": {"M[]": "bad"}})
        with self.assertRaises(ValueError):
            hdltool.validate_name_map(
                {"first": "same", "second": "same"},
                source_names=["first", "second"],
            )

    def test_name_map_supports_index_offsets(self):
        mapping = {
            "_patterns": {
                "GPIO_[]_0": "gpio[]",
                "gpio_rtl_[]": "gpio[2]",
            }
        }
        hdltool.validate_name_map(
            mapping,
            source_names=[
                "GPIO_0_0_tri_io",
                "gpio_rtl_0_tri_io",
                "gpio_rtl_1_tri_io",
            ],
        )
        self.assertEqual(
            hdltool.resolve_name_mapping("GPIO_0_0_tri_io", mapping),
            "gpio0_tri_io",
        )
        self.assertEqual(
            hdltool.resolve_name_mapping("gpio_rtl_0_tri_io", mapping),
            "gpio2_tri_io",
        )
        self.assertEqual(
            hdltool.resolve_name_mapping("gpio_rtl_1_tri_io", mapping),
            "gpio3_tri_io",
        )

    def test_unknown_rtl_family_is_indexable_by_default_rule(self):
        source = (
            "entity custom_wrapper is\n"
            "  port (\n"
            "    custom_rtl_0_data : in std_logic;\n"
            "    custom_rtl_1_data : in std_logic\n"
            "  );\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            wrapper = Path(directory) / "custom_wrapper.vhd"
            wrapper.write_text(source, encoding="utf-8")
            data = hdltool.analyze_wrapper(wrapper)
            name_map = {
                "_non_indexable": {},
                "_indexable": {"custom_rtl_[]": "custom[]"},
            }
            declarations, mappings = hdltool._generation_port_lines(
                data, name_map, "slv-array"
            )

        declaration_types = {name: type_text for name, _direction, type_text in declarations}
        mapping_targets = dict(mappings)
        self.assertEqual(declaration_types["custom_data"], "std_logic_vector(1 downto 0)")
        self.assertEqual(mapping_targets["custom_rtl_0_data"], "custom_data(0)")
        self.assertEqual(mapping_targets["custom_rtl_1_data"], "custom_data(1)")

    def test_indexable_pattern_selects_prefix_before_field_digits(self):
        source = (
            "entity numbered_wrapper is\n"
            "  port (\n"
            "    foo2_0_data : in std_logic;\n"
            "    foo2_1_data : in std_logic\n"
            "  );\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            wrapper = Path(directory) / "numbered_wrapper.vhd"
            wrapper.write_text(source, encoding="utf-8")
            data = hdltool.analyze_wrapper(wrapper)
            name_map = {
                "_non_indexable": {},
                "_indexable": {"foo2_[]": "bar[]"},
            }
            declarations, mappings = hdltool._generation_port_lines(
                data, name_map, "slv-array"
            )

        declaration_types = {name: type_text for name, _direction, type_text in declarations}
        mapping_targets = dict(mappings)
        self.assertEqual(declaration_types["bar_data"], "std_logic_vector(1 downto 0)")
        self.assertEqual(mapping_targets["foo2_0_data"], "bar_data(0)")
        self.assertEqual(mapping_targets["foo2_1_data"], "bar_data(1)")

    def test_indexable_interrupts_are_grouped(self):
        source = (
            "entity interrupt_wrapper is\n"
            "  port (\n"
            "    interrupt_0_status : out std_logic;\n"
            "    interrupt_1_status : out std_logic\n"
            "  );\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            wrapper = Path(directory) / "interrupt_wrapper.vhd"
            wrapper.write_text(source, encoding="utf-8")
            data = hdltool.analyze_wrapper(wrapper)
            name_map = {
                "_non_indexable": {},
                "_indexable": {"interrupt_[]": "alarm[]"},
            }
            declarations, mappings = hdltool._generation_port_lines(
                data, name_map, "slv-array"
            )

        declaration_types = {name: type_text for name, _direction, type_text in declarations}
        mapping_targets = dict(mappings)
        self.assertEqual(declaration_types["alarm_status"], "std_logic_vector(1 downto 0)")
        self.assertEqual(mapping_targets["interrupt_0_status"], "alarm_status(0)")
        self.assertEqual(mapping_targets["interrupt_1_status"], "alarm_status(1)")

    def test_singleton_indexable_groups_collapse_outer_dimension(self):
        source = (
            "entity singleton_wrapper is\n"
            "  port (\n"
            "    CAN_0_0_rx : in std_logic;\n"
            "    GPIO_0_0_tri_io : inout std_logic_vector (94 downto 0)\n"
            "  );\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            wrapper = Path(directory) / "singleton_wrapper.vhd"
            wrapper.write_text(source, encoding="utf-8")
            data = hdltool.analyze_wrapper(wrapper)
            name_map = {
                "_non_indexable": {},
                "_indexable": {
                    "CAN_[]_0": "can[]",
                    "GPIO_[]_0": "ps_gpio[]",
                },
            }
            declarations, mappings = hdltool._generation_port_lines(
                data, name_map, "slv-array"
            )

        declaration_types = {
            name: type_text
            for name, _direction, type_text in declarations
        }
        mapping_targets = dict(mappings)
        self.assertEqual(declaration_types["can_rx"], "std_logic")
        self.assertEqual(declaration_types["ps_gpio"], "std_logic_vector(94 downto 0)")
        self.assertEqual(mapping_targets["CAN_0_0_rx"], "can_rx")
        self.assertEqual(mapping_targets["GPIO_0_0_tri_io"], "ps_gpio")

    def test_singleton_mode_view_array_bus_collapses_to_scalar_view(self):
        source = (
            "entity singleton_bus_wrapper is\n"
            "  port (\n"
            "    M00_AXI_0_awaddr : out std_logic_vector (31 downto 0);\n"
            "    M00_AXI_0_awvalid : out std_logic;\n"
            "    M00_AXI_0_awready : in std_logic\n"
            "  );\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            wrapper = Path(directory) / "singleton_bus_wrapper.vhd"
            wrapper.write_text(source, encoding="utf-8")
            data = hdltool.analyze_wrapper(wrapper)
            name_map = {
                "_interfaces": {"M[]_AXI_0": "axilite[]"},
            }
            declarations, mappings = hdltool._generation_port_lines(
                data, name_map, "mode-view-array"
            )

        self.assertIn(
            ("axilite0", "view", "view master_axilite of axilite_m32_t"),
            declarations,
        )
        self.assertNotIn("axilite_m32_array_t", str(declarations))
        self.assertEqual(mappings[0][1], "axilite0.awaddr")

    def test_generated_ranges_use_downto(self):
        self.assertEqual(
            hdltool._generation_descending_range("(0 to 7)"),
            "(7 downto 0)",
        )
        self.assertEqual(
            hdltool._generation_descending_range("(7 downto 0)"),
            "(7 downto 0)",
        )

    def test_generate_all_profiles_and_zero_port_tops(self):
        source = (
            "entity demo_wrapper is\n"
            "  port (\n"
            "    pl_clk0 : out std_logic;\n"
            "    M00_AXI_0_awaddr : out std_logic_vector (39 downto 0);\n"
            "    M00_AXI_0_awvalid : out std_logic_vector (0 to 0);\n"
            "    M00_AXI_0_awready : in std_logic_vector (0 to 0);\n"
            "    M01_AXI_0_awaddr : out std_logic_vector (39 downto 0);\n"
            "    M01_AXI_0_awvalid : out std_logic_vector (0 to 0);\n"
            "    M01_AXI_0_awready : in std_logic_vector (0 to 0)\n"
            "  );\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            wrapper = Path(directory) / "demo_wrapper.vhd"
            output_dir = Path(directory) / "generated"
            wrapper.write_text(source, encoding="utf-8")
            _data, _name_map, outputs = hdltool.generate_vhdl_variants(
                wrapper, output_dir=output_dir
            )
            generated = {
                path.name: path.read_text(encoding="utf-8") for path in outputs
            }

        self.assertEqual(len(generated), 8)
        self.assertTrue(
            any(
                "M00_AXI_0_awaddr" in line and "=> axilite0_awaddr" in line
                for line in generated["ps_flat.vhd"].splitlines()
            )
        )
        self.assertTrue(
            any(
                "M00_AXI_0_awaddr" in line and "=> axilite_awaddr(0)" in line
                for line in generated["ps_slv_array.vhd"].splitlines()
            )
        )
        self.assertIn(
            "axilite_awvalid : out std_logic_vector(1 downto 0)",
            generated["ps_slv_array.vhd"],
        )
        self.assertIn(
            "M00_AXI_0_awvalid(0) => axilite_awvalid(0)",
            generated["ps_slv_array.vhd"],
        )
        flat_axi = generated["ps_flat.vhd"]
        flat_axi_positions = [
            flat_axi.index(f"axilite0_{suffix}")
            for suffix in ("awaddr", "awvalid", "awready")
        ]
        self.assertEqual(flat_axi_positions, sorted(flat_axi_positions))
        self.assertNotIn("axilite_awvalid(0)(0)", generated["ps_slv_array.vhd"])
        self.assertNotIn("axilite_awaddr(0).", generated["ps_slv_array.vhd"])
        self.assertTrue(
            any(
                "M00_AXI_0_awaddr" in line and "=> axilite0.awaddr" in line
                for line in generated["ps_mode_view.vhd"].splitlines()
            )
        )
        self.assertTrue(
            any(
                "M00_AXI_0_awaddr" in line and "=> axilite(0).awaddr" in line
                for line in generated["ps_mode_view_array.vhd"].splitlines()
            )
        )
        self.assertIn("signal axilite0 : axilite_m40_t;", generated["ps_mode_view_top.vhd"])
        self.assertNotIn("signal axilite0 : axilite_t;", generated["ps_mode_view_top.vhd"])
        self.assertIn("use work.axilite_pkg.all;", generated["ps_mode_view_top.vhd"])
        self.assertNotIn("use work.axi3_pkg.all;", generated["ps_mode_view_top.vhd"])
        self.assertNotIn("use work.axi4_pkg.all;", generated["ps_mode_view_top.vhd"])
        self.assertNotIn("use work.axis_pkg.all;", generated["ps_mode_view_top.vhd"])
        self.assertIn("-- AXI M00_AXI_0", generated["ps_flat.vhd"])
        self.assertNotIn("-- M00_AXI_0_awaddr", generated["ps_flat.vhd"])
        self.assertNotIn("-- collapsed scalar", generated["ps_flat.vhd"])
        for name, text in generated.items():
            if name.endswith("_top.vhd"):
                self.assertIn("end entity", text)
                self.assertNotIn("  port (", text)

    def test_interfaces_group_controls_mode_view_buses(self):
        source = (
            "entity interface_wrapper is\n"
            "  port (\n"
            "    M00_AXI_0_awaddr : out std_logic_vector (31 downto 0);\n"
            "    M00_AXI_0_awvalid : out std_logic;\n"
            "    M01_AXI_0_awaddr : out std_logic_vector (31 downto 0);\n"
            "    M01_AXI_0_awvalid : out std_logic\n"
            "  );\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrapper = root / "interface_wrapper.vhd"
            mapping = root / "name_map.json"
            wrapper.write_text(source, encoding="utf-8")
            mapping.write_text(
                '{"_interfaces": {"M00_AXI_0": "axilite0"}}',
                encoding="utf-8",
            )
            _, _, outputs = hdltool.generate_vhdl_variants(
                wrapper,
                output_dir=root / "generated",
                name_map_path=mapping,
                profiles=("flat", "mode-view"),
            )
            flat = outputs[0].read_text(encoding="utf-8")
            mode_view = outputs[2].read_text(encoding="utf-8")
            mode_view_top = outputs[3].read_text(encoding="utf-8")

        self.assertIn("M00_AXI_0_awaddr", flat)
        self.assertIn("M01_AXI_0_awaddr", flat)
        self.assertIn("M00_AXI_0_awaddr", mode_view)
        self.assertNotIn("M01_AXI_0_awaddr", mode_view)
        self.assertIn("signal axilite0 : axilite_m32_t;", mode_view_top)

    def test_mode_view_rejects_unconstrained_bus_fallbacks(self):
        with self.assertRaises(ValueError):
            hdltool._generation_bus_type({"protocol": "AXI3"}, "custom_axi")
        with self.assertRaises(ValueError):
            hdltool._generation_bus_type({"protocol": "AXI4"}, "custom_axi")
        with self.assertRaises(ValueError):
            hdltool._generation_bus_type({"protocol": "AXIS"}, "custom_axis")

    def test_full_axi_master_is_not_named_axilite(self):
        source = (
            "entity full_wrapper is\n"
            "  port (\n"
            "    M00_AXI_0_awaddr : out std_logic_vector (39 downto 0);\n"
            "    M00_AXI_0_awlen : out std_logic_vector (7 downto 0);\n"
            "    M00_AXI_0_awqos : out std_logic_vector (3 downto 0);\n"
            "    M00_AXI_0_awvalid : out std_logic_vector (0 to 0);\n"
            "    M00_AXI_0_awready : in std_logic_vector (0 to 0)\n"
            "  );\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            wrapper = Path(directory) / "full_wrapper.vhd"
            wrapper.write_text(source, encoding="utf-8")
            data = hdltool.analyze_wrapper(wrapper)
            _, _, outputs = hdltool.generate_vhdl_variants(
                wrapper, output_dir=Path(directory) / "generated", profiles=("flat",)
            )
            shim = outputs[0].read_text(encoding="utf-8")
        self.assertEqual(data["axi_buses"]["M00_AXI_0"]["protocol"], "AXI4")
        self.assertEqual(data["name_map"]["M00_AXI_0"], "axi0")
        self.assertNotIn("axilite0_awqos", shim)
        self.assertIn("axi0_awqos", shim)

    def test_generation_rejects_stale_axilite_mapping_for_axi4(self):
        source = (
            "entity stale_wrapper is\n"
            "  port (\n"
            "    M00_AXI_0_awaddr : out std_logic_vector (39 downto 0);\n"
            "    M00_AXI_0_awqos : out std_logic_vector (3 downto 0);\n"
            "    M00_AXI_0_awvalid : out std_logic_vector (0 to 0);\n"
            "    M00_AXI_0_awready : in std_logic_vector (0 to 0)\n"
            "  );\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            wrapper = Path(directory) / "stale_wrapper.vhd"
            mapping = Path(directory) / "name_map.json"
            wrapper.write_text(source, encoding="utf-8")
            mapping.write_text(
                '{"_patterns": {"M[]_AXI_0": "axilite[]"}}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "classified as AXI4"):
                hdltool.generate_vhdl_variants(
                    wrapper, output_dir=Path(directory) / "generated",
                    name_map_path=mapping,
                )

    def test_vivado_wrapper_corpus_detects_required_categories(self):
        vivado_root = Path(__file__).parents[4] / "viv"
        if not vivado_root.is_dir():
            self.skipTest("Vivado wrapper corpus is not available")

        wrappers = sorted(vivado_root.rglob("*_wrapper.vhd"))
        self.assertTrue(wrappers)
        protocols = set()
        peripherals = set()
        peripheral_arrays = set()
        for path in wrappers:
            data = hdltool.analyze_wrapper(path)
            compact_map = hdltool._analysis_name_map_file(data)
            for original, friendly in data["name_map"].items():
                if original.upper() == "DDR" or original.upper().startswith(("DDR_", "FIXED_IO_")):
                    self.assertEqual(
                        hdltool.resolve_name_mapping(original, compact_map), original
                    )
                    self.assertNotIn(original, compact_map)
                    continue
                self.assertEqual(
                    hdltool.resolve_name_mapping(original, compact_map), friendly
                )
            clock_names = [
                signal["name"].lower()
                for signal in data["other_ports"]
            ]
            self.assertTrue(any("clk" in name or "clock" in name for name in clock_names))
            self.assertTrue(any("rst" in name or "reset" in name for name in clock_names))
            self.assertTrue(data["master_names"])
            protocols.update(
                bus["protocol"] for bus in data["axi_buses"].values()
            )
            names = " ".join(
                list(data["name_map"].keys()) + list(data["name_map"].values())
            ).lower()
            peripherals.update(
                name for name in ("i2c", "spi", "uart", "can", "gpio") if name in names
            )
            peripheral_arrays.update(data["peripheral_arrays"])

        self.assertIn("AXI4", protocols)
        self.assertIn("AXI-Lite", protocols)
        self.assertEqual(peripherals, {"i2c", "spi", "uart", "can", "gpio"})
        self.assertEqual(
            peripheral_arrays, {"i2c", "spi", "uart", "can", "gpio"}
        )

    def test_analyze_without_path_discovers_project_wrapper(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / "demo.xpr"
            wrapper_dir = root / "demo.gen" / "sources_1" / "bd" / "design_1" / "hdl"
            wrapper_dir.mkdir(parents=True)
            (wrapper_dir / "design_1_wrapper.vhd").write_text(
                "entity design_1_wrapper is\n"
                "  port (pl_clk0 : out std_logic);\n"
                "end entity;\n",
                encoding="utf-8",
            )
            project.write_text(
                '<File Path="$PGENDIR/sources_1/bd/design_1/hdl/design_1_wrapper.vhd"/>\n',
                encoding="utf-8",
            )
            import os
            original_directory = Path.cwd()
            try:
                os.chdir(root)
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    result = hdltool.main(["analyze-wrapper"])
                saved = json.loads((root / "name_map.json").read_text(encoding="utf-8"))
            finally:
                os.chdir(original_directory)

        self.assertEqual(result, 0)
        self.assertEqual(hdltool.resolve_name_mapping("pl_clk0", saved), "ps_clk0")
        self.assertIn("wrote", output.getvalue())

    def test_pynq_wrapper_generates_mixed_axi_profiles(self):
        wrapper = (
            Path(__file__).parents[4]
            / "viv"
            / "emio"
            / "pynqz2"
            / "pynqz2.gen"
            / "sources_1"
            / "bd"
            / "design_1"
            / "hdl"
            / "design_1_wrapper.vhd"
        )
        if not wrapper.is_file():
            self.skipTest("PYNQ-Z2 wrapper is not available")

        data = hdltool.analyze_wrapper(wrapper)
        self.assertEqual(data["axi_buses"]["M00_AXI_0"]["protocol"], "AXI-Lite")
        self.assertEqual(data["axi_buses"]["S_AXI_HP0_0"]["protocol"], "AXI3")
        self.assertNotEqual(data["name_map"]["DDR_reset_n"], data["name_map"]["FIXED_IO_ps_srstb"])
        compact_map = hdltool._analysis_name_map_file(data)
        self.assertEqual(compact_map["_ignore"], ["DDR*", "FIXED_IO_*"])
        self.assertNotIn("DDR", compact_map)
        self.assertNotIn("DDR_reset_n", compact_map)
        self.assertNotIn("FIXED_IO_ps_srstb", compact_map)
        self.assertEqual(compact_map["_interfaces"]["S_AXI_HP[]_0"], "hp[]")
        self.assertEqual(compact_map["_indexable"]["IIC_[]"], "i2c[]")
        self.assertEqual(compact_map["_indexable"]["IIC_[]_0"], "i2c[]_0")
        self.assertNotIn("S_AXI_HP0_0", compact_map)
        self.assertNotIn("S_AXI_HP1_0", compact_map)
        self.assertNotIn("IIC_0_0_scl_io", compact_map)
        self.assertNotIn("IIC_1_0_scl_io", compact_map)
        self.assertEqual(
            compact_map["_indexable"]["spi_rtl_[]"], "spi_rtl[]"
        )
        self.assertEqual(
            hdltool.resolve_name_mapping("S_AXI_HP1_0", compact_map), "hp1"
        )
        self.assertEqual(
            hdltool.resolve_name_mapping("IIC_1_0_scl_io", compact_map),
            "i2c1_0_scl_io",
        )
        mapped_map = {
            **compact_map,
            "_non_indexable": dict(compact_map["_non_indexable"]),
            "_indexable": {
                **compact_map["_indexable"],
                "FCLK_CLK[]": "ps_clk[]",
                "IIC_[]": "pl_i2c[]",
                "IIC_[]_0": "ps_i2c[]",
                "SPI_[]_0": "ps_spi[]",
                "spi_rtl_[]": "pl_spi[]",
            },
        }
        mode_declarations, mode_mappings = hdltool._generation_port_lines(
            data, mapped_map, "mode-view"
        )
        mode_types = {
            name: type_text
            for name, _direction, type_text in mode_declarations
        }
        mode_targets = dict(mode_mappings)
        self.assertEqual(mode_types["ps_i2c_scl"], "std_logic_vector(1 downto 0)")
        self.assertEqual(mode_types["pl_i2c_scl"], "std_logic_vector(1 downto 0)")
        self.assertEqual(mode_types["pl_spi_io0"], "std_logic_vector(1 downto 0)")
        self.assertEqual(mode_targets["IIC_0_scl_io"], "pl_i2c_scl(0)")
        self.assertEqual(mode_targets["spi_rtl_1_io0_io"], "pl_spi_io0(1)")
        declarations, mappings = hdltool._generation_port_lines(
            data, mapped_map, "slv-array"
        )
        declaration_types = {name: type_text for name, _direction, type_text in declarations}
        mapping_targets = dict(mappings)
        self.assertEqual(declaration_types["pl_spi_io0"], "std_logic_vector(1 downto 0)")
        self.assertEqual(declaration_types["pl_spi_io1"], "std_logic_vector(1 downto 0)")
        self.assertEqual(declaration_types["pl_spi_ss"], "std_logic_vector(1 downto 0)")
        self.assertEqual(declaration_types["ps_clk"], "std_logic_vector(1 downto 0)")
        self.assertEqual(mapping_targets["FCLK_CLK0"], "ps_clk(0)")
        self.assertEqual(mapping_targets["spi_rtl_0_io0_io"], "pl_spi_io0(0)")
        self.assertEqual(
            hdltool.resolve_name_mapping("IIC_1_scl_io", compact_map),
            "i2c1_scl_io",
        )
        with tempfile.TemporaryDirectory() as directory:
            _, _, outputs = hdltool.generate_vhdl_variants(
                wrapper, output_dir=Path(directory)
            )
            generated = {
                path.name: path.read_text(encoding="utf-8") for path in outputs
            }
        self.assertEqual(len(outputs), 8)
        self.assertIn("signal hp0 : axi3_hp_t;", generated["ps_mode_view_top.vhd"])
        self.assertNotIn("signal hp0 : axi3_t;", generated["ps_mode_view_top.vhd"])
        self.assertIn(
            "hp : view (slave_axi3) of axi3_hp_array_t(1 downto 0);",
            generated["ps_mode_view_array.vhd"],
        )
        for text in generated.values():
            self.assertNotIn("DDR_", text)
            self.assertNotIn("FIXED_IO_", text)
        flat = generated["ps_flat.vhd"]
        self.assertEqual(flat.count("-- i2c"), 2)
        self.assertNotIn("-- i2c0", flat)
        self.assertNotIn("-- i2c1", flat)
        self.assertIn("i2c0_scl", flat)
        self.assertRegex(flat, r"IIC_0_scl_io\s*=>\s*i2c0_scl,")
        self.assertNotRegex(flat, r"IIC_0_scl_io\s*=>\s*i2c0_scl_io")
        self.assertIn("gpio0 : inout std_logic_vector", flat)
        self.assertRegex(flat, r"SPI_0_0_ss1_o\s*=>\s*spi0_ss1,")
        self.assertIn("uart0_rx : in  std_logic", flat)
        self.assertIn("UART_0_rxd => uart0_rx", flat)
        self.assertIn("uart0_tx : out std_logic", flat)
        self.assertIn("UART_0_txd => uart0_tx", flat)
        self.assertEqual(flat.count("-- can"), 2)
        self.assertNotIn("-- can0", flat)
        self.assertNotIn("-- can1", flat)
        self.assertEqual(flat.count("-- spi"), 2)
        self.assertNotIn("-- spi0", flat)
        self.assertNotIn("-- spi1", flat)
        self.assertEqual(flat.count("-- uart"), 2)
        self.assertNotIn("-- uart0", flat)
        self.assertNotIn("-- uart1", flat)
        self.assertNotIn("-- collapsed scalar", flat)
        slv_array = generated["ps_slv_array.vhd"]
        self.assertIn("hp_awaddr  : in  slv_array_t(1 downto 0)(31 downto 0)", slv_array)
        self.assertIn("hp_awvalid : in  std_logic_vector(1 downto 0)", slv_array)
        self.assertRegex(slv_array, r"S_AXI_HP0_0_awaddr\s*=>\s*hp_awaddr\(0\),")
        self.assertRegex(slv_array, r"S_AXI_HP1_0_awaddr\s*=>\s*hp_awaddr\(1\),")
        self.assertNotIn("hp0_awaddr : in std_logic_vector", slv_array)
        self.assertEqual(flat.count("-- can"), 2)
        self.assertNotIn("-- can0", flat)
        self.assertNotIn("-- can1", flat)
        self.assertNotIn("-- collapsed scalar", flat)

    def test_generation_respects_custom_ignore_patterns(self):
        source = (
            "entity ignore_wrapper is\n"
            "  port (\n"
            "    KEEP_signal : in std_logic;\n"
            "    DROP_signal : in std_logic\n"
            "  );\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrapper = root / "ignore_wrapper.vhd"
            mapping = root / "name_map.json"
            wrapper.write_text(source, encoding="utf-8")
            mapping.write_text(
                '{"_ignore": ["DROP_*"]}', encoding="utf-8"
            )
            _, _, outputs = hdltool.generate_vhdl_variants(
                wrapper, output_dir=root / "generated", name_map_path=mapping,
                profiles=("flat",)
            )
            shim = outputs[0].read_text(encoding="utf-8")
        self.assertIn("KEEP_signal", shim)
        self.assertNotIn("DROP_signal", shim)

    def test_generation_defaults_use_current_directory(self):
        source = (
            "entity default_wrapper is\n"
            "  port (\n"
            "    source_signal : in std_logic\n"
            "  );\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrapper = root / "default_wrapper.vhd"
            wrapper.write_text(source, encoding="utf-8")
            (root / "name_map.json").write_text(
                '{"source_signal": "mapped_signal"}', encoding="utf-8"
            )
            original_directory = Path.cwd()
            try:
                import os
                os.chdir(root)
                _, _, outputs = hdltool.generate_vhdl_variants(wrapper, profiles=("flat",))
            finally:
                os.chdir(original_directory)
            shim = (root / "ps_flat.vhd").read_text(encoding="utf-8")

        self.assertEqual({path.parent for path in outputs}, {root})
        self.assertIn("mapped_signal", shim)

    def test_generation_cli_discovers_current_wrapper(self):
        source = (
            "entity cli_wrapper is\n"
            "  port (source_signal : in std_logic);\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrapper = root / "cli_wrapper.vhd"
            wrapper.write_text(source, encoding="utf-8")
            original_directory = Path.cwd()
            try:
                import os
                os.chdir(root)
                result = hdltool.main(["generate-all"])
            finally:
                os.chdir(original_directory)
            generated = {path.name for path in root.glob("ps_*.vhd")}
            has_new_top_name = (root / "ps_flat_top.vhd").is_file()
            has_old_top_name = (root / "cli_top_flat.vhd").exists()

        self.assertEqual(result, 0)
        self.assertEqual(len(generated), 8)
        self.assertNotIn("all", hdltool.OPERATIONS)
        self.assertTrue(has_new_top_name)
        self.assertFalse(has_old_top_name)

    def test_generation_cli_accepts_filename_prefix(self):
        source = (
            "entity prefix_wrapper is\n"
            "  port (source_signal : in std_logic);\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrapper = root / "prefix_wrapper.vhd"
            wrapper.write_text(source, encoding="utf-8")
            result = hdltool.main([
                "generate-all", str(wrapper), "--prefix", "custom_",
                "--outdir", str(root / "generated"),
            ])
            generated = list((root / "generated").glob("custom_*.vhd"))
            has_custom_shim = (root / "generated" / "custom_flat.vhd").is_file()
            has_custom_top = (root / "generated" / "custom_flat_top.vhd").is_file()
            custom_shim = (root / "generated" / "custom_flat.vhd").read_text(encoding="utf-8")
            custom_top = (root / "generated" / "custom_flat_top.vhd").read_text(encoding="utf-8")

        self.assertEqual(result, 0)
        self.assertEqual(len(generated), 8)
        self.assertTrue(has_custom_shim)
        self.assertTrue(has_custom_top)
        self.assertIn("entity custom_flat is", custom_shim)
        self.assertIn("entity custom_flat_top is", custom_top)

    def test_pattern_indexable_zero_disables_nonflat_arrays(self):
        source = (
            "entity indexable_wrapper is\n"
            "  port (\n"
            "    M00_AXI_0_awaddr : out std_logic_vector (31 downto 0);\n"
            "    M01_AXI_0_awaddr : out std_logic_vector (31 downto 0)\n"
            "  );\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrapper = root / "indexable_wrapper.vhd"
            mapping = root / "name_map.json"
            wrapper.write_text(source, encoding="utf-8")
            mapping.write_text(
                '{"_non_indexable": {"M[]_AXI_0": "axilite[]"}, '
                '"_indexable": {}}',
                encoding="utf-8",
            )
            _, _, outputs = hdltool.generate_vhdl_variants(
                wrapper, output_dir=root / "generated", name_map_path=mapping,
                profiles=("flat", "slv-array")
            )
            flat = outputs[0].read_text(encoding="utf-8")
            slv_array = outputs[2].read_text(encoding="utf-8")

        self.assertIn("axilite0_awaddr", flat)
        self.assertIn("axilite1_awaddr", flat)
        self.assertIn("axilite0_awaddr", slv_array)
        self.assertIn("axilite1_awaddr", slv_array)
        self.assertNotIn("slv_array_t", slv_array)

    def test_duplicate_peripherals_get_neutral_namespaces(self):
        source = (
            "entity dual_peripheral_wrapper is\n"
            "  port (\n"
            "    GPIO_0_tri_io : inout std_logic;\n"
            "    GPIO_0_0_tri_io : inout std_logic;\n"
            "    IIC_0_scl_io : inout std_logic;\n"
            "    IIC_0_0_scl_io : inout std_logic;\n"
            "    SPI_0_sck_io : inout std_logic;\n"
            "    SPI_0_0_sck_io : inout std_logic\n"
            "  );\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            wrapper = Path(directory) / "dual_peripheral_wrapper.vhd"
            wrapper.write_text(source, encoding="utf-8")
            compact_map = hdltool._analysis_name_map_file(
                hdltool.analyze_wrapper(wrapper)
            )

        patterns = {
            **compact_map["_non_indexable"],
            **compact_map["_indexable"],
        }
        self.assertEqual(patterns["GPIO_[]"], "gpio[]")
        self.assertEqual(patterns["GPIO_[]_0"], "gpio[]_0")
        self.assertEqual(patterns["IIC_[]"], "i2c[]")
        self.assertEqual(patterns["IIC_[]_0"], "i2c[]_0")
        self.assertEqual(patterns["SPI_[]"], "spi[]")
        self.assertEqual(patterns["SPI_[]_0"], "spi[]_0")
        self.assertEqual(
            hdltool.resolve_name_mapping("GPIO_0_tri_io", compact_map),
            "gpio0_tri_io",
        )
        self.assertEqual(
            hdltool.resolve_name_mapping("GPIO_0_0_tri_io", compact_map),
            "gpio0_0_tri_io",
        )

    def test_qualified_peripheral_groups_use_family_headers(self):
        source = (
            "entity qualified_wrapper is\n"
            "  port (\n"
            "    IIC_0_scl_io : inout std_logic;\n"
            "    IIC_1_scl_io : inout std_logic;\n"
            "    IIC_0_0_scl_io : inout std_logic;\n"
            "    IIC_1_0_scl_io : inout std_logic\n"
            "  );\n"
            "end entity;\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrapper = root / "qualified_wrapper.vhd"
            mapping = root / "name_map.json"
            wrapper.write_text(source, encoding="utf-8")
            mapping.write_text(
                '{"_patterns": {"IIC_[]": "ps_i2c[]", '
                '"IIC_[]_0": "pl_i2c[]"}}',
                encoding="utf-8",
            )
            _, _, outputs = hdltool.generate_vhdl_variants(
                wrapper, output_dir=root / "generated", name_map_path=mapping,
                profiles=("flat", "slv-array")
            )
            flat = outputs[0].read_text(encoding="utf-8")
            slv_array = outputs[2].read_text(encoding="utf-8")

        self.assertEqual(flat.count("-- ps_i2c"), 2)
        self.assertEqual(flat.count("-- pl_i2c"), 2)
        self.assertNotIn("-- ps\n", flat)
        self.assertNotIn("-- pl\n", flat)
        self.assertLess(flat.index("ps_i2c0_scl"), flat.index("ps_i2c1_scl"))
        self.assertEqual(slv_array.count("-- ps_i2c"), 1)
        self.assertEqual(slv_array.count("-- pl_i2c"), 1)
        self.assertLess(flat.index("ps_i2c1_scl"), flat.index("pl_i2c0_scl"))
        self.assertLess(flat.index("pl_i2c0_scl"), flat.index("pl_i2c1_scl"))


if __name__ == "__main__":
    unittest.main()
