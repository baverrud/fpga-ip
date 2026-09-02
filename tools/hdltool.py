#!/usr/bin/env python3
"""hdltool.py - standalone HDL formatter and wrapper utility.

Guarantee:
    This tool ONLY inserts/removes spaces and blank lines.  It never
    reorders, renames, or rewrites any token, so the compiled design is
    identical.  A self-check asserts that, per line, the sequence of
    non-whitespace characters is unchanged.

Targets:
        - *_top.vhd / *_top.sv synthesis wrappers and *_inst.vhd / *_inst.sv
            instantiation templates
    - VHDL / SystemVerilog code blocks inside README.md files
      (only fenced blocks tagged vhdl / systemverilog are touched)
    - raw code blocks piped on stdin when no file path is supplied

Style `extreme` (see fpga-rules/hdl_coding_rules.md - Column Alignment):
    - Align repeated columns within a block: identifiers, ':', direction,
      type/range ('to'/'downto' and '[...:...]'), ':=', '=>', '=', ',',
      ';', ')', ']' and inline comments.
    - Right-align numbers/expressions before 'to'/'downto' (VHDL) and
      before/after ':' inside vector ranges (SV).
    - Right-align ':= value' / '= value' columns.
    - Align trailing ';' and ',' punctuation in a stable block column.
    - Strip trailing whitespace while preserving blank-line structure.

Style `moderate`:
    - Align outer declaration/map columns while keeping declaration
      punctuation attached to the preceding type, value, or name.
    - Keep type and range expressions natural; do not right-align indices.
    - Keep generic/parameter values and map expressions compact.

Style `collapsed` keeps natural spacing and indentation.

Usage:
    hdltool format <file> [<file> ...] [options]
    hdltool search-wrappers [project.xpr|project-dir]
    hdltool format < block.txt
    hdltool analyze-wrapper <wrapper.vhd> [--name-map name_map.json]
    hdltool analyze-wrapper <wrapper.vhd> [--analysis analysis.json]

    --style {extreme,moderate,collapsed}
                            alignment profile (default: moderate)
    --indent WIDTH          spaces per inferred indentation level (default: 2)
    --check                 check that files can be read and analyzed
    --name-map PATH         write only the friendly name map to PATH
"""

import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path

__version__ = "0.1.0"
_FORMAT_EXTENSIONS = {".v", ".sv", ".vhd", ".vhdl"}
_FORMAT_SKIP_DIRS = {
    ".git", ".venv", ".xil", "cache", "ip_user_files", "sim", "vivado",
    "work", ".runs", ".cache", ".gen", ".srcs", ".hw", ".sim",
}
_FORMAT_SKIP_DIRS_LOWER = {item.lower() for item in _FORMAT_SKIP_DIRS}
_FORMAT_SKIP_SUFFIXES = (
    ".cache", ".gen", ".srcs", ".runs", ".hw", ".sim", ".ip_user_files"
)


def non_ws(line):
    return re.sub(r"\s+", "", line)


def split_comment(line, comment_prefix):
    index = line.find(comment_prefix)
    if index < 0:
        return line.rstrip(), None
    return line[:index].rstrip(), line[index:].strip()


_VHD_GEN_RE = re.compile(
    r"^(?P<ind>\s*)(?P<kind>constant|generic|parameter)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
    r"(?P<type>[^:=,;]+?)\s*:=\s*(?P<value>[^,;]*?)"
    r"(?P<tail>[,;]?)\s*$",
    re.IGNORECASE,
)
_VHD_DECL_RE = re.compile(
    r"^(?P<ind>\s*)(?:(?P<kind>signal|constant)\s+)?"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
    r"(?P<dir>(?:inout|in|out)\b)?\s*"
    r"(?P<type>[^,;]+?)(?P<tail>[,;]?)\s*$",
    re.IGNORECASE,
)
_VHD_MAP_RE = re.compile(
    r"^(?P<ind>\s*)(?P<name>[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)\s*=>\s*"
    r"(?P<expr>.*?)(?P<tail>,?)\s*$"
)
_VHD_RANGE_RE = re.compile(
    r"^(?P<pre>.*?)\s*(?P<kw>downto|to)\s*(?P<post>.*?)$",
    re.IGNORECASE,
)


def _vhd_decl_cells(body, cmt):
    """Parse one VHDL declaration or generic into alignment cells."""
    match = _VHD_GEN_RE.match(body)
    if match:
        return {
            "is_gen": True, "ind": match.group("ind"),
            "kind": match.group("kind") or "", "name": match.group("name"),
            "dir": "", "type": match.group("type").strip(),
            "value": match.group("value").strip(), "tail": match.group("tail"),
            "cmt": cmt,
        }
    match = _VHD_DECL_RE.match(body)
    if match:
        cells = {
            "is_gen": False, "ind": match.group("ind"),
            "kind": match.group("kind") or "", "name": match.group("name"),
            "dir": (match.group("dir") or "").strip(),
            "type": match.group("type").strip(), "value": "",
            "tail": match.group("tail"), "cmt": cmt,
        }
        if cells["type"].startswith("="):
            return None
        return cells
    return None


def _vhd_type_cells(type_str):
    match = re.match(
        r"^(?P<head>.*?)(?:\(\s*(?P<inside>[^()]*)\s*\))?$",
        type_str.strip(),
    )
    if not match or not match.group("inside"):
        return type_str.strip(), "", ""
    inside = re.sub(r"\s+", " ", match.group("inside").strip())
    range_match = _VHD_RANGE_RE.match(inside)
    if not range_match:
        return type_str.strip(), "", ""
    head = match.group("head").strip() + "(" + range_match.group("pre").strip()
    return head, range_match.group("kw"), range_match.group("post").strip() + ")"


def _vhd_head_split(head):
    match = re.match(r"^(.*\()([^()]*)$", head)
    if match:
        return match.group(1), match.group(2)
    return head, ""


def _align_inline_comments(rows):
    if not rows:
        return rows
    comment_rows = [(line, comment) for line, comment in rows if comment]
    if not comment_rows:
        return [line for line, _comment in rows]
    column = max(len(line) for line, _comment in comment_rows) + 2
    return [
        (line.ljust(column) + comment if comment else line)
        for line, comment in rows
    ]


def _compact_inline_comments(rows):
    result = []
    for line, comment in rows:
        result.append(line + ("  " + comment if comment else ""))
    return result


class _Cfg:
    """Per-style column alignment flags for one block kind.

    Each flag enables padding/alignment of a column for the active style;
    a zero flag leaves that column at its natural width.  comment_align
    selects block-aligned inline comments (extreme/moderate) vs. compact
    ones (collapsed).  The per-kind/per-style tables live in _STYLE_CFGS.
    """

    __slots__ = ("pad_kind", "pad_dir", "pad_name", "pad_tail", "pad_value",
                 "rjust_value", "pad_expr", "align_vectors", "outer_type",
                 "comment_align")

    def __init__(self, pad_kind=0, pad_dir=0, pad_name=0, pad_tail=0,
                 pad_value=0, rjust_value=0, pad_expr=0, align_vectors=0,
                 outer_type=0, comment_align=1):
        self.pad_kind = pad_kind
        self.pad_dir = pad_dir
        self.pad_name = pad_name
        self.pad_tail = pad_tail
        self.pad_value = pad_value
        self.rjust_value = rjust_value
        self.pad_expr = pad_expr
        self.align_vectors = align_vectors
        self.outer_type = outer_type
        self.comment_align = comment_align


def _attach_comments(rows, cfg):
    """Attach inline comments per the style's comment mode."""
    if cfg.comment_align:
        return _align_inline_comments(rows)
    return _compact_inline_comments(rows)


def _align_vhd_decl(lines, cfg):
    """Align VHDL generic/port/signal declarations.

    Columns: name, ':', direction, type head, 'to'/'downto' keyword, range
    index (right-aligned), ':=' value (right-aligned), trailing ';'/','.

    Which columns are padded and right-aligned is driven by cfg (see _Cfg
    and _STYLE_CFGS); non-uniform or mixed-kind blocks are left untouched.
    """
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "--")
        c = _vhd_decl_cells(body, cmt)
        if c is None:
            return lines  # not a uniform block; leave untouched
        c["head"], c["kw"], c["post"] = _vhd_type_cells(c["type"])
        c["prefix"], c["idx"] = _vhd_head_split(c["head"])
        parsed.append(c)
    if any(p["is_gen"] != parsed[0]["is_gen"] or
           p["kind"] != parsed[0]["kind"] for p in parsed):
        return lines

    gens = parsed[0]["is_gen"]
    name_w = max(len(p["name"]) for p in parsed) if cfg.pad_name else 0
    has_dir = (not gens) and all(p["dir"] for p in parsed)
    dir_w = max(len(p["dir"]) for p in parsed) if (has_dir and cfg.pad_dir) else 0

    ranged = [p for p in parsed if p["kw"]]
    prefix_w = max(len(p["prefix"]) for p in ranged) if (cfg.align_vectors and ranged) else 0
    idx_w = max(len(p["idx"]) for p in ranged) if (cfg.align_vectors and ranged) else 0
    kw_w = max(len(p["kw"]) for p in ranged) if (cfg.align_vectors and ranged) else 0
    post_w = max(len(p["post"]) for p in ranged) if (cfg.align_vectors and ranged) else 0
    value_w = max(len(p["value"]) for p in parsed) if (gens and cfg.pad_value) else 0

    cores = []
    for p in parsed:
        decl_kind = (p["kind"] + " ") if p["kind"] else ""
        line = p["ind"] + decl_kind + p["name"].ljust(name_w) + " : "
        if cfg.pad_dir:
            if has_dir:
                line += p["dir"].ljust(dir_w) + " "
        elif p["dir"]:
            line += p["dir"] + " "
        if cfg.align_vectors and p["kw"]:
            line += p["prefix"].ljust(prefix_w) + p["idx"].rjust(idx_w)
            line += " " + p["kw"].ljust(kw_w) + " " + p["post"].ljust(post_w)
        else:
            line += (p["head"] if cfg.align_vectors
                     else _normalize_vhdl_type(p["type"]))
        if gens:
            val = p["value"].rjust(value_w) if cfg.pad_value else p["value"].strip()
            line += " := " + val
        cores.append((line, p["tail"], p["cmt"]))

    if cfg.pad_tail:
        tail_col = max(len(line) for line, _, _ in cores)
        out = []
        for line, tail, cmt in cores:
            if tail:
                line = line.ljust(tail_col) + tail
            out.append((line, cmt))
        return _align_inline_comments(out)
    out = [(line + tail, cmt) for line, tail, cmt in cores]
    return _attach_comments(out, cfg)


def _align_vhd_map(lines, cfg):
    """Align VHDL generic/port maps ('name => expr')."""
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "--")
        m = _VHD_MAP_RE.match(body)
        if not m:
            return lines
        parsed.append((m.group("ind"), m.group("name"), m.group("expr").strip(),
                       m.group("tail"), cmt))

    def map_side_parts(value):
        match = re.match(r"^(?P<base>[^()]+)\((?P<inside>[^()]*)\)$", value)
        if not match:
            return None
        base = match.group("base").rstrip()
        inside = re.sub(r"\s+", " ", match.group("inside").strip())
        range_match = _VHD_RANGE_RE.match(inside)
        if range_match:
            return (base, range_match.group("pre").strip(),
                    range_match.group("kw"), range_match.group("post").strip())
        return (base, inside, "", "")

    def format_map_sides(values):
        parts = [map_side_parts(value) for value in values]
        ranged_parts = [part for part in parts if part]
        if not ranged_parts:
            return values
        base_w = max(len(part[0]) for part in ranged_parts)
        left_w = max(len(part[1]) for part in ranged_parts)
        kw_w = max(len(part[2]) for part in ranged_parts)
        right_w = max(len(part[3]) for part in ranged_parts)
        inner_w = max(
            len(part[1]) + (1 + len(part[2]) + 1 + len(part[3]) if part[2] else 0)
            for part in ranged_parts
        )
        formatted = []
        for value, part in zip(values, parts):
            if not part:
                formatted.append(value)
                continue
            base, left, keyword, right = part
            if keyword:
                inner = (left.rjust(left_w) + " " + keyword.ljust(kw_w)
                         + " " + right.ljust(right_w))
            else:
                inner = left.rjust(inner_w)
            formatted.append(base.ljust(base_w) + "(" + inner + ")")
        return formatted

    def compact_map_side(value):
        part = map_side_parts(value)
        if not part:
            return value.strip()
        base, left, keyword, right = part
        if keyword:
            inner = f"{left} {keyword} {right}"
        else:
            inner = left
        return f"{base}({inner})"

    names = (format_map_sides([p[1] for p in parsed]) if cfg.align_vectors
             else [compact_map_side(p[1]) for p in parsed])
    exprs = (format_map_sides([p[2] for p in parsed]) if cfg.align_vectors
             else [compact_map_side(p[2]) for p in parsed])
    name_w = max(len(name) for name in names) if cfg.pad_name else 0
    expr_w = max(len(expr) for expr in exprs) if cfg.pad_expr else 0
    out = []
    for index, (ind, _name, _expr, tail, cmt) in enumerate(parsed):
        line = ind + names[index].ljust(name_w) + " => " + exprs[index].ljust(expr_w) + tail
        out.append((line, cmt))
    return _attach_comments(out, cfg)


