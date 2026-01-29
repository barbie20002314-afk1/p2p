import csv
import os
import re
from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal, InvalidOperation
from enum import StrEnum, auto
from pathlib import Path
from typing import Dict, List, Tuple

from ftfcu_appworx import Apwx, JobTime

__version__ = "2.00"

ARG_DEFAULTS = {
    "COOP_INFILE_PATH": ".\\Logs",
    "COOP_INFILE_NAME": "",
    "OSI_INFILE_PATH": ".\\Logs",
    "OSI_INFILE_NAME": "",
    "OUTFILE_PATH": ".\\Logs",
    "MATCHED_FILENAME": "matched.txt",
    "EXCEPTIONS_FILENAME": "exceptions.txt",
}

OSI_COLUMNS = [
    "pan",
    "datetime",
    "trancd",
    "tranamt",
    "acctnbr",
    "local_seq",
    "transtat",
    "local_term",
]

LINE0_FIELDS: List[Tuple[str, int]] = [
    ("pan", 17),
    ("trancd", 13),
    ("junk", 1),
    ("debit", 11),
    ("sign1", 1),
    ("sign2", 1),
    ("credit", 12),
    ("c_sign1", 1),
    ("c_sign2", 1),
    ("fee", 8),
    ("sw_date", 5),
    ("sw_time", 9),
    ("term_rtnbr", 11),
    ("sw_term", 8),
    ("sw_seq", 9),
]

LINE1_FIELDS: List[Tuple[str, int]] = [
    ("junk", 7),
    ("acctnbr", 10),
    ("junk2", 49),
    ("loc_date", 5),
    ("loc_time", 9),
    ("card_rtnbr", 11),
    ("local_term", 11),
    ("local_seq", 16),
]

LINE2_FIELDS: List[Tuple[str, int]] = [
    ("junk", 61),
    ("desc", 70),
]

TRAN_LINE_RE = re.compile(r"^ \d{16,}")
HEADER_SKIP_RE = re.compile(
    r"^1CREDIT UNION|  FIRST TECH FCU|  EFBPD020-RP01|0 CARDHOLDER NUMBER|     PLASTIC NUMBER"
)
POSTED_TOTALS_RE = re.compile(r"^0     POSTED TOTALS")
NUMERIC_PREFIX_RE = re.compile(r"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)")


# ------------------------------------------------------------
# AppWorx Arguments
# ------------------------------------------------------------
class AppWorxEnum(StrEnum):
    COOP_INFILE_PATH = auto()
    COOP_INFILE_NAME = auto()
    OSI_INFILE_PATH = auto()
    OSI_INFILE_NAME = auto()
    OUTFILE_PATH = auto()
    MATCHED_FILENAME = auto()
    EXCEPTIONS_FILENAME = auto()

    def __str__(self):
        return self.name


# ------------------------------------------------------------
# Script Data Container
# ------------------------------------------------------------
@dataclass
class ScriptData:
    apwx: Apwx

    coop_file: Path
    osi_file: Path
    matched_file: Path
    exception_file: Path

    coop: dict = field(default_factory=lambda: {
        "cards": {},
        "counters": {
            "processed_trans": 0,
            "skipped_trans": 0,
        },
    })

    dna: dict = field(default_factory=lambda: {
        "cards": {},
    })

    matched: List[dict] = field(default_factory=list)
    exceptions: List[dict] = field(default_factory=list)


# ------------------------------------------------------------
# Main Runner
# ------------------------------------------------------------
def run(apwx: Apwx) -> bool:
    print(f"Job started at {datetime.now()}")

    data = initialize(apwx)

    print("Parsing COOP recon report")
    parse_coop_file(data)

    print("Parsing OSI recon report")
    parse_osi_file(data)

    print("Processing transactions")
    process_coop_data(data)

    print("Preparing output data")
    prepare_data_for_file(data)

    print("Writing matched file")
    write_file(data.matched, data.matched_file)

    print("Writing exception file")
    write_file(data.exceptions, data.exception_file)

    print(f"Job completed at {datetime.now()}")
    return True


# ------------------------------------------------------------
# Initialization
# ------------------------------------------------------------
def initialize(apwx: Apwx) -> ScriptData:
    args = apwx.args
    apply_defaults(args)
    validate_appworx_env(apwx)
    validate_paths(args)
    normalize_paths(args)

    coop_file = Path(f"{args.COOP_INFILE_PATH}{args.COOP_INFILE_NAME}")
    osi_file = Path(f"{args.OSI_INFILE_PATH}{args.OSI_INFILE_NAME}")
    matched_file = Path(f"{args.OUTFILE_PATH}{args.MATCHED_FILENAME}")
    exception_file = Path(f"{args.OUTFILE_PATH}{args.EXCEPTIONS_FILENAME}")

    return ScriptData(
        apwx=apwx,
        coop_file=coop_file,
        osi_file=osi_file,
        matched_file=matched_file,
        exception_file=exception_file,
    )


# ------------------------------------------------------------
# COOP Fixed-Width Parsing (FULL Perl Parity)
# ------------------------------------------------------------
def parse_coop_file(data: ScriptData) -> None:
    with open(data.coop_file, encoding="utf-8") as fh:
        rpt_start = False
        tran_line = 0
        pan = None
        card = None
        tn = None

        for line in fh:
            line = line.rstrip("\n")

            if not rpt_start:
                if "EFBPD020-RP01" in line:
                    rpt_start = True
                continue

            if POSTED_TOTALS_RE.match(line):
                break

            if HEADER_SKIP_RE.search(line):
                continue

            # -------------------------
            # Line 0 (main transaction)
            # -------------------------
            if tran_line == 0:
                if not TRAN_LINE_RE.match(line):
                    continue

                fields = parse_fixed_width(line, LINE0_FIELDS)
                sign1 = fields["sign1"]
                sign2 = fields["sign2"]
                c_sign1 = fields["c_sign1"]
                c_sign2 = fields["c_sign2"]

                # Skip pre-auths
                if any(fix_data(s) == "*" for s in (sign1, sign2, c_sign1, c_sign2)):
                    data.coop["counters"]["skipped_trans"] += 1
                    continue

                pan = fix_data(fields["pan"])
                card = data.coop["cards"].setdefault(
                    pan,
                    {"trans": {}, "tran_count": 0, "has_reversal_tran": "N"},
                )

                tn = card["tran_count"] = card["tran_count"] + 1
                trans = card["trans"].setdefault(tn, {})

                for name, _width in LINE0_FIELDS:
                    trans[name] = fix_data(fields[name])

                if card.get("has_reversal_tran") != "Y":
                    card["has_reversal_tran"] = "N"

                raw_debit = fields["debit"]
                raw_credit = fields["credit"]

                if raw_debit.strip() != "":
                    trans["trantyp"] = "DEBIT"
                    tranamt_str = trans["debit"]
                elif raw_credit.strip() != "":
                    trans["trantyp"] = "CREDIT"
                    tranamt_str = trans["credit"]
                else:
                    trans["trantyp"] = ""
                    tranamt_str = "0"

                trans["tranamt"] = parse_amount(tranamt_str, remove_commas=True)

                reversal = "Y" if fix_data(sign1) == "-" or fix_data(c_sign1) == "-" else "N"
                trans["reversal"] = reversal
                if reversal == "Y":
                    card["has_reversal_tran"] = "Y"

                trans["matched"] = "N"

                tran_line = 1
                continue

            # -------------------------
            # Line 1
            # -------------------------
            if tran_line == 1 and card is not None and tn is not None:
                fields = parse_fixed_width(line, LINE1_FIELDS)
                for name, _width in LINE1_FIELDS:
                    card["trans"][tn][name] = fix_data(fields[name])
                tran_line = 2
                continue

            # -------------------------
            # Line 2
            # -------------------------
            if tran_line == 2 and card is not None and tn is not None:
                fields = parse_fixed_width(line, LINE2_FIELDS)
                for name, _width in LINE2_FIELDS:
                    card["trans"][tn][name] = fix_data(fields[name])
                data.coop["counters"]["processed_trans"] += 1
                tran_line = 0