def _normalize_vhdl_type(type_str):
    """Return a VHDL type with natural internal spacing."""
    head, keyword, post = _vhd_type_cells(type_str.strip())
    if keyword:
        head = re.sub(r"\s+", " ", head).strip()
        head = re.sub(r"\(\s+", "(", head)
        post = re.sub(r"\s+", " ", post).strip()
        return head + " " + keyword + " " + post
    return re.sub(r"\s+", " ", type_str.strip())


# ---------------------------------------------------------------------------
# SystemVerilog
# ---------------------------------------------------------------------------

# parameter/localparam <type> <name> = <value> ,
_SV_PARAM_RE = re.compile(
    r"^(?P<ind>\s*)(?P<kind>parameter|localparam)\s+"
    r"(?P<type>[^=]*?)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
    r"(?P<value>.*?)(?P<tail>,?)\s*$"
)

# input|output|inout <type> <name> ,
_SV_PORT_RE = re.compile(
    r"^(?P<ind>\s*)(?P<dir>input|output|inout)\s+"
    r"(?P<type>.*?)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?P<tail>,?)\s*$"
)

# logic|wire|reg <type> <name> ;
_SV_DECL_RE = re.compile(
    r"^(?P<ind>\s*)(?P<kind>logic|wire|reg)\s+"
    r"(?P<type>.*?)\s+"
    r"(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?P<tail>;?)\s*$"
)

# .name ( expr ) ,
_SV_MAP_RE = re.compile(
    r"^(?P<ind>\s*)(?P<name>\.\w+)\s*\(\s*"
    r"(?P<expr>.*?)\s*\)\s*(?P<tail>,?)\s*$"
)

# vector type: "logic [<lo>:<hi>]"
_SV_VEC_RE = re.compile(r"^(?P<pre>[^[]*\[)(?P<lo>[^:]*):(?P<hi>[^\]]*)\]$")


def _sv_type_fields(typ):
    """Split an SV type into (pre, lo, hi, is_vector).

    'logic [A:B]' -> ('logic [', 'A', 'B', True); anything else returns
    the whole type as 'pre' with is_vector=False.
    """
    m = _SV_VEC_RE.match(typ)
    if m:
        return m.group("pre"), m.group("lo").strip(), m.group("hi").strip(), True
    return typ, "", "", False


def _sv_type_aligner(types):
    """Return an emit(typ) function that aligns types in a block.

    The vector range parts before/after ':' are right-aligned separately
    so the ':' lines up; the whole type column is padded so following
    names stay aligned.
    """
    fields = [_sv_type_fields(t) for t in types]
    pre_w = max(len(f[0]) for f in fields)
    vecs = [f for f in fields if f[3]]
    lo_w = max(len(f[1]) for f in vecs) if vecs else 0
    hi_w = max(len(f[2]) for f in vecs) if vecs else 0
    type_w = max((pre_w + lo_w + 1 + hi_w + 1 if f[3] else len(f[0]))
                 for f in fields)

    def emit(typ):
        pre, lo, hi, isvec = _sv_type_fields(typ)
        if isvec:
            s = pre.ljust(pre_w) + lo.rjust(lo_w) + ":" + hi.rjust(hi_w) + "]"
        else:
            s = pre
        return s.ljust(type_w)

    return emit


def _normalize_sv_type(type_str):
    """Return a SystemVerilog type with natural internal spacing."""
    pre, lo, hi, is_vector = _sv_type_fields(type_str.strip())
    if is_vector:
        pre = re.sub(r"\s+", " ", pre).strip()
        return pre + lo + ":" + hi + "]"
    return re.sub(r"\s+", " ", type_str.strip())


def _sv_moderate_type_aligner(types):
    """Return an emitter that pads only the outer type column."""
    type_w = max(len(_normalize_sv_type(typ)) for typ in types)

    def emit(typ):
        return _normalize_sv_type(typ).ljust(type_w)

    return emit


def _sv_type_emitter(types, cfg):
    """Return an emit(typ) function matching the style's type alignment."""
    if cfg.align_vectors:
        return _sv_type_aligner(types)
    if cfg.outer_type:
        return _sv_moderate_type_aligner(types)
    return lambda typ: _normalize_sv_type(typ)


def _align_sv_params(lines, cfg):
    """Align SV parameters ('kind type name = value')."""
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_PARAM_RE.match(body)
        if not m:
            return lines
        parsed.append((m.group("ind"), m.group("kind"), m.group("type").strip(),
                       m.group("name"),
                       m.group("value").strip(), m.group("tail"), cmt))
    emit_type = _sv_type_emitter([p[2] for p in parsed], cfg)
    kind_w = max(len(p[1]) for p in parsed) if cfg.pad_kind else 0
    name_w = max(len(p[3]) for p in parsed) if cfg.pad_name else 0
    value_w = max(len(p[4]) for p in parsed) if (cfg.pad_value or cfg.rjust_value) else 0
    tail_w = max(len(p[5]) for p in parsed) if cfg.pad_tail else 0
    out = []
    for ind, kind, typ, name, value, tail, cmt in parsed:
        line = ind + kind.ljust(kind_w) + " " + emit_type(typ) + " "
        line += name.ljust(name_w) + " = "
        line += value.rjust(value_w) if cfg.rjust_value else value
        line += (tail or "").ljust(tail_w)
        out.append((line, cmt))
    return _attach_comments(out, cfg)


def _align_sv_ports(lines, cfg):
    """Align SV module ports ('dir type name')."""
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_PORT_RE.match(body)
        if not m:
            return lines
        parsed.append((m.group("ind"), m.group("dir"), m.group("type").strip(),
                       m.group("name"), m.group("tail"), cmt))
    emit_type = _sv_type_emitter([p[2] for p in parsed], cfg)
    dir_w = max(len(p[1]) for p in parsed) if cfg.pad_dir else 0
    name_w = max(len(p[3]) for p in parsed) if cfg.pad_name else 0
    tail_w = max(len(p[4]) for p in parsed) if cfg.pad_tail else 0
    out = []
    for ind, d, typ, name, tail, cmt in parsed:
        line = ind + d.ljust(dir_w) + " " + emit_type(typ) + " "
        line += name.ljust(name_w) + (tail or "").ljust(tail_w)
        out.append((line, cmt))
    return _attach_comments(out, cfg)


def _align_sv_decls(lines, cfg):
    """Align SV declarations ('kind type name')."""
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_DECL_RE.match(body)
        if not m:
            return lines
        parsed.append((m.group("ind"), m.group("kind"), m.group("type").strip(),
                       m.group("name"), m.group("tail"), cmt))
    emit_type = _sv_type_emitter([p[2] for p in parsed], cfg)
    kind_w = max(len(p[1]) for p in parsed) if cfg.pad_kind else 0
    name_w = max(len(p[3]) for p in parsed) if cfg.pad_name else 0
    tail_w = max(len(p[4]) for p in parsed) if cfg.pad_tail else 0
    out = []
    for ind, kind, typ, name, tail, cmt in parsed:
        line = ind + kind.ljust(kind_w) + " " + emit_type(typ) + " "
        line += name.ljust(name_w) + (tail or "").ljust(tail_w)
        out.append((line, cmt))
    return _attach_comments(out, cfg)


def _align_sv_maps(lines, cfg):
    """Align SV port maps ('.name ( expr )')."""
    parsed = []
    for ln in lines:
        body, cmt = split_comment(ln, "//")
        m = _SV_MAP_RE.match(body)
        if not m:
            return lines
        parsed.append((m.group("ind"), m.group("name"), m.group("expr").strip(),
                       m.group("tail"), cmt))
    name_w = max(len(p[1]) for p in parsed) if cfg.pad_name else 0
    expr_w = max(len(p[2]) for p in parsed) if cfg.pad_expr else 0
    tail_w = max(len(p[3]) for p in parsed) if cfg.pad_tail else 0
    out = []
    for ind, name, expr, tail, cmt in parsed:
        line = ind + name.ljust(name_w) + " (" + expr.ljust(expr_w) + ")"
        line += (tail or "").ljust(tail_w)
        out.append((line, cmt))
    return _attach_comments(out, cfg)


# ---------------------------------------------------------------------------
# Block segmentation and dispatch
# ---------------------------------------------------------------------------

def _classify_vhdl(body):
    if "=>" in body and _VHD_MAP_RE.match(body):
        return "vhd_map"
    if _VHD_GEN_RE.match(body):
        return "vhd_gen"
    if ":" in body and _VHD_DECL_RE.match(body):
        return "vhd_decl"
    return None


def _classify_sv(body):
    if re.match(r"^\s*(parameter|localparam)\b", body):
        return "sv_param"
    if _SV_MAP_RE.match(body):
        return "sv_map"
    if re.match(r"^\s*(input|output|inout)\b", body):
        return "sv_port"
    if re.match(r"^\s*(logic|wire|reg)\b", body):
        return "sv_decl"
    return None


_KIND_ALIGNERS = {
    "vhd_decl": _align_vhd_decl,
    "vhd_gen": _align_vhd_decl,
    "vhd_map": _align_vhd_map,
    "sv_param": _align_sv_params,
    "sv_port": _align_sv_ports,
    "sv_decl": _align_sv_decls,
    "sv_map": _align_sv_maps,
}

_STYLE_CFGS = {
    "extreme": {
        "vhd_decl": _Cfg(pad_name=1, pad_dir=1, pad_tail=1, pad_value=1,
                         align_vectors=1),
        "vhd_gen": _Cfg(pad_name=1, pad_dir=1, pad_tail=1, pad_value=1,
                        align_vectors=1),
        "vhd_map": _Cfg(pad_name=1, pad_expr=1, align_vectors=1),
        "sv_param": _Cfg(pad_kind=1, pad_name=1, pad_tail=1, pad_value=1,
                         rjust_value=1, align_vectors=1),
        "sv_port": _Cfg(pad_dir=1, pad_name=1, pad_tail=1, align_vectors=1),
        "sv_decl": _Cfg(pad_name=1, pad_tail=1, align_vectors=1),
        "sv_map": _Cfg(pad_name=1, pad_expr=1, pad_tail=1),
    },
    "moderate": {
        "vhd_decl": _Cfg(pad_name=1, pad_dir=1),
        "vhd_gen": _Cfg(pad_name=1, pad_dir=1),
        "vhd_map": _Cfg(pad_name=1),
        "sv_param": _Cfg(pad_kind=1, pad_name=1, outer_type=1),
        "sv_port": _Cfg(pad_dir=1, outer_type=1),
        "sv_decl": _Cfg(pad_kind=1, outer_type=1),
        "sv_map": _Cfg(pad_name=1),
    },
    "collapsed": {
        "vhd_decl": _Cfg(comment_align=0),
        "vhd_gen": _Cfg(comment_align=0),
        "vhd_map": _Cfg(comment_align=0),
        "sv_param": _Cfg(comment_align=0),
        "sv_port": _Cfg(comment_align=0),
        "sv_decl": _Cfg(comment_align=0),
        "sv_map": _Cfg(comment_align=0),
    },
}


def prettify_code(lines, language, style="moderate"):
    """Align a list of code lines (whitespace-only)."""
    if style not in _STYLE_CFGS:
        raise ValueError(f"unsupported alignment style: {style}")
    classify = _classify_vhdl if language == "vhdl" else _classify_sv
    prefix = "--" if language == "vhdl" else "//"
    out = []
    i = 0
    n = len(lines)
    while i < n:
        ln = lines[i]
        body, _ = split_comment(ln, prefix)
        kind = classify(body) if body.strip() else None
        if kind is None:
            out.append(ln.rstrip())
            i += 1
            continue
        # gather a run of consecutive same-kind lines
        j = i
        while j < n:
            b2, _ = split_comment(lines[j], prefix)
            k2 = classify(b2) if b2.strip() else None
            if k2 != kind:
                break
            j += 1
        block = lines[i:j]
        aligned = _KIND_ALIGNERS[kind](block, _STYLE_CFGS[style][kind])
        if aligned is None:
            aligned = [l.rstrip() for l in block]
        out.extend(aligned)
        i = j
    return out