# ------------------------------------------------------------
# OSI (DNA) Parsing
# ------------------------------------------------------------
def parse_osi_file(data: ScriptData) -> None:
    with open(data.osi_file, newline="", encoding="utf-8") as fh:
        reader = csv.reader(fh)

        for row in reader:
            if not row:
                continue

            rec = {}
            for idx, key in enumerate(OSI_COLUMNS):
                rec[key] = row[idx] if idx < len(row) else ""

            # Limit pan to 16 digits
            rec["pan"] = rec["pan"][:16]

            # Make the data spiffy and clean
            for key in list(rec.keys()):
                rec[key] = fix_data(rec[key])

            pan = rec["pan"]
            card = data.dna["cards"].setdefault(
                pan, {"trans": {}, "tran_count": 0}
            )

            idx = card["tran_count"]
            card["tran_count"] += 1

            rec["pan"] = pan
            rec["tranamt"] = parse_amount(rec["tranamt"], remove_commas=False)
            rec["trantyp"] = dna_trancode_convert(rec["trancd"])
            rec["matched"] = "N"
            rec["reversal"] = "-"
            rec["desc"] = "-"

            card["trans"][idx] = rec


# ------------------------------------------------------------
# Matching Logic (Unchanged – already equivalent)
# ------------------------------------------------------------
def process_coop_data(data: ScriptData) -> None:
    for card in data.coop["cards"].values():

        if card.get("has_reversal_tran") == "Y":
            mark_reversals(card["trans"])

        for ct in card["trans"].values():
            if ct["matched"] != "N":
                continue

            dna_card = data.dna["cards"].get(ct["pan"])
            if not dna_card:
                ct["matched"] = "NP"
                continue

            for d in dna_card["trans"].values():
                if d["matched"] != "N":
                    continue

                if ct["tranamt"] == d["tranamt"] and ct["trantyp"] == d["trantyp"]:
                    if ct["local_term"] == d["local_term"]:
                        ct_seq = ct.get("local_seq")
                        d_seq = d.get("local_seq")
                        if ct_seq == d_seq or (
                            ct_seq is not None and d_seq is not None and ct_seq in d_seq
                        ):
                            ct["matched"] = d["matched"] = "C"
                        else:
                            ct["matched"] = d["matched"] = "P"
                        break


# ------------------------------------------------------------
# Reversal Matching
# ------------------------------------------------------------
def mark_reversals(trans: Dict[int, dict]) -> None:
    for rt in trans.values():
        if rt["reversal"] != "Y":
            continue

        for ot in trans.values():
            if ot["matched"] == "RC" or ot["reversal"] == "Y":
                continue

            if rt["sw_term"] == ot["sw_term"] and rt["sw_seq"] == ot["sw_seq"]:
                if rt["tranamt"] == ot["tranamt"]:
                    rt["matched"] = ot["matched"] = "RC"
                    break
                rt["matched"] = "RC"
                ot["tranamt"] = abs(ot["tranamt"] - rt["tranamt"])
                ot["reversal"] = "Y"


# ------------------------------------------------------------
# Prepare Output
# ------------------------------------------------------------
def prepare_data_for_file(data: ScriptData) -> None:
    messages = {
        "C": "Complete match to DNA file",
        "P": "Partial - Matched to DNA",
        "NP": "PAN not found in DNA ATM/Recon file",
        "N": "Unmatched transaction",
    }

    for system in ("coop", "dna"):
        for card in data.__dict__[system]["cards"].values():
            for tran in card["trans"].values():

                if tran["matched"] in ("RC", "RP"):
                    continue

                tran["message"] = messages.get(tran["matched"], "")

                if system == "coop" and tran["matched"] in ("C", "P"):
                    data.matched.append(tran)

                elif tran["matched"] in ("NP", "N"):
                    if tran["matched"] == "N":
                        tran["message"] += f" - {system.upper()}"
                    data.exceptions.append(tran)


# ------------------------------------------------------------
# Write Output Files
# ------------------------------------------------------------
def write_file(records: List[dict], filename: Path) -> None:
    field_order = [
        "pan",
        "local_seq",
        "local_term",
        "tranamt",
        "acctnbr",
        "trantyp",
        "trancd",
        "reversal",
        "desc",
        "message",
    ]

    with open(filename, "w", encoding="utf-8", newline="") as fh:
        if not records:
            return

        for rec in records:
            row = []
            for field in field_order:
                value = rec.get(field)
                if field == "tranamt":
                    row.append(format_amount(value))
                elif value is None:
                    row.append("")
                else:
                    row.append(str(value))
            fh.write("|".join(row) + "\n")


# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
def dna_trancode_convert(tc: str) -> str:
    return {
        "DWTH": "DEBIT",
        "PWTH": "DEBIT",
        "DWTF": "DEBIT",
        "DDEP": "CREDIT",
        "PDEP": "CREDIT",
        "DWTT": "CREDIT",
    }.get(tc, tc)


def fix_data(val):
    if val is None:
        return None
    s = str(val).strip()
    if s.startswith(":"):
        s = s[1:]
    return s.upper()


def parse_fixed_width(line: str, fields: List[Tuple[str, int]]) -> Dict[str, str]:
    data = {}
    pos = 0
    for name, width in fields:
        data[name] = line[pos : pos + width]
        pos += width
    return data


def parse_amount(val, remove_commas: bool) -> Decimal:
    if val is None:
        return Decimal("0")
    s = str(val).strip()
    if remove_commas:
        s = s.replace(",", "")
    match = NUMERIC_PREFIX_RE.match(s)
    if not match:
        return Decimal("0")
    try:
        return Decimal(match.group(0))
    except InvalidOperation:
        return Decimal("0")


def format_amount(val) -> str:
    if not isinstance(val, Decimal):
        return "" if val is None else str(val)
    if val == val.to_integral_value():
        return str(int(val))
    s = format(val, "f")
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s


def apply_defaults(args) -> None:
    for key, default in ARG_DEFAULTS.items():
        if getattr(args, key, None) is None:
            setattr(args, key, default)


def ensure_trailing_backslash(path: str) -> str:
    if not path.endswith("\\"):
        return path + "\\"
    return path


def normalize_paths(args) -> None:
    args.COOP_INFILE_PATH = ensure_trailing_backslash(args.COOP_INFILE_PATH)
    args.OSI_INFILE_PATH = ensure_trailing_backslash(args.OSI_INFILE_PATH)
    args.OUTFILE_PATH = ensure_trailing_backslash(args.OUTFILE_PATH)


def validate_paths(args) -> None:
    for key in ("COOP_INFILE_PATH", "OSI_INFILE_PATH", "OUTFILE_PATH"):
        value = getattr(args, key, None)
        if not value:
            raise ValueError(f"Missing path value for {key}")
        if not Path(value).is_dir():
            raise ValueError(f"Invalid directory for {key}: {value}")


def validate_appworx_env(apwx: Apwx) -> None:
    if not os.environ.get("JOBID"):
        raise ValueError("ENV JOBID is required")

    missing = []
    for key in ("OSIUPDATE", "OSIUPDATE_PW"):
        value = None
        if hasattr(apwx, "vars") and isinstance(apwx.vars, dict):
            value = apwx.vars.get(key)
        if value is None and hasattr(apwx, "get_var"):
            try:
                value = apwx.get_var(key)
            except Exception:
                value = None
        if value is None:
            value = os.environ.get(key)
        if not value:
            missing.append(key)
    if missing:
        raise ValueError(f"Missing AppWorx vars: {', '.join(missing)}")


# ------------------------------------------------------------
# AppWorx Bootstrap
# ------------------------------------------------------------
def parse_args(apwx: Apwx) -> Apwx:
    parser = apwx.parser
    for arg in AppWorxEnum:
        parser.add_arg(arg, type=str, required=False)
    apwx.parse_args()
    return apwx


def get_apwx() -> Apwx:
    return Apwx(["OSIUPDATE", "OSIUPDATE_PW"])


if __name__ == "__main__":
    JobTime().print_start()
    run(parse_args(get_apwx()))
    JobTime().print_end()