def _infer_indent_unit(lines):
    """Infer the source indentation unit while tolerating odd continuation indents."""
    widths = [len(line) - len(line.lstrip(" "))
              for line in lines if line.strip()]
    widths = [width for width in widths if width > 0]
    if not widths:
        return 1
    minimum = min(widths)
    candidates = range(1, minimum + 1)
    required = max(1, (len(widths) * 3 + 3) // 4)
    supported = [candidate for candidate in candidates
                 if sum(width % candidate == 0 for width in widths) >= required]
    return max(supported, default=1)


def normalize_indentation(lines, indent_width):
    """Normalize leading spaces to the requested spaces-per-level width."""
    if indent_width < 1:
        raise ValueError("indent width must be at least 1")
    source_unit = _infer_indent_unit(lines)
    out = []
    for line in lines:
        prefix = line[:len(line) - len(line.lstrip(" \t"))]
        body = line[len(prefix):]
        if not body:
            out.append("")
            continue
        spaces = len(prefix.expandtabs(source_unit))
        level = (spaces + source_unit // 2) // source_unit
        out.append(" " * (level * indent_width) + body)
    return out


_VHD_INSTANTIATION_RE = re.compile(
    r"^(?P<label>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
    r"(?:component\b|entity\b|configuration\b)", re.IGNORECASE
)
_VHD_MAP_START_RE = re.compile(r"^(?:generic|port)\s+map\s*\(", re.IGNORECASE)


def normalize_vhdl_instantiations(lines, indent_width):
    """Indent concurrent VHDL instantiations using the requested width."""
    out = list(lines)
    begin_indent = None
    instantiation = None
    map_indent = None
    for index, line in enumerate(out):
        stripped = line.lstrip(" \t")
        if not stripped:
            continue
        current_indent = len(line) - len(stripped)
        code, _ = split_comment(stripped, "--")
        code = code.rstrip()

        if code.lower() == "begin":
            begin_indent = current_indent
            continue

        if map_indent is not None:
            if code.startswith(");"):
                out[index] = " " * map_indent + stripped
                map_indent = None
            else:
                out[index] = " " * (map_indent + indent_width) + stripped
            continue

        match = _VHD_INSTANTIATION_RE.match(code)
        if match:
            parent_indent = begin_indent if begin_indent is not None else current_indent
            label_indent = current_indent
            if label_indent == parent_indent:
                label_indent += indent_width
            out[index] = " " * label_indent + stripped
            instantiation = label_indent
            continue

        if instantiation is not None and _VHD_MAP_START_RE.match(code):
            map_indent = instantiation + indent_width
            out[index] = " " * map_indent + stripped

    return out


def _finish(out):
    """Strip trailing whitespace while preserving every blank line."""
    return [l.rstrip() for l in out]


# ---------------------------------------------------------------------------
# File-level processing
# ---------------------------------------------------------------------------

_VHDL_FENCE = re.compile(r"^\s*```(vhdl|systemverilog|verilog)\s*$", re.IGNORECASE)
_CODE_FENCE = re.compile(r"^\s*```\s*$")


def prettify_text(text, is_markdown, lang=None, style="moderate", indent_width=2):
    """Prettify file text.  For markdown, only fenced code blocks are touched."""
    src = text.splitlines()
    if not is_markdown:
        l = lang or ("vhdl" if _looks_vhdl(src) else "sv")
        out = prettify_code(src, l, style)
        out = normalize_indentation(out, indent_width)
        if l == "vhdl":
            out = normalize_vhdl_instantiations(out, indent_width)
        return "\n".join(_finish(out)) + "\n"

    # markdown: rewrite only inside vhdl/systemverilog fenced blocks
    out = []
    in_code = False
    code_lang = None
    code_buf = []
    for ln in src:
        if in_code and _CODE_FENCE.match(ln):
            # end of code block
            pretty = prettify_code(code_buf,
                                   "vhdl" if code_lang == "vhdl" else "sv",
                                   style)
            pretty = normalize_indentation(pretty, indent_width)
            if code_lang == "vhdl":
                pretty = normalize_vhdl_instantiations(pretty, indent_width)
            out.extend(_finish(pretty))
            out.append(ln)
            in_code = False
            code_lang = None
            code_buf = []
            continue
        if not in_code:
            m = _VHDL_FENCE.match(ln)
            if m and m.group(1).lower() in ("vhdl", "systemverilog", "verilog"):
                in_code = True
                code_lang = "vhdl" if m.group(1).lower() == "vhdl" else "sv"
                out.append(ln)
                continue
            out.append(ln.rstrip())
        else:
            code_buf.append(ln)
    # unterminated code block: flush remaining
    if code_buf:
        pretty = prettify_code(code_buf,
                       "vhdl" if code_lang == "vhdl" else "sv",
                       style)
        pretty = normalize_indentation(pretty, indent_width)
        if code_lang == "vhdl":
            pretty = normalize_vhdl_instantiations(pretty, indent_width)
        out.extend(_finish(pretty))
    return "\n".join(out) + "\n"


def _looks_vhdl(src):
    """Heuristic: a bare file is VHDL if it contains a VHDL entity/library
    marker before any SystemVerilog-only marker."""
    has_vhdl = any(re.search(r"\b(?:entity|architecture|library|signal)\b", l)
                   for l in src[:60])
    has_sv = any(re.search(r"\bmodule\b|^\s*(logic|wire|input|output)\b", l)
                 for l in src[:60])
    return has_vhdl and not has_sv


# ---------------------------------------------------------------------------
# Invariant check
# ---------------------------------------------------------------------------

def _check_invariant(before_lines, after_lines):
    """Assert the tool only changed whitespace (per-line token content)."""
    if len(before_lines) != len(after_lines):
        # blank-line collapse changes line count; compare content stream
        bws = [non_ws(l) for l in before_lines if non_ws(l)]
        aws = [non_ws(l) for l in after_lines if non_ws(l)]
        return bws == aws
    for b, a in zip(before_lines, after_lines):
        if non_ws(b) != non_ws(a):
            return False
    return True


def _language_for_path(path):
    """Select VHDL or SystemVerilog from a supported source extension."""
    suffix = Path(path).suffix.lower()
    if suffix in (".vhd", ".vhdl"):
        return "vhdl"
    if suffix in (".v", ".sv"):
        return "sv"
    return None


def prettify_file(path, style="moderate", indent_width=2):
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    path_text = str(path)
    is_md = path_text.lower().endswith((".md", ".markdown"))
    selected_lang = _language_for_path(path)
    if not is_md and selected_lang is None:
        raise ValueError(
            f"unsupported HDL extension for {path}; use .v, .sv, .vhd, or .vhdl"
        )
    new_text = prettify_text(text, is_md, lang=selected_lang, style=style,
                             indent_width=indent_width)
    ok = _check_invariant(text.splitlines(), new_text.splitlines())
    return text, new_text, ok


# ---------------------------------------------------------------------------
# Wrapper analysis
# ---------------------------------------------------------------------------

_ANALYSIS_AXI_SIGNALS = {
    "aw": ["awid", "awaddr", "awlen", "awsize", "awburst", "awlock",
        "awcache", "awprot", "awqos", "awregion", "awuser", "awvalid",
        "awready"],
    "w": ["wid", "wdata", "wstrb", "wlast", "wuser", "wvalid", "wready"],
    "b": ["bid", "bresp", "buser", "bvalid", "bready"],
    "ar": ["arid", "araddr", "arlen", "arsize", "arburst", "arlock",
        "arcache", "arprot", "arqos", "arregion", "aruser", "arvalid",
        "arready"],
    "r": ["rid", "rdata", "rresp", "rlast", "ruser", "rvalid", "rready"],
    "t": ["tdata", "tlast", "tuser", "tid", "tdest", "tkeep", "tstrb",
       "tvalid", "tready"],
}
_AXI_CHANNEL_ORDER = tuple(_ANALYSIS_AXI_SIGNALS)
_ANALYSIS_SUFFIX_CHANNEL = {
    suffix: channel
    for channel, suffixes in _ANALYSIS_AXI_SIGNALS.items()
    for suffix in suffixes
}
_ANALYSIS_AXI_SUFFIXES = sorted(_ANALYSIS_SUFFIX_CHANNEL, key=len, reverse=True)
_ANALYSIS_NON_AXI_SIGNALS = {
    "APB": ["paddr", "pprot", "pselx", "psel", "penable", "pwrite",
            "pwdata", "prdata", "pready", "pslverr", "pstrb"],
    "Wishbone": ["adr", "dat_o", "dat_i", "we", "sel", "stb", "cyc",
                 "ack", "err", "rty"],
    "SBI": ["cs", "addr", "wr", "rd", "wdata", "ready", "rdata"],
}
_ANALYSIS_SUFFIX_PROTOCOL = {
    suffix: protocol
    for protocol, suffixes in _ANALYSIS_NON_AXI_SIGNALS.items()
    for suffix in suffixes
}
_ANALYSIS_NON_AXI_SUFFIXES = sorted(
    _ANALYSIS_SUFFIX_PROTOCOL, key=len, reverse=True
)
_ANALYSIS_AXI_LITE_SUFFIXES = {
    "awaddr", "awprot", "awvalid", "awready", "wdata", "wstrb", "wvalid",
    "wready", "bresp", "bvalid", "bready", "araddr", "arprot", "arvalid",
    "arready", "rdata", "rresp", "rvalid", "rready",
}
_ANALYSIS_PORT_RE = re.compile(
    r"^\s*(\w+)\s*:\s*(in|out|inout)\s+(\w+)"
    r"((?:\s*\(\s*\w+\s+(?:downto|to)\s*\w+\s*\))?);?"
    r"(?:\s*--.*)?$",
    re.IGNORECASE,
)
_ANALYSIS_SPACE_RE = re.compile(r"\s+")
_ANALYSIS_PAREN_SPACE_RE = re.compile(r"\( | \)")
_DEFAULT_IGNORE_PATTERNS = ("DDR*", "FIXED_IO_*")


def _matches_ignore(name, patterns):
    normalized_name = name.casefold()
    return any(
        fnmatch.fnmatchcase(normalized_name, pattern.casefold())
        for pattern in patterns
    )


def _matches_ignored_map_key(name, patterns):
    return _matches_ignore(name, patterns) or _matches_ignore(f"{name}_", patterns)


def _analysis_parse_port(line):
    match = _ANALYSIS_PORT_RE.match(line.strip())
    if not match:
        return None
    name = match.group(1)
    direction = match.group(2).lower()
    port_type = match.group(3).upper()
    port_range = match.group(4).strip()
    if port_range:
        port_range = _ANALYSIS_SPACE_RE.sub(" ", port_range.lower())
    return name, direction, port_type, port_range


def _analysis_port_dict(name, direction, port_type, port_range):
    if (
        port_type == "STD_LOGIC_VECTOR"
        and port_range.replace(" ", "") in ("(0to0)", "(0downto0)")
    ):
        return {
            "name": name,
            "direction": direction,
            "type": "std_logic",
            "original_range": _ANALYSIS_PAREN_SPACE_RE.sub(
                lambda match: "(" if match.group() == "( " else ")",
                port_range,
            ),
        }
    result = {"name": name, "direction": direction, "type": port_type.lower()}
    if port_range:
        result["range"] = _ANALYSIS_PAREN_SPACE_RE.sub(
            lambda match: "(" if match.group() == "( " else ")",
            port_range,
        )
    return result


def _analysis_classify_axi(name):
    for suffix in _ANALYSIS_AXI_SUFFIXES:
        if name.endswith("_" + suffix):
            return name[:-(len(suffix) + 1)], _ANALYSIS_SUFFIX_CHANNEL[suffix], suffix
    return None


def _analysis_classify_non_axi(name):
    for suffix in _ANALYSIS_NON_AXI_SUFFIXES:
        if name.endswith("_" + suffix):
            return name[:-(len(suffix) + 1)], _ANALYSIS_SUFFIX_PROTOCOL[suffix], suffix
    return None


def _analysis_axi_role(prefix):
    if prefix.startswith("M_") or re.match(r"M\d+_", prefix):
        return "master"
    if prefix.startswith("S_"):
        return "slave"
    return ""


def _analysis_is_clock_reset(name):
    return any(keyword in name.lower() for keyword in ("clk", "clock", "rst", "resetn", "reset"))


def _analysis_is_interrupt(name):
    name_lower = name.lower()
    return any(keyword in name_lower for keyword in ("irq", "int", "interrupt"))


def _analysis_axi_type(channels):
    if "t" in channels:
        return "AXIS"
    suffixes = {
        signal["suffix"]
        for channel_signals in channels.values()
        for signal in channel_signals
    }
    if not any(suffix not in _ANALYSIS_AXI_LITE_SUFFIXES for suffix in suffixes):
        return "AXI-Lite"
    for channel_signals in channels.values():
        for signal in channel_signals:
            port_range = signal.get("range", "").replace(" ", "")
            if signal["suffix"] in ("awlen", "arlen") and port_range == "(3downto0)":
                return "AXI3"
            if signal["suffix"] in ("awlock", "arlock") and port_range:
                return "AXI3"
            if signal["suffix"] == "wid":
                return "AXI3"
    return "AXI4"


_ANALYSIS_NAME_MAP_AXI_RE = re.compile(r"M(\d+)_AXI_\d+|(?:M|S)_AXI_(.+)_\d+")
_ANALYSIS_HPC_FPD_RE = re.compile(r"^hpc?\d+_fpd$")
_ANALYSIS_AXILITE_ARRAY_RE = re.compile(r"^M(\d+)_AXI_\d+$")
_ANALYSIS_HPM_ARRAY_RE = re.compile(r"^M_AXI_HPM(\d+)_(FPD|LPD)_\d+$")
_ANALYSIS_PERIPHERAL_RE = re.compile(
    r"^(CAN|IIC|I2C|SPI|UART|GPIO|MDIO|QSPI|I2S)((?:_\d+)+)_(.+)$",
    re.IGNORECASE,
)
_ANALYSIS_PERIPHERAL_NAMES = {
    "can": "can",
    "iic": "i2c",
    "i2c": "i2c",
    "spi": "spi",
    "uart": "uart",
    "gpio": "gpio",
    "mdio": "mdio",
    "qspi": "qspi",
    "i2s": "i2s",
}
_ANALYSIS_PERIPHERAL_SIGNAL_RE = re.compile(
    r"^(CAN|IIC|I2C|SPI|UART|GPIO|MDIO|QSPI|I2S)_(\d+)(?:_(\d+))?_(.+)$",
    re.IGNORECASE,
)
_ANALYSIS_INDEXED_SIGNAL_RE = re.compile(
    r"^([a-z][a-z0-9_]*?)(\d+)_(.+)$", re.IGNORECASE
)
_ANALYSIS_INDEXED_NAME_RE = re.compile(r"^(.*?)(\d+)$")


def _analysis_sideband_prefix(name):
    parts = name.split("_")
    if len(parts) <= 1:
        return name
    if len(parts) > 4:
        return "_".join(parts[:-2])
    return "_".join(parts[:-1])


def _analysis_peripheral_signal_match(name):
    return (
        _ANALYSIS_PERIPHERAL_SIGNAL_RE.match(name)
        or _ANALYSIS_INDEXED_SIGNAL_RE.match(name)
    )


def _analysis_peripheral_name(data, signal):
    peripheral_match = _ANALYSIS_PERIPHERAL_SIGNAL_RE.match(signal["name"])
    indexed_match = _ANALYSIS_INDEXED_SIGNAL_RE.match(signal["name"])
    if peripheral_match:
        family = peripheral_match.group(1).lower()
        index = int(peripheral_match.group(2))
        second_index = peripheral_match.group(3)
        suffix = peripheral_match.group(4)
        include_second = any(
            other_match
            and other_match.group(1).lower() == peripheral_match.group(1).lower()
            and other_match.group(2) == peripheral_match.group(2)
            and other_match.group(3) is None
            for other in data.get("other_ports", [])
            for other_match in [_ANALYSIS_PERIPHERAL_SIGNAL_RE.match(other["name"])]
        )
        short_root = _ANALYSIS_PERIPHERAL_NAMES.get(family, family)
        index_text = str(index)
        if second_index is not None and include_second:
            index_text += f"_{int(second_index)}"
        return f"{short_root}{index_text}_{suffix}"
    if indexed_match:
        family = indexed_match.group(1).rstrip("_")
        family_lower = family.lower()
        if family_lower.endswith("_rtl"):
            family_lower = family_lower[:-4].rstrip("_")
            short_root = _ANALYSIS_PERIPHERAL_NAMES.get(family_lower, family_lower)
            family = f"{short_root}_rtl"
        return f"{family}{int(indexed_match.group(2))}_{indexed_match.group(3)}"
    return None


def _analysis_unique_name(name_map, source_name, candidate):
    used = set(name_map.values())
    if candidate not in used:
        return candidate
    index = 1
    while f"{candidate}{index}" in used:
        index += 1
    return f"{candidate}{index}"


def _analysis_flat_ports(data):
    """Return flat ports, accepting legacy categorized analysis dictionaries."""
    ports = list(data.get("other_ports", []))
    ports.extend(data.get("clocks_reset", []))
    ports.extend(data.get("interrupts", []))
    return ports


def _analysis_suggest_flat_name(data, signal, name_map):
    """Suggest a friendly name for one non-bus port."""
    peripheral_name = _analysis_peripheral_name(data, signal)
    if peripheral_name:
        return peripheral_name

    name = signal["name"]
    name_lower = name.lower()
    indexed_match = _ANALYSIS_INDEXED_NAME_RE.match(name)
    indexed_suffix = str(int(indexed_match.group(2))) if indexed_match else ""
    if name_lower.startswith(("pl_clk", "fclk_clk")):
        candidate = f"ps_clk{indexed_suffix}"
    elif name_lower.startswith(("pl_reset", "peripheral_aresetn")):
        candidate = f"ps_srstn{indexed_suffix}"
    elif _analysis_is_clock_reset(name):
        candidate = name_lower
    elif _analysis_is_interrupt(name):
        candidate = f"ps_irq{indexed_suffix}"
    else:
        candidate = name_lower
    return _analysis_unique_name(name_map, name, candidate)


def _analysis_generate_name_map(data):
    name_map = {}
    for prefix, bus in data.get("axi_buses", {}).items():
        match = _ANALYSIS_NAME_MAP_AXI_RE.match(prefix)
        if match and match.group(1) is not None:
            family = "axilite" if bus.get("protocol") == "AXI-Lite" else "axi"
            name_map[prefix] = f"{family}{int(match.group(1))}"
        elif match:
            suggested = match.group(2).lower()
            if _ANALYSIS_HPC_FPD_RE.search(suggested):
                suggested = suggested[:-4]
            name_map[prefix] = suggested
        else:
            name_map[prefix] = prefix.lower()

    for prefix, bus in data.get("non_axi_buses", {}).items():
        protocol = bus.get("protocol", "").lower()
        name_map[prefix] = prefix.lower().replace(protocol, protocol, 1)

    for signal in _analysis_flat_ports(data):
        name_map[signal["name"]] = _analysis_suggest_flat_name(
            data, signal, name_map
        )
    return name_map


def _analysis_apply_name_pattern(pattern, name, replacement):
    """Apply [] captures, preserving a suffix when the pattern has no * token."""
    parts = re.split(r"(\[\]|\*)", pattern)
    expression = []
    capture_kinds = []
    for part in parts:
        if part == "[]":
            expression.append(r"(\d+)")
            capture_kinds.append("index")
        elif part == "*":
            expression.append(r"(.*)")
            capture_kinds.append("suffix")
        else:
            expression.append(re.escape(part))
    expression_text = "".join(expression)
    match = (
        re.fullmatch(expression_text, name)
        if "*" in pattern
        else re.match(expression_text, name)
    )
    if not match:
        return None

    values = []
    for value, kind in zip(match.groups(), capture_kinds):
        values.append(str(int(value)) if kind == "index" else value)
    value_iter = iter(values)
    output = []
    for part in re.split(r"(\[\]|\[-?\d+\]|\*)", replacement):
        if part == "[]" or part == "*":
            output.append(next(value_iter))
        elif re.fullmatch(r"\[-?\d+\]", part):
            output.append(str(int(next(value_iter)) + int(part[1:-1])))
        else:
            output.append(part)
    resolved = "".join(output)
    if "*" not in pattern:
        resolved += name[match.end():]
    return resolved


def _name_map_pattern_groups(name_map):
    """Return pattern mappings with effective indexability.

    The current schema uses separate mapping groups for interfaces,
    indexable patterns, and non-indexable patterns. Legacy `_patterns` files
    and numeric `_indexable` overrides are still interpreted here so all
    callers apply the same compatibility rules.
    """
    explicit_non_indexable = "_non_indexable" in name_map
    non_indexable = name_map.get(
        "_non_indexable", name_map.get("_patterns", {})
    )
    indexable = name_map.get("_indexable", {})
    interfaces = name_map.get("_interfaces", {})
    mapping_indexable = any(isinstance(value, str) for value in indexable.values())
    numeric_overrides = (
        indexable
        if not explicit_non_indexable and not mapping_indexable
        else {}
    )
    non_default = 0 if explicit_non_indexable or mapping_indexable else 1
    return (
        [(pattern, entry, 1) for pattern, entry in interfaces.items()]
        + [(pattern, entry, 1) for pattern, entry in indexable.items()]
        + [
            (pattern, entry, numeric_overrides.get(pattern, non_default))
            for pattern, entry in non_indexable.items()
        ]
    )


def _name_pattern_entry(pattern, entry, name_map, default_indexable=1):
    """Return replacement text and indexability from a pattern entry."""
    if isinstance(entry, str):
        replacement = entry
        return replacement, default_indexable
    if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
        raise ValueError("name-map pattern entries must contain a string name")
    replacement = entry["name"]
    indexable = entry.get("indexable", default_indexable)
    if indexable not in (0, 1):
        raise ValueError("name-map pattern indexable must be 0 or 1")
    return replacement, indexable


def _name_pattern_metadata(name, name_map):
    """Return the matching pattern and metadata for a source name."""
    entries = _name_map_pattern_groups(name_map)
    ordered = sorted(
        entries,
        key=lambda item: (
            len(item[0].replace("[]", "").replace("*", "")),
            -item[0].count("[]") - item[0].count("*"),
        ),
        reverse=True,
    )
    for pattern, entry, group_indexable in ordered:
        replacement, entry_indexable = _name_pattern_entry(
            pattern, entry, name_map, group_indexable
        )
        resolved = _analysis_apply_name_pattern(pattern, name, replacement)
        if resolved is not None:
            return pattern, replacement, entry_indexable
    return None


def resolve_name_mapping(name, name_map):
    """Resolve an exact or compact pattern-based name-map entry."""
    if name in name_map and not name.startswith("_"):
        return name_map[name]
    metadata = _name_pattern_metadata(name, name_map)
    if metadata is not None:
        _pattern, replacement, _indexable = metadata
        return _analysis_apply_name_pattern(_pattern, name, replacement)
    return name


def _name_is_indexable(name, name_map):
    metadata = _name_pattern_metadata(name, name_map)
    return metadata is None or metadata[2] == 1


def _name_is_interface(name, name_map):
    """Return whether a bus is enabled for mode-view/interface generation."""
    interfaces = name_map.get("_interfaces")
    if interfaces is None:
        return True
    for pattern, entry in interfaces.items():
        replacement, _indexable = _name_pattern_entry(pattern, entry, name_map, 1)
        if _analysis_apply_name_pattern(pattern, name, replacement) is not None:
            return True
    return False


def _analysis_generate_name_patterns(data):
    """Generate compact patterns covering repeated indexed interfaces."""
    patterns = {}
    m_axi_patterns = {}
    for prefix in data.get("axi_buses", {}):
        match = re.fullmatch(r"M(\d+)_AXI_(\d+)", prefix)
        if match:
            pattern = f"M[]_AXI_{match.group(2)}"
            family = (
                "axilite"
                if data["axi_buses"][prefix].get("protocol") == "AXI-Lite"
                else "axi"
            )
            m_axi_patterns.setdefault(pattern, set()).add(family)
            continue
        match = re.fullmatch(r"M_AXI_HPM(\d+)_(FPD|LPD)_(\d+)", prefix)
        if match:
            patterns[
                f"M_AXI_HPM[]_{match.group(2)}_{match.group(3)}"
            ] = f"hpm[]_{match.group(2).lower()}"
            continue
        match = re.fullmatch(r"S_AXI_(HP|HPC)(\d+)_FPD_(\d+)", prefix)
        if match:
            patterns[
                f"S_AXI_{match.group(1)}[]_FPD_{match.group(3)}"
            ] = f"{match.group(1).lower()}[]"
            continue
        match = re.fullmatch(r"S_AXI_(HP|HPC)(\d+)_(\d+)", prefix)
        if match:
            patterns[
                f"S_AXI_{match.group(1)}[]_{match.group(3)}"
            ] = f"{match.group(1).lower()}[]"

    for pattern, families in m_axi_patterns.items():
        if len(families) == 1:
            patterns[pattern] = f"{next(iter(families))}[]"

    for signal in _analysis_flat_ports(data):
        if not _analysis_is_clock_reset(signal["name"]):
            continue
        indexed_match = _ANALYSIS_INDEXED_NAME_RE.match(signal["name"])
        if not indexed_match:
            continue
        name_lower = signal["name"].lower()
        if "clk" in name_lower or "clock" in name_lower:
            patterns[f"{indexed_match.group(1)}[]"] = "ps_clk[]"
        elif "rst" in name_lower or "reset" in name_lower:
            patterns[f"{indexed_match.group(1)}[]"] = "ps_srstn[]"

    for signal in _analysis_flat_ports(data):
        if _analysis_is_clock_reset(signal["name"]):
            continue
        match = _ANALYSIS_PERIPHERAL_SIGNAL_RE.match(signal["name"])
        if match:
            family = match.group(1).upper()
            short_root = _ANALYSIS_PERIPHERAL_NAMES[match.group(1).lower()]
            second_index = match.group(3)
            pattern = f"{family}_[]"
            replacement = short_root + "[]"
            if second_index is not None:
                pattern += f"_{second_index}"
                include_second = any(
                    other_match
                    and other_match.group(1).lower() == match.group(1).lower()
                    and other_match.group(2) == match.group(2)
                    and other_match.group(3) is None
                    for other in data.get("other_ports", [])
                    for other_match in [_ANALYSIS_PERIPHERAL_SIGNAL_RE.match(other["name"])]
                )
                if include_second:
                    replacement += f"_{second_index}"
            patterns[pattern] = replacement
            continue
        match = _ANALYSIS_INDEXED_SIGNAL_RE.match(signal["name"])
        if match:
            family = match.group(1).rstrip("_")
            family_lower = family.lower()
            if family_lower.endswith("_rtl"):
                family_lower = family_lower[:-4].rstrip("_")
                short_root = _ANALYSIS_PERIPHERAL_NAMES.get(family_lower, family_lower)
                family = f"{short_root}_rtl"
            patterns[f"{match.group(1)}[]"] = f"{family}[]"
    return {
        pattern: replacement for pattern, replacement in sorted(patterns.items())
    }


def _analysis_generate_master_arrays(data, name_map):
    arrays = {}
    for prefix, bus in data.get("axi_buses", {}).items():
        if bus.get("role") != "master":
            continue
        match = _ANALYSIS_AXILITE_ARRAY_RE.match(prefix)
        if match:
            array_name = "axilite"
            index = int(match.group(1))
        else:
            match = _ANALYSIS_HPM_ARRAY_RE.match(prefix)
            if not match:
                continue
            array_name = f"hpm_{match.group(2).lower()}"
            index = int(match.group(1))
        array = arrays.setdefault(
            array_name,
            {"protocol": bus.get("protocol", ""), "role": "master", "members": {}},
        )
        array["members"][str(index)] = {
            "original": prefix,
            "name": name_map.get(prefix, prefix),
        }
    return dict(sorted(arrays.items()))


def _analysis_generate_peripheral_arrays(data, name_map):
    arrays = {}
    for signal in _analysis_flat_ports(data):
        match = _ANALYSIS_PERIPHERAL_RE.match(signal["name"])
        if not match:
            continue
        family = _ANALYSIS_PERIPHERAL_NAMES[match.group(1).lower()]
        index = match.group(2).lstrip("_")
        array = arrays.setdefault(family, {"members": {}})
        member = array["members"].setdefault(
            index,
            {
                "original": f"{match.group(1).upper()}{match.group(2)}",
                "name": family,
                "signals": {},
            },
        )
        member["signals"][signal["name"]] = name_map.get(signal["name"], signal["name"])
    return dict(sorted(arrays.items()))


def _analysis_name_map_file(data):
    """Return a compact, hand-editable exact/pattern mapping file."""
    patterns = _analysis_generate_name_patterns(data)
    ignored = sorted({
        pattern for pattern in _DEFAULT_IGNORE_PATTERNS
        if any(_matches_ignore(signal["name"], (pattern,))
               for signal in _analysis_all_signals(data))
    })
    indexable = {
        pattern: 0
        for pattern in patterns
        if "clk" in pattern.casefold()
    }
    mapping = {
        "_ignore": ignored,
        "_non_indexable": {
            pattern: replacement
            for pattern, replacement in patterns.items()
            if pattern in indexable
        },
        "_interfaces": {
            pattern: replacement
            for pattern, replacement in patterns.items()
            if re.match(r"^(?:M|S_AXI_)" , pattern)
        },
        "_indexable": {
            pattern: replacement
            for pattern, replacement in patterns.items()
            if pattern not in indexable
            and not re.match(r"^(?:M|S_AXI_)" , pattern)
        },
    }
    for original, friendly in data.get("name_map", {}).items():
        identity_pattern = _analysis_indexed_identity_pattern(original)
        if (
            identity_pattern
            and resolve_name_mapping(original, mapping) == original
            and friendly == original
        ):
            mapping["_indexable"].setdefault(
                identity_pattern,
                identity_pattern,
            )
    for original, friendly in data.get("name_map", {}).items():
        if _matches_ignored_map_key(original, ignored):
            continue
        if resolve_name_mapping(original, mapping) != friendly:
            mapping[original] = friendly
    return mapping


def _analysis_all_signals(data):
    signals = []
    signals.extend(_analysis_flat_ports(data))
    for bus in data.get("axi_buses", {}).values():
        for channel in bus.get("channels", {}).values():
            signals.extend(channel)
    for bus in data.get("non_axi_buses", {}).values():
        signals.extend(bus.get("signals", []))
    return signals


def _analysis_indexed_identity_pattern(name):
    """Return a compact identity pattern for an indexed source name."""
    parts = name.split("_")
    for index, part in enumerate(parts):
        if part.isdigit():
            return "_".join(parts[:index] + ["[]"]) if index else "[]"
        match = re.fullmatch(r"([A-Za-z]+)(\d+)", part)
        if match:
            return "_".join(parts[:index] + [f"{match.group(1)}[]"])
    return None


_VHDL_IDENTIFIER_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")


def _validate_name_map_entry(pattern, replacement):
    """Validate one exact or compact pattern-based name-map entry."""
    if not isinstance(pattern, str) or not isinstance(replacement, str):
        raise ValueError("name-map keys and values must be strings")
    if pattern.startswith("_"):
        raise ValueError(f"reserved name-map key is not a signal name: {pattern}")
    replacement_index_count = replacement.count("[]") + len(
        re.findall(r"\[-?\d+\]", replacement)
    )
    if pattern.count("[]") + pattern.count("*") != replacement_index_count + replacement.count("*"):
        raise ValueError(
            f"pattern placeholder mismatch: {pattern!r} -> {replacement!r}"
        )
    if pattern.count("*") != replacement.count("*"):
        raise ValueError(
            f"pattern wildcard mismatch: {pattern!r} -> {replacement!r}"
        )
    sample = re.sub(r"\[\]|\[-?\d+\]", "0", replacement).replace("*", "suffix")
    if not _VHDL_IDENTIFIER_RE.fullmatch(sample):
        raise ValueError(
            f"mapped name is not a valid VHDL identifier: {replacement!r}"
        )


def validate_name_map(name_map, source_names=None):
    """Validate a name map and optionally detect resolved-name collisions."""
    if not isinstance(name_map, dict):
        raise ValueError("name-map JSON must contain an object")
    ignored = name_map.get("_ignore", [])
    if not isinstance(ignored, list) or not all(isinstance(item, str) for item in ignored):
        raise ValueError("name-map _ignore must contain a list of strings")
    groups = {
        group_name: name_map.get(group_name, {})
        for group_name in ("_non_indexable", "_patterns", "_indexable", "_interfaces")
    }
    for group_name, entries in groups.items():
        if not isinstance(entries, dict):
            raise ValueError(f"name-map {group_name} must contain an object")
        if any(not isinstance(pattern, str) for pattern in entries):
            raise ValueError("name-map pattern keys must be strings")

    indexable = groups["_indexable"]
    if "_non_indexable" not in name_map and indexable:
        values = set(type(value) for value in indexable.values())
        if values not in ({str}, {int}):
            raise ValueError("name-map _indexable must contain mappings or 0/1 overrides")
        if values == {int}:
            patterns = groups["_patterns"]
            for pattern, value in indexable.items():
                if pattern not in patterns:
                    raise ValueError(f"_indexable pattern is not defined: {pattern}")
                if value not in (0, 1):
                    raise ValueError("name-map pattern indexable must be 0 or 1")

    group_patterns = {}
    for pattern, _entry, _indexable in _name_map_pattern_groups(name_map):
        group_patterns.setdefault(pattern, 0)
        group_patterns[pattern] += 1
    if any(count > 1 for count in group_patterns.values()):
        raise ValueError("name-map groups must contain separate patterns")
    for pattern, entry, group_indexable in _name_map_pattern_groups(name_map):
        replacement, _entry_indexable = _name_pattern_entry(
            pattern, entry, name_map, group_indexable
        )
        _validate_name_map_entry(pattern, replacement)
    for name, replacement in name_map.items():
        if name not in (
            "_non_indexable", "_patterns", "_indexable", "_interfaces", "_ignore"
        ):
            _validate_name_map_entry(name, replacement)
    if source_names is not None:
        resolved_names = {}
        for source_name in source_names:
            if _matches_ignore(source_name, ignored):
                continue
            resolved = resolve_name_mapping(source_name, name_map)
            previous = resolved_names.get(resolved)
            if previous is not None and previous != source_name:
                raise ValueError(
                    f"name-map collision: {previous} and {source_name} both map to {resolved}"
                )
            resolved_names[resolved] = source_name
    return name_map


def load_name_map(path, source_names=None):
    """Load and validate a hand-edited name-map JSON file."""
    map_path = Path(path).expanduser()
    try:
        name_map = json.loads(map_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid name-map JSON in {map_path}: {exc}") from exc
    return validate_name_map(name_map, source_names=source_names)


def _json_dumps_aligned(value, indent_width=2):
    """Serialize JSON while aligning object-member colons per logical block."""
    pattern_groups = ("_non_indexable", "_indexable", "_interfaces")
    pattern_keys = [
        json.dumps(key, ensure_ascii=True)
        for group in pattern_groups
        if isinstance(value, dict) and isinstance(value.get(group), dict)
        for key in value[group]
    ]
    pattern_width = max(map(len, pattern_keys), default=0)

    def render(item, depth, key_width=None):
        prefix = " " * (depth * indent_width)
        if isinstance(item, dict):
            if not item:
                return "{}"
            rendered_items = []
            keys = [json.dumps(key, ensure_ascii=True) for key in item]
            max_key = max(max(map(len, keys)), key_width or 0)
            for key, key_text in zip(item, keys):
                child_key_width = None
                if depth == 0 and key in pattern_groups:
                    child_key_width = pattern_width
                rendered_items.append(
                    " " * ((depth + 1) * indent_width)
                    + key_text.ljust(max_key)
                    + " : "
                    + render(item[key], depth + 1, child_key_width)
                )
            return "{\n" + ",\n".join(rendered_items) + "\n" + prefix + "}"
        if isinstance(item, list):
            if not item:
                return "[]"
            rendered_items = [
                " " * ((depth + 1) * indent_width) + render(element, depth + 1)
                for element in item
            ]
            return "[\n" + ",\n".join(rendered_items) + "\n" + prefix + "]"
        return json.dumps(item, ensure_ascii=True)
    return render(value, 0)


def analyze_wrapper(wrapper_path):
    """Analyze a Vivado VHDL wrapper and return a shim-ready dictionary."""
    path = Path(wrapper_path).expanduser()
    text = path.read_text(encoding="utf-8")
    entity_match = re.search(r"entity\s+(\w+)\s+is", text, re.IGNORECASE)
    if not entity_match:
        raise ValueError(f"could not find entity declaration in {path}")
    entity_name = entity_match.group(1)
    port_match = re.search(
        r"port\s*\((.*?)\)\s*;\s*(?:end\s+\w+|architecture)",
        text, re.IGNORECASE | re.DOTALL
    )
    if not port_match:
        raise ValueError(f"could not find port section in {path}")

    axi_buses = {}
    non_axi_buses = {}
    other_ports = []
    for line in port_match.group(1).splitlines():
        port = _analysis_parse_port(line)
        if port:
            name, direction, port_type, port_range = port
            axi_match = _analysis_classify_axi(name)
            if axi_match:
                prefix, channel, suffix = axi_match
                signal = _analysis_port_dict(name, direction, port_type, port_range)
                signal["suffix"] = suffix
                axi_buses.setdefault(prefix, {}).setdefault(channel, []).append(signal)
                continue
            non_axi_match = _analysis_classify_non_axi(name)
            if non_axi_match:
                prefix, protocol, suffix = non_axi_match
                bus = non_axi_buses.setdefault(
                    prefix, {"protocol": protocol, "role": _analysis_axi_role(prefix), "signals": []}
                )
                signal = _analysis_port_dict(name, direction, port_type, port_range)
                signal["suffix"] = suffix
                bus["signals"].append(signal)
                continue
            signal = _analysis_port_dict(name, direction, port_type, port_range)
            other_ports.append(signal)
    if not other_ports and not axi_buses and not non_axi_buses:
        raise ValueError(f"no ports parsed from {path}")

    other_ports.sort(key=lambda signal: signal["name"])
    for prefix, channels in sorted(axi_buses.items()):
        ordered = {}
        for channel in _AXI_CHANNEL_ORDER:
            if channel in channels:
                channels[channel].sort(
                    key=lambda signal: _ANALYSIS_AXI_SIGNALS[channel].index(
                        signal["suffix"]
                    )
                )
                ordered[channel] = channels[channel]
        axi_buses[prefix] = {
            "protocol": _analysis_axi_type(channels),
            "role": _analysis_axi_role(prefix),
            "channels": ordered,
        }
    for bus in non_axi_buses.values():
        bus["signals"].sort(key=lambda signal: signal["name"])

    result = {
        "entity": entity_name,
        "source_file": str(path.resolve()),
        "other_ports": other_ports,
        "axi_buses": axi_buses,
        "non_axi_buses": dict(sorted(non_axi_buses.items())),
    }
    name_map = _analysis_generate_name_map(result)
    result["name_map"] = name_map
    result["name_patterns"] = _analysis_generate_name_patterns(result)
    result["master_names"] = {
        prefix: name_map[prefix]
        for prefix, bus in axi_buses.items()
        if bus.get("role") == "master" and prefix in name_map
    }
    result["master_arrays"] = _analysis_generate_master_arrays(result, name_map)
    result["peripheral_arrays"] = _analysis_generate_peripheral_arrays(result, name_map)
    return result


# ---------------------------------------------------------------------------
# Vivado wrapper discovery
# ---------------------------------------------------------------------------

_XPR_WRAPPER_RE = re.compile(
    r'<File\s+Path="(?P<path>[^"]+_wrapper\.(?:vhd|v|sv))"\s*/?>',
    re.IGNORECASE,
)
_XPR_BD_RE = re.compile(
    r'<File\s+Path="(?P<path>[^"]+\.bd)"\s*/?>',
    re.IGNORECASE,
)


def _find_xpr(path):
    """Resolve a project argument to one .xpr file."""
    candidate = Path(path).expanduser()
    if candidate.is_file() and candidate.suffix.lower() == ".xpr":
        return candidate.resolve()
    if candidate.is_dir():
        projects = sorted(candidate.glob("*.xpr"))
        if len(projects) == 1:
            return projects[0].resolve()
        if not projects:
            raise ValueError(f"no .xpr file found in {candidate}")
        raise ValueError(f"multiple .xpr files found in {candidate}; specify one")
    raise ValueError(f"Vivado project not found: {candidate}")


def _resolve_xpr_path(project_dir, project_name, value):
    """Resolve common Vivado .xpr path variables to a filesystem path."""
    replacements = {
        "$PGENDIR": project_dir / f"{project_name}.gen",
        "$PSRCDIR": project_dir / f"{project_name}.srcs",
        "$PRUNDIR": project_dir / f"{project_name}.runs",
        "$PPRDIR": project_dir,
    }
    resolved = value
    for variable, replacement in replacements.items():
        resolved = resolved.replace(variable, str(replacement))
    path = Path(resolved).expanduser()
    return path if path.is_absolute() else project_dir / path


def _scan_project_design_files(project_dir):
    """Find all block-design .bd files below a project directory."""
    ignored_parts = {"ip_user_files", "cache"}
    bd_paths = {}
    for path in sorted(project_dir.rglob("*")):
        if not path.is_file() or any(
            part.lower() in ignored_parts for part in path.parts
        ):
            continue
        if path.suffix.lower() == ".bd":
            bd_paths.setdefault(path.stem.lower(), []).append(
                path.resolve(strict=False)
            )
    return bd_paths


def find_wrapper_references(project):
    """Return XPR path, wrapper records, and all scanned block designs."""
    xpr_path = _find_xpr(project)
    text = xpr_path.read_text(encoding="utf-8")
    wrapper_matches = list(_XPR_WRAPPER_RE.finditer(text))
    bd_references = {}
    for match in _XPR_BD_RE.finditer(text):
        reference = match.group("path")
        bd_path = _resolve_xpr_path(xpr_path.parent, xpr_path.stem, reference)
        bd_references.setdefault(Path(reference).stem.lower(), []).append(
            bd_path.resolve(strict=False)
        )

    scanned_bd = _scan_project_design_files(xpr_path.parent)
    seen = set()
    results = []
    for match in wrapper_matches:
        reference = match.group("path")
        resolved = _resolve_xpr_path(xpr_path.parent, xpr_path.stem, reference)
        resolved = resolved.resolve(strict=False)
        key = str(resolved).lower()
        if key in seen:
            continue
        seen.add(key)
        design_name = Path(reference).stem[:-len("_wrapper")].lower()
        bd_paths = [(path, "xpr") for path in bd_references.get(design_name, [])]
        bd_paths.extend(
            (path, "scan") for path in scanned_bd.get(design_name, [])
            if path not in {item[0] for item in bd_paths}
        )
        results.append((resolved, resolved.is_file(), design_name, bd_paths))
    return xpr_path, results, scanned_bd


def search_wrappers(project):
    """Print wrapper and block-design discovery results for a Vivado project."""
    try:
        xpr_path, references, scanned_bd = find_wrapper_references(project)
    except (OSError, ValueError) as exc:
        print(f"hdltool: {exc}", file=sys.stderr)
        return 2

    print(f"Vivado project: {xpr_path}")
    missing = 0
    for resolved, exists, design_name, bd_paths in references:
        status = "FOUND" if exists else "MISSING"
        print(f"{status:7} {resolved}  [{design_name}]")
        if bd_paths:
            for bd_path, source in bd_paths:
                print(f"         .bd [{source}]:  {bd_path}")
        else:
            print("         .bd: MISSING")
        if not exists:
            missing += 1
    if not references:
        print("No generated wrapper references found.")

    referenced_bd_paths = {
        path for _resolved, _exists, _design_name, paths in references
        for path, _source in paths
    }
    unrelated_bd = [
        path for paths in scanned_bd.values() for path in paths
        if path not in referenced_bd_paths
    ]
    if unrelated_bd:
        print("Unrelated block designs found in project folder:")
        for bd_path in unrelated_bd:
            print(f"         .bd [scan]:  {bd_path}")
    else:
        print("Unrelated block designs: none")
    print(f"Wrappers: {len(references)} found, {missing} missing")
    return 1 if missing else 0


# ---------------------------------------------------------------------------
# VHDL shim generation
# ---------------------------------------------------------------------------

_GENERATION_PROFILES = ("flat", "slv-array", "mode-view", "mode-view-array")
_GENERATION_IGNORED_PREFIXES = ("DDR", "FIXED_IO_")
_GENERATION_MAPPED_PERIPHERAL_RE = re.compile(
    r"^(?:(ps|pl)_)?(can|i2c|spi|uart|gpio|mdio|qspi|i2s)"
    r"(\d+)(?:_(\d+))?_",
    re.IGNORECASE,
)
_GENERATION_VECTOR_SUFFIXES = {
    "awid", "awaddr", "awuser", "wdata", "wstrb", "wuser", "bid", "buser",
    "arid", "araddr", "aruser", "rid", "rdata", "ruser", "tdata", "tuser",
    "tid", "tdest", "tkeep", "tstrb",
}


def _generation_group_sort_key(name):
    group = _generation_group_name(name)
    if group.startswith("ps_"):
        return group[3:], 0, name
    if group.startswith("pl_"):
        return group[3:], 1, name
    return group, 0, name


def _generation_signals(data, name_map=None):
    signals = []

    def include(signal):
        name = signal["name"]
        ignored = (name_map or {}).get("_ignore", [])
        if _matches_ignore(name, ignored):
            return False
        if name_map is None:
            return not name.upper().startswith(_GENERATION_IGNORED_PREFIXES)
        return True

    other_ports = [
        signal for signal in _analysis_flat_ports(data) if include(signal)
    ]
    other_ports.sort(
        key=lambda signal: _generation_group_sort_key(
            _generation_mapped_name(signal, name_map)
            if name_map is not None else signal["name"]
        )
    )
    signals.extend(other_ports)
    for prefix, bus in sorted(data.get("axi_buses", {}).items()):
        for channel in _AXI_CHANNEL_ORDER:
            signals.extend(
                signal for signal in bus.get("channels", {}).get(channel, [])
                if include(signal)
            )
    for prefix, bus in sorted(data.get("non_axi_buses", {}).items()):
        signals.extend(signal for signal in bus.get("signals", []) if include(signal))
    return signals


def _generation_array_identity(prefix):
    """Return an indexed-array family for a recognized interface prefix."""
    match = re.fullmatch(r"M(\d+)_AXI_\d+", prefix)
    if match:
        return "axilite", match.group(1)
    match = re.fullmatch(r"M_AXI_HPM(\d+)_(FPD|LPD)_\d+", prefix)
    if match:
        return f"hpm_{match.group(2).lower()}", match.group(1)
    match = re.fullmatch(r"S_AXI_(HP|HPC)(\d+)_FPD_\d+", prefix)
    if match:
        return match.group(1).lower(), match.group(2)
    match = re.fullmatch(r"S_AXI_(HP|HPC)(\d+)_\d+", prefix)
    if match:
        return match.group(1).lower(), match.group(2)
    return None


def _generation_bus_type(bus, prefix):
    """Return a constrained record subtype suitable for generated ports."""
    protocol = bus.get("protocol", "")
    signals = [
        signal
        for channel in bus.get("channels", {}).values()
        for signal in channel
    ]
    widths = {
        signal["suffix"]: signal.get("range", "")
        for signal in signals
        if signal.get("range")
    }
    if protocol == "AXI-Lite":
        address_range = widths.get("awaddr") or widths.get("araddr")
        if address_range == "(39 downto 0)":
            return "axilite_m40_t"
        if address_range == "(31 downto 0)":
            return "axilite_m32_t"
        raise ValueError(
            f"unsupported AXI-Lite address width for {prefix}: {address_range or 'missing'}"
        )
    if protocol == "AXI3":
        if "HP" in prefix or "HPC" in prefix:
            return "axi3_hp_t"
        raise ValueError(
            f"no constrained AXI3 subtype is available for {prefix}"
        )
    if protocol == "AXIS":
        if widths.get("tdata") == "(31 downto 0)":
            return "axis_32b_t"
        raise ValueError(
            f"no constrained AXI-Stream subtype is available for {prefix}"
        )
    if "HPM" in prefix:
        return "axi4_hpm_fpd_t" if "FPD" in prefix else "axi4_hpm_lpd_t"
    if "HP" in prefix or "HPC" in prefix:
        return "axi4_hp_t"
    raise ValueError(
        f"no constrained AXI4 subtype is available for {prefix}"
    )


def _generation_view(bus, prefix):
    protocol = bus.get("protocol", "")
    role = bus.get("role", "")
    if protocol == "AXI-Lite":
        view = "master_axilite" if role == "master" else "slave_axilite"
    elif protocol == "AXI3":
        view = "master_axi3" if role == "master" else "slave_axi3"
    elif protocol == "AXIS":
        view = "master_axis" if role == "master" else "slave_axis"
    else:
        view = "master_axi4" if role == "master" else "slave_axi4"
    return view, _generation_bus_type(bus, prefix)


def _generation_type(signal):
    if signal.get("type") == "std_logic":
        return "std_logic"
    return signal.get("type", "std_logic") + _generation_descending_range(
        signal.get("range", "")
    )


def _generation_descending_range(range_text):
    """Normalize numeric VHDL ranges to descending form."""
    match = re.fullmatch(
        r"\(\s*(\d+)\s+(downto|to)\s*(\d+)\s*\)", range_text,
        re.IGNORECASE,
    )
    if not match:
        return range_text
    left, direction, right = match.groups()
    if direction.casefold() == "to":
        left, right = right, left
    return f"({left} downto {right})"


def _generation_array_type(signal):
    if signal.get("type") == "std_logic":
        return "std_logic_vector({count} downto 0)"
    return "slv_array_t({count} downto 0)" + _generation_descending_range(
        signal.get("range", "")
    )


def _generation_wrapper_name(signal):
    if "original_range" in signal:
        return f'{signal["name"]}(0)'
    return signal["name"]


def _generation_clean_name(name):
    """Remove redundant Vivado peripheral direction/interface suffixes."""
    normalized = name.casefold()
    if normalized in ("tri_io", "tri_i", "tri_o"):
        return ""
    if normalized in ("rxd", "txd"):
        return name[:-1]
    for suffix, replacement in (("_rxd", "_rx"), ("_txd", "_tx")):
        if normalized.endswith(suffix):
            return name[:-len(suffix)] + replacement
    for suffix in ("_tri_io", "_io", "_i", "_o"):
        if normalized.endswith(suffix):
            return name[:-len(suffix)]
    return name


def _generation_mapped_name(signal, name_map):
    return _generation_clean_name(resolve_name_mapping(signal["name"], name_map))


def _generation_indexed_prefix(name, name_map):
    """Return an indexed source prefix, preferring explicit map patterns."""
    patterns = {
        pattern: entry
        for pattern, entry, indexable in _name_map_pattern_groups(name_map)
        if indexable == 1
    }
    for pattern in sorted(patterns, key=len, reverse=True):
        if pattern.count("[]") != 1 or "*" in pattern:
            continue
        before, after = pattern.split("[]")
        match = re.match(
            re.escape(before) + r"(\d+)" + re.escape(after), name
        )
        if match and (
            match.end() == len(name) or name[match.end()] == "_"
        ):
            return match.group(0), match.group(1)
    match = _ANALYSIS_INDEXED_SIGNAL_RE.match(name)
    if match:
        return match.group(0)[:match.end(2)], match.group(2)
    match = _ANALYSIS_INDEXED_NAME_RE.match(name)
    if match:
        return match.group(0), match.group(2)
    return None


def _generation_group_name(name):
    name = name.split("(", 1)[0]
    axi = _analysis_classify_axi(name)
    if axi:
        return f"AXI {axi[0]}"
    non_axi = _analysis_classify_non_axi(name)
    if non_axi:
        return f"{non_axi[1]} {non_axi[0]}"
    peripheral = _ANALYSIS_PERIPHERAL_SIGNAL_RE.match(name)
    if peripheral:
        group = f"{peripheral.group(1)}_{peripheral.group(2)}"
        if peripheral.group(3) is not None:
            group += f"_{peripheral.group(3)}"
        return group
    mapped_peripheral = _GENERATION_MAPPED_PERIPHERAL_RE.match(name)
    if mapped_peripheral:
        domain = mapped_peripheral.group(1)
        family = mapped_peripheral.group(2)
        if domain:
            return f"{domain}_{family}"
        return family
    parts = name.split("_")
    if len(parts) >= 3 and parts[0].casefold() in ("ps", "pl"):
        return "_".join(parts[:2])
    return name.split("_", 1)[0]


def _generation_array_groups(data, name_map):
    """Group map-approved flat ports and structured AXI buses by array name.

    Member indices are assigned from sorted source prefixes, making generated
    declarations and associations deterministic across runs.
    """
    groups = {}
    signal_info = {}
    for prefix, bus in sorted(data.get("axi_buses", {}).items()):
        identity = _generation_array_identity(prefix)
        if identity and _name_is_indexable(prefix, name_map):
            family, member_key = identity
            mapped_prefix = resolve_name_mapping(prefix, name_map)
            match = re.match(r"^(.*?)(\d+)(_.+)?$", mapped_prefix)
            array_name = (match.group(1) + (match.group(3) or "")).rstrip("_") if match else family
            groups.setdefault((array_name, family), {})[prefix] = member_key
            for channel in bus.get("channels", {}).values():
                for signal in channel:
                    signal_info[signal["name"]] = (array_name, prefix)

    for signal in _analysis_flat_ports(data):
        match = _ANALYSIS_PERIPHERAL_SIGNAL_RE.match(signal["name"])
        if match:
            family = _ANALYSIS_PERIPHERAL_NAMES.get(
                match.group(1).lower(), match.group(1).lower()
            )
            prefix = f"{match.group(1).upper()}_{match.group(2)}"
            if match.group(3):
                prefix += f"_{match.group(3)}"
            if not _name_is_indexable(prefix, name_map):
                continue
            mapped_prefix = resolve_name_mapping(prefix, name_map)
            index_match = re.match(r"^(.*?)(\d+)(_.+)?$", mapped_prefix)
            array_name = index_match.group(1).rstrip("_") if index_match else family
            groups.setdefault((array_name, family), {})[prefix] = match.group(2)
            signal_info[signal["name"]] = (array_name, prefix)
        else:
            indexed_prefix = _generation_indexed_prefix(signal["name"], name_map)
            if indexed_prefix is None:
                continue
            prefix, source_index = indexed_prefix
            family = prefix.rsplit("_", 1)[0].rstrip("_")
            if not _name_is_indexable(prefix, name_map):
                continue
            mapped_prefix = resolve_name_mapping(prefix, name_map)
            index_match = re.match(r"^(.*?)(\d+)(_.+)?$", mapped_prefix)
            array_name = index_match.group(1).rstrip("_") if index_match else family
            groups.setdefault((array_name, family), {})[prefix] = source_index
            signal_info[signal["name"]] = (array_name, prefix)

    indices = {}
    for group, members in groups.items():
        indices[group] = {
            prefix: index for index, prefix in enumerate(sorted(members))
        }
    return groups, indices, signal_info


def _generation_indexed_port_binding(
    signal, info, array_groups, array_indices, used_arrays
):
    """Build one indexed flat-port declaration and wrapper association.

    A singleton group drops its outer instance dimension; multi-member groups
    retain it and use the deterministic generated member index.
    """
    if not info:
        return None
    array_name, bus_prefix = info
    group = next(group for group in array_groups if group[0] == array_name)
    index = array_indices[group][bus_prefix]
    member_count = len(array_groups[group])
    field = (
        signal["name"][len(bus_prefix) + 1:]
        if signal["name"].startswith(bus_prefix + "_")
        else ""
    )
    field = _generation_clean_name(field)
    port_name = f"{array_name}_{field}" if field else array_name
    declaration = None
    if port_name not in used_arrays:
        if member_count == 1:
            array_type = _generation_type(signal)
        else:
            array_type = _generation_array_type(signal).format(
                count=member_count - 1
            )
        declaration = (port_name, signal["direction"], array_type)
        used_arrays.add(port_name)
    target = port_name if member_count == 1 else f"{port_name}({index})"
    mapping = (_generation_wrapper_name(signal), target)
    return declaration, mapping


def _generation_port_lines(data, name_map, profile):
    array_groups, array_indices, signal_info = _generation_array_groups(data, name_map)
    declarations = []
    mappings = []
    used_arrays = set()
    used_mode_arrays = set()
    mode_bus_names = {}
    ordered_axi = sorted(data.get("axi_buses", {}).items())
    first_axi_prefix = ordered_axi[0][0] if ordered_axi else None

    for prefix, bus in ordered_axi:
        if profile not in ("mode-view", "mode-view-array") and prefix != first_axi_prefix:
            continue
        if profile in ("mode-view", "mode-view-array") and not _name_is_interface(
            prefix, name_map
        ):
            continue
        if profile in ("mode-view", "mode-view-array"):
            view, type_name = _generation_view(bus, prefix)
            identity = _generation_array_identity(prefix)
            if profile == "mode-view-array" and identity and _name_is_indexable(prefix, name_map):
                family, _member = identity
                scalar_type = _generation_bus_type(bus, prefix)
                candidates = {
                    "hp": "axi4_hp_array_t",
                }
                if family == "axilite":
                    array_type = {
                        "axilite_m40_t": "axilite_m40_array_t",
                        "axilite_m32_t": "axilite_m32_array_t",
                    }[scalar_type]
                elif family == "hp" and bus.get("protocol") == "AXI3":
                    array_type = "axi3_hp_array_t"
                else:
                    array_type = candidates.get(family)
                if (
                    array_type
                    and ((family == "axilite" and bus.get("protocol") == "AXI-Lite")
                         or (family == "hp" and bus.get("protocol") in ("AXI3", "AXI4")))
                ):
                    group = next(
                        group for group in array_groups
                        if group[1] == family
                    )
                    count = len(array_groups[group])
                    array_name = group[0]
                    if count == 1:
                        bus_name = resolve_name_mapping(prefix, name_map)
                        declarations.append(
                            (bus_name, "view", f"view {view} of {scalar_type}")
                        )
                        mode_bus_names[prefix] = (bus_name, None)
                        continue
                    if group not in used_mode_arrays:
                        declarations.append(
                            (array_name, "view",
                                f"view ({view}) of {array_type}({count - 1} downto 0)")
                        )
                        used_mode_arrays.add(group)
                    mode_bus_names[prefix] = (array_name, array_indices[group][prefix])
                    continue
            bus_name = resolve_name_mapping(prefix, name_map)
            declarations.append((bus_name, "view", f"view {view} of {type_name}"))
            mode_bus_names[prefix] = (bus_name, None)
            continue

    if profile not in ("mode-view", "mode-view-array"):
        for signal in _generation_signals(data, name_map):
            info = signal_info.get(signal["name"])
            if profile == "slv-array" and info:
                binding = _generation_indexed_port_binding(
                    signal, info, array_groups, array_indices, used_arrays
                )
                declaration, mapping = binding
                if declaration is not None:
                    declarations.append(declaration)
                mappings.append(mapping)
            else:
                mapped = _generation_mapped_name(signal, name_map)
                declarations.append((mapped, signal["direction"], _generation_type(signal)))
                mappings.append((_generation_wrapper_name(signal), mapped))

    if profile in ("mode-view", "mode-view-array"):
        for signal in _generation_signals(data, name_map):
            axi = _analysis_classify_axi(signal["name"])
            if not axi:
                info = signal_info.get(signal["name"])
                if info:
                    binding = _generation_indexed_port_binding(
                        signal, info, array_groups, array_indices, used_arrays
                    )
                    declaration, mapping = binding
                    if declaration is not None:
                        declarations.append(declaration)
                    mappings.append(mapping)
                    continue
                mapped = _generation_mapped_name(signal, name_map)
                declarations.append((mapped, signal["direction"], _generation_type(signal)))
                mappings.append((_generation_wrapper_name(signal), mapped))
                continue
            prefix, _channel, suffix = axi
            if not _name_is_interface(prefix, name_map):
                continue
            bus_name, index = mode_bus_names[prefix]
            rhs = f"{bus_name}({index}).{suffix}" if index is not None else f"{bus_name}.{suffix}"
            if signal.get("type") == "std_logic" and suffix in _GENERATION_VECTOR_SUFFIXES:
                rhs += "(0)"
            mappings.append((_generation_wrapper_name(signal), rhs))

    return declarations, mappings


def _generation_entity(entity_name, declarations, clauses):
    lines = ["library ieee;", "use ieee.std_logic_1164.all;"]
    lines.extend(f"use work.{clause}.all;" for clause in clauses)
    lines.extend(["", f"entity {entity_name} is", "  port ("])
    last_group = None
    for index, (name, direction, type_name) in enumerate(declarations):
        group = _generation_group_name(name)
        if group != last_group:
            if last_group is not None:
                lines.append("")
            lines.append(f"    -- {group}")
            last_group = group
        terminator = ";" if index < len(declarations) - 1 else ""
        if direction == "view":
            lines.append(f"    {name} : {type_name}{terminator}")
        else:
            lines.append(f"    {name} : {direction} {type_name}{terminator}")
    lines.extend(["  );", f"end entity {entity_name};", ""])
    return lines


def _generation_top(entity_name, shim_entity, declarations, clauses):
    lines = ["library ieee;", "use ieee.std_logic_1164.all;"]
    lines.extend(f"use work.{clause}.all;" for clause in clauses)
    lines.extend(["", f"entity {entity_name} is", f"end entity {entity_name};", ""])
    lines.extend([f"architecture struct of {entity_name} is"])
    last_group = None
    for name, direction, type_name in declarations:
        group = _generation_group_name(name)
        if group != last_group:
            if last_group is not None:
                lines.append("")
            lines.append(f"  -- {group}")
            last_group = group
        if direction == "view":
            type_name = type_name.split(" of ", 1)[-1]
        lines.append(f"  signal {name} : {type_name};")
    lines.extend(["begin", f"  shim_inst : entity work.{shim_entity}", "    port map ("])
    last_group = None
    for index, (name, _direction, _type_name) in enumerate(declarations):
        group = _generation_group_name(name)
        if group != last_group:
            if last_group is not None:
                lines.append("")
            lines.append(f"      -- {group}")
            last_group = group
        comma = "," if index < len(declarations) - 1 else ""
        lines.append(f"      {name} => {name}{comma}")
    lines.extend(["    );", "end architecture struct;", ""])
    return "\n".join(lines)


def _generation_required_packages(declarations, profile):
    """Return packages referenced by the declarations emitted for a profile."""
    packages = []
    type_names = [type_name for _name, _direction, type_name in declarations]
    if any("slv_array_t" in type_name for type_name in type_names):
        packages.append("util_pkg")
    if profile in ("mode-view", "mode-view-array"):
        package_tokens = (
            ("axilite_", "axilite_pkg"),
            ("axi3_", "axi3_pkg"),
            ("axi4_", "axi4_pkg"),
            ("axis_", "axis_pkg"),
        )
        for token, package in package_tokens:
            if any(token in type_name for type_name in type_names):
                packages.append(package)
    return packages


def _generation_files(data, name_map, profile, file_prefix):
    wrapper_entity = data["entity"]
    profile_name = profile.replace("-", "_")
    shim_entity = f"{file_prefix}{profile_name}"
    top_entity = f"{file_prefix}{profile_name}_top"
    if not _VHDL_IDENTIFIER_RE.fullmatch(shim_entity) or not _VHDL_IDENTIFIER_RE.fullmatch(top_entity):
        raise ValueError(
            f"generated prefix produces invalid VHDL entity names: {shim_entity}, {top_entity}"
        )
    declarations, mappings = _generation_port_lines(data, name_map, profile)
    clauses = _generation_required_packages(declarations, profile)

    shim = _generation_entity(shim_entity, declarations, clauses)
    shim.extend([f"architecture struct of {shim_entity} is", "begin",
                 f"  wrapper_inst : entity work.{wrapper_entity}", "    port map ("])
    last_group = None
    for index, (left, right) in enumerate(mappings):
        mapped_group = _generation_group_name(right)
        mapped_peripheral = _GENERATION_MAPPED_PERIPHERAL_RE.match(right)
        group = (
            mapped_group
            if mapped_peripheral
            else _generation_group_name(left)
        )
        if group != last_group:
            if last_group is not None:
                shim.append("")
            shim.append(f"      -- {group}")
            last_group = group
        comma = "," if index < len(mappings) - 1 else ""
        shim.append(f"      {left} => {right}{comma}")
    shim.extend(["    );", f"end architecture struct;", ""])

    top = _generation_top(top_entity, shim_entity, declarations, clauses)
    return "\n".join(shim), top


def _generation_source_names(data, name_map=None):
    return [signal["name"] for signal in _generation_signals(data, name_map)]


def _generation_validated_map(name_map, data):
    name_map.setdefault("_ignore", list(_DEFAULT_IGNORE_PATTERNS))
    return validate_name_map(
        name_map, source_names=_generation_source_names(data, name_map)
    )


def _generation_load_map(wrapper_path, data, map_path):
    if map_path:
        selected_path = Path(map_path).expanduser()
        return _generation_validated_map(load_name_map(selected_path), data)
    current_path = Path.cwd() / "name_map.json"
    wrapper_path_map = Path(wrapper_path).with_name("name_map.json")
    selected_path = current_path if current_path.is_file() else wrapper_path_map
    if selected_path.is_file():
        return _generation_validated_map(load_name_map(selected_path), data)
    return _generation_validated_map(_analysis_name_map_file(data), data)


def _generation_validate_protocol_names(data, name_map):
    """Reject misleading AXI-Lite names on buses classified as full AXI."""
    for prefix, bus in data.get("axi_buses", {}).items():
        if bus.get("protocol") == "AXI-Lite":
            continue
        mapped = resolve_name_mapping(prefix, name_map).lower()
        if mapped.startswith("axilite"):
            raise ValueError(
                f"{prefix} is classified as {bus.get('protocol')}, but the name map "
                f"maps it to {mapped}; use an axi[] name instead of axilite[]"
            )


def generate_vhdl_variants(wrapper_path, output_dir=None, name_map_path=None,
                            profiles=None, style="moderate", prefix=None):
    """Generate shim/top pairs for one or more VHDL profiles."""
    wrapper_path = Path(wrapper_path).expanduser()
    data = analyze_wrapper(wrapper_path)
    name_map = _generation_load_map(wrapper_path, data, name_map_path)
    _generation_validate_protocol_names(data, name_map)
    destination = Path(output_dir).expanduser() if output_dir else Path.cwd()
    destination.mkdir(parents=True, exist_ok=True)
    selected = profiles or _GENERATION_PROFILES
    file_prefix = prefix if prefix is not None else "ps_"
    outputs = []
    for profile in selected:
        shim, top = _generation_files(data, name_map, profile, file_prefix)
        shim = prettify_text(shim, False, lang="vhdl", style=style)
        top = prettify_text(top, False, lang="vhdl", style=style)
        profile_name = profile.replace("-", "_")
        shim_path = destination / f"{file_prefix}{profile_name}.vhd"
        top_path = destination / f"{file_prefix}{profile_name}_top.vhd"
        shim_path.write_text(shim, encoding="utf-8")
        top_path.write_text(top, encoding="utf-8")
        outputs.extend((shim_path, top_path))
    return data, name_map, outputs


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

OPERATIONS = {
    "format", "analyze-wrapper", "search-wrappers",
    "generate-shim", "generate-top", "generate-all",
}


class HdlToolHelpFormatter(argparse.HelpFormatter):
    """Keep common option descriptions on one readable line."""

    def __init__(self, prog):
        super().__init__(prog, max_help_position=40)


def expand_format_paths(values):
    """Expand file and directory arguments into supported HDL files."""
    expanded = []
    for value in values:
        path = Path(value).expanduser()
        if path.is_file():
            expanded.append(path)
            continue
        if not path.is_dir():
            raise OSError(f"input path not found: {path}")
        for child in sorted(path.rglob("*")):
            if not child.is_file() or child.suffix.lower() not in _FORMAT_EXTENSIONS:
                continue
            if any(
                part.lower() in _FORMAT_SKIP_DIRS_LOWER
                or part.lower().endswith(_FORMAT_SKIP_SUFFIXES)
                for part in child.relative_to(path).parts[:-1]
            ):
                continue
            expanded.append(child)
    return expanded


def format_hdl(paths, style, check, indent_width):
    """Format HDL using the bundled whitespace-only implementation."""
    if not paths:
        text = sys.stdin.read()
        lang = "vhdl" if _looks_vhdl(text.splitlines()) else "sv"
        formatted = prettify_text(text, False, lang=lang, style=style,
                                  indent_width=indent_width)
        if check:
            before_lines = text.splitlines()
            after_lines = formatted.splitlines()
            if not _check_invariant(before_lines, after_lines):
                print("hdltool: formatting safety check failed", file=sys.stderr)
                return 3
            print("ok stdin")
        else:
            sys.stdout.write(formatted)
        return 0

    try:
        paths = expand_format_paths(paths)
    except OSError as exc:
        print(f"hdltool: {exc}", file=sys.stderr)
        return 2

    if not paths:
        print("hdltool: no supported HDL files found", file=sys.stderr)
        return 2

    for path in paths:
        try:
            before, after, ok = prettify_file(path, style=style,
                                              indent_width=indent_width)
        except (OSError, ValueError) as exc:
            print(f"hdltool: {exc}", file=sys.stderr)
            return 2
        if not ok:
            print(f"ERROR: {path}: aligner changed non-whitespace content; "
                  "refusing to write", file=sys.stderr)
            return 3
        if before == after:
            print(f"ok     {path}")
            continue
        if check:
            print(f"ok     {path}")
        else:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(after)
            print(f"wrote  {path}")
    return 0


def build_parser():
    parser = argparse.ArgumentParser(
        prog="hdltool",
        description="Format HDL and generate wrapper-based HDL artifacts.",
        formatter_class=HdlToolHelpFormatter,
    )
    parser.add_argument(
        "operation", nargs="?",
        help="format, analyze-wrapper, search-wrappers, generate-shim, generate-top, or generate-all; a path defaults to format",
    )
    parser.add_argument("paths", nargs="*", help="input files, directories, or projects")
    parser.add_argument("--style", "-s", choices=("extreme", "moderate", "collapsed"),
                        default="moderate",
                        help="formatting style")
    parser.add_argument("--indent", "-i", type=int, default=2,
                        help="spaces per indentation level (default: 2)")
    parser.add_argument("--check", "-c", action="store_true",
                        help="check that files can be read and analyzed")
    parser.add_argument("--name-map", metavar="PATH",
                        help="write only the friendly name map to PATH")
    parser.add_argument("--analysis", metavar="PATH",
                        help="write the full analysis dictionary to PATH")
    parser.add_argument("--profile", choices=_GENERATION_PROFILES,
                        default="flat", help="generation profile for shim/top")
    parser.add_argument("--outdir", "-o", metavar="PATH",
                        help="output directory for generated VHDL")
    parser.add_argument("--prefix", metavar="PREFIX",
                        help="generated filename prefix (default: ps_)")
    parser.add_argument("--version", action="version", version=f"hdltool {__version__}")
    return parser


def normalize_args(argv):
    """Treat a first non-operation path as a format target."""
    if argv and not argv[0].startswith("-") and argv[0] not in OPERATIONS:
        return ["format", *argv]
    return argv


def command_format(args, parser):
    """Format files or read piped HDL when no paths are supplied."""
    if not args.paths and sys.stdin.isatty():
        parser.error("format requires a file path or piped input")
    return format_hdl(args.paths, args.style, args.check, args.indent)


def command_search_wrappers(args, parser):
    """Search one explicitly supplied or current-directory Vivado project."""
    if len(args.paths) > 1:
        parser.error("search-wrappers accepts at most one project argument")
    return search_wrappers(args.paths[0] if args.paths else Path.cwd())


def _discover_single_wrapper():
    """Find the only wrapper in the current project or directory."""
    try:
        _project, references, _scanned = find_wrapper_references(Path.cwd())
    except (OSError, ValueError):
        references = []
    found = [path for path, exists, _design, _bd in references if exists]
    if len(found) == 1:
        return found[0]
    if len(found) > 1:
        raise ValueError("current project must contain exactly one existing wrapper")

    candidates = sorted(
        path for path in Path.cwd().rglob("*_wrapper.vhd")
        if path.is_file()
    )
    if len(candidates) == 1:
        return candidates[0]
    raise ValueError("current directory must contain exactly one wrapper file")


def command_analyze_wrapper(args, parser):
    """Analyze one wrapper and print or save its compact name map."""
    wrapper_path = args.paths[0] if args.paths else None
    if len(args.paths) > 2:
        parser.error("analyze-wrapper accepts a wrapper path and optional output JSON path")
    if wrapper_path is None:
        try:
            _project, references, _scanned = find_wrapper_references(Path.cwd())
        except (OSError, ValueError) as exc:
            print(f"hdltool: cannot infer wrapper from current directory: {exc}", file=sys.stderr)
            return 2
        found = [path for path, exists, _design, _bd in references if exists]
        if len(found) != 1:
            print(
                "hdltool: current project must contain exactly one existing wrapper",
                file=sys.stderr,
            )
            return 2
        wrapper_path = str(found[0])
    analysis_path = getattr(args, "analysis", None)
    if len(args.paths) == 2 and analysis_path:
        parser.error("use either a second output path or --analysis, not both")
    try:
        data = analyze_wrapper(wrapper_path)
        mapping = _analysis_name_map_file(data)
        validate_name_map(
            mapping,
            source_names=[signal["name"] for signal in _analysis_all_signals(data)],
        )
    except (OSError, ValueError) as exc:
        print(f"hdltool: {exc}", file=sys.stderr)
        return 2

    name_map_path = getattr(args, "name_map", None)
    if name_map_path:
        name_map_file = Path(name_map_path).expanduser()
        name_map_file.parent.mkdir(parents=True, exist_ok=True)
        name_map_file.write_text(
            _json_dumps_aligned(mapping) + "\n",
            encoding="utf-8",
        )
        print(f"wrote  {name_map_file}")

    json_text = _json_dumps_aligned(data) + "\n"
    output_path = analysis_path or (args.paths[1] if len(args.paths) == 2 else None)
    if not args.paths and not analysis_path and not name_map_path:
        name_map_path = str(Path.cwd() / "name_map.json")
        output_path = None
        name_map_file = Path(name_map_path)
        name_map_file.write_text(
            _json_dumps_aligned(mapping) + "\n", encoding="utf-8"
        )
        print(f"wrote  {name_map_file}")
    if output_path:
        output_path = Path(output_path).expanduser()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json_text, encoding="utf-8")
        print(f"wrote  {output_path}")
    elif not name_map_path:
        sys.stdout.write(_json_dumps_aligned(mapping) + "\n")
    return 0


def command_generate(operation, args, parser):
    """Generate one profile or all four VHDL shim/top pairs."""
    if len(args.paths) > 1:
        parser.error(f"{operation} accepts at most one wrapper path")
    wrapper_path = args.paths[0] if args.paths else None
    if wrapper_path is None:
        try:
            wrapper_path = _discover_single_wrapper()
        except (OSError, ValueError) as exc:
            parser.error(str(exc))
    profiles = _GENERATION_PROFILES if operation == "generate-all" else (args.profile,)
    try:
        _data, _name_map, outputs = generate_vhdl_variants(
            wrapper_path,
            output_dir=args.outdir,
            name_map_path=args.name_map,
            profiles=profiles,
            style=args.style,
            prefix=args.prefix,
        )
    except (OSError, ValueError) as exc:
        print(f"hdltool: {exc}", file=sys.stderr)
        return 2
    for output in outputs:
        print(f"wrote  {output}")
    return 0


def command_placeholder(operation, args):
    """Keep future generation commands visible while they are being built."""
    print(f"hdltool: {operation} operation is not implemented yet")
    for value in args.paths:
        print(f"  input: {Path(value)}")
    return 0


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(normalize_args(argv or sys.argv[1:]))
    operation = args.operation or "format"
    if operation not in OPERATIONS:
        parser.error(f"unknown operation: {operation}")
    if args.analysis and operation != "analyze-wrapper":
        parser.error("--analysis is only valid with analyze-wrapper")
    if args.name_map and operation not in (
        "analyze-wrapper", "generate-shim", "generate-top", "generate-all"
    ):
        parser.error(
            "--name-map is only valid with analyze-wrapper, generate-shim, "
            "generate-top, or generate-all"
        )
    if args.outdir and operation not in ("generate-shim", "generate-top", "generate-all"):
        parser.error(
            "--outdir is only valid with generate-shim, generate-top, or generate-all"
        )

    if operation == "search-wrappers":
        return command_search_wrappers(args, parser)

    if operation == "analyze-wrapper":
        return command_analyze_wrapper(args, parser)

    if operation == "format":
        return command_format(args, parser)

    if operation in ("generate-shim", "generate-top", "generate-all"):
        return command_generate(operation, args, parser)

    return command_placeholder(operation, args)


if __name__ == "__main__":
    sys.exit(main())
