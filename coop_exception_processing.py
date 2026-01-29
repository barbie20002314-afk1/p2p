import csv
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Dict, List, Tuple

__version__ = "2.00"

APPWORX_VARS = ("OSIUPDATE", "OSIUPDATE_PW")

ARG_DEFAULTS = {
    "COOP_INFILE_PATH": ".\\Logs",
    "COOP_INFILE_NAME": "",
    "OSI_INFILE_PATH": ".\\Logs",
    "OSI_INFILE_NAME": "",
    "OUTFILE_PATH": ".\\Logs",
    "MATCHED_FILENAME": "matched.txt",
    "EXCEPTIONS_FILENAME": "exceptions.txt",
}

PATH_KEYS = (
    "COOP_INFILE_PATH",
    "OSI_INFILE_PATH",
    "OUTFILE_PATH",
)

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

HEADER_SKIP_RE = re.compile(
    r"^1CREDIT UNION|  FIRST TECH FCU|  EFBPD020-RP01|0 CARDHOLDER NUMBER|     PLASTIC NUMBER"
)
POSTED_TOTALS_RE = re.compile(r"^0     POSTED TOTALS")
NUMERIC_PREFIX_RE = re.compile(r"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)")


@dataclass
class ScriptData:
    args: dict
    coop: dict = field(
        default_factory=lambda: {
            "cards": {},
            "counters": {
                "processed_trans": 0,
                "skipped_trans": 0,
            },
        }
    )
    dna: dict = field(default_factory=lambda: {"cards": {}})
    matched: List[dict] = field(default_factory=list)
    exceptions: List[dict] = field(default_factory=list)


def fix_data(val):
    if val is None:
        return None
    s = str(val).strip()
    if s.startswith(":"):
        s = s[1:]
    return s.upper()


def parse_kv_args(argv):
    parsed = {}
    for arg in argv:
        if "=" not in arg:
            continue
        key, value = arg.split("=", 1)
        if key.startswith("--"):
            key = key[2:]
        parsed[key] = value
    return parsed


def ensure_trailing_sep(path: str) -> str:
    if not path:
        return path
    if path.endswith(("/", "\\")):
        return path
    sep = "\\" if "\\" in path and "/" not in path else os.sep
    return path + sep


def coerce_decimal(val, remove_commas: bool) -> Decimal:
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


def format_decimal(val) -> str:
    if not isinstance(val, Decimal):
        return "" if val is None else str(val)
    if val == val.to_integral_value():
        return str(int(val))
    s = format(val, "f")
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s


def parse_fixed_width(line: str, fields: List[Tuple[str, int]]) -> Dict[str, str]:
    data = {}
    pos = 0
    for name, width in fields:
        data[name] = line[pos : pos + width]
        pos += width
    return data


def get_appworx_params(argv) -> dict:
    args = dict(ARG_DEFAULTS)

    for key in args:
        if key in os.environ:
            args[key] = os.environ[key]

    cli_args = parse_kv_args(argv)
    for key, value in cli_args.items():
        if key in args:
            args[key] = value

    jobid = os.environ.get("JOBID")
    if not jobid:
        raise SystemExit("ENV JOBID is required")

    missing_apwx = [var for var in APPWORX_VARS if not os.environ.get(var)]
    if missing_apwx:
        raise SystemExit(f"Missing APWX vars: {', '.join(missing_apwx)}")

    for key in PATH_KEYS:
        if not args.get(key) or not os.path.isdir(args[key]):
            raise SystemExit(f"Invalid directory for {key}: {args.get(key)}")

    for key in PATH_KEYS:
        args[key] = ensure_trailing_sep(args[key])

    params = {"ARGV": args}
    params["incoopfile"] = args["COOP_INFILE_PATH"] + args["COOP_INFILE_NAME"]
    params["inosifile"] = args["OSI_INFILE_PATH"] + args["OSI_INFILE_NAME"]
    params["outmatchfile"] = args["OUTFILE_PATH"] + args["MATCHED_FILENAME"]
    params["outexcpfile"] = args["OUTFILE_PATH"] + args["EXCEPTIONS_FILENAME"]
    return params


def process():
    data = ScriptData(args=get_appworx_params(sys.argv[1:]))

    print(f"{datetime.now().ctime()}: AppWorx params received")
    print("I was passed the following parameters:", file=sys.stderr)
    print(data.args["ARGV"], file=sys.stderr)

    print(f"{datetime.now().ctime()}: Parsing COOP recon report")
    parse_coop_file(data)

    print(f"{datetime.now().ctime()}: Parsing OSI recon report")
    parse_osi_file(data)

    print(f"{datetime.now().ctime()}: Processing data")
    process_coop_data(data)

    prepare_data_for_file(data)

    print(f"{datetime.now().ctime()}: Writing matched file")
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
    write_file(data.matched, data.args["outmatchfile"], field_order)

    print(f"{datetime.now().ctime()}: Writing exception file")
    write_file(data.exceptions, data.args["outexcpfile"], field_order)

    print("Job complete.")


def parse_coop_file(data: ScriptData) -> None:
    with open(data.args["incoopfile"], encoding="utf-8") as fh:
        rpt_start = False
        tran_line = 0
        pan = None
        card = None
        tn = None

        for raw_line in fh:
            line = raw_line.rstrip("\n")

            if not rpt_start:
                if "EFBPD020-RP01" in line:
                    rpt_start = True
                continue

            if POSTED_TOTALS_RE.match(line):
                break

            if HEADER_SKIP_RE.search(line):
                continue

            if tran_line == 0:
                if not (len(line) >= 17 and line[0] == " " and line[1:17].isdigit()):
                    continue

                fields = parse_fixed_width(line, LINE0_FIELDS)
                sign1 = fields["sign1"]
                sign2 = fields["sign2"]
                c_sign1 = fields["c_sign1"]
                c_sign2 = fields["c_sign2"]

                if any(fix_data(s) == "*" for s in (sign1, sign2, c_sign1, c_sign2)):
                    data.coop["counters"]["skipped_trans"] += 1
                    continue

                pan = fix_data(fields["pan"])
                card = data.coop["cards"].setdefault(
                    pan, {"trans": {}, "tran_count": 0, "has_reversal_tran": "N"}
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

                trans["tranamt"] = coerce_decimal(tranamt_str, remove_commas=True)

                if fix_data(sign1) == "-" or fix_data(c_sign1) == "-":
                    trans["reversal"] = "Y"
                    card["has_reversal_tran"] = "Y"
                else:
                    trans["reversal"] = "N"

                trans["matched"] = "N"

                tran_line = 1
                continue

            if tran_line == 1 and card is not None and tn is not None:
                fields = parse_fixed_width(line, LINE1_FIELDS)
                for name, _width in LINE1_FIELDS:
                    card["trans"][tn][name] = fix_data(fields[name])
                tran_line = 2
                continue

            if tran_line == 2 and card is not None and tn is not None:
                fields = parse_fixed_width(line, LINE2_FIELDS)
                for name, _width in LINE2_FIELDS:
                    card["trans"][tn][name] = fix_data(fields[name])
                data.coop["counters"]["processed_trans"] += 1
                tran_line = 0


def parse_osi_file(data: ScriptData) -> None:
    with open(data.args["inosifile"], newline="", encoding="utf-8") as fh:
        reader = csv.reader(fh)

        for row in reader:
            if not row:
                continue

            rec = {}
            for idx, key in enumerate(OSI_COLUMNS):
                rec[key] = row[idx] if idx < len(row) else ""

            rec["pan"] = rec["pan"][:16]
            for key in list(rec.keys()):
                rec[key] = fix_data(rec[key])

            pan = rec["pan"]
            card = data.dna["cards"].setdefault(pan, {"trans": {}, "tran_count": 0})

            tc = card["tran_count"]
            card["tran_count"] += 1

            rec["trantyp"] = dna_trancode_convert(rec.get("trancd"))
            rec["matched"] = "N"
            rec["tranamt"] = coerce_decimal(rec.get("tranamt"), remove_commas=False)
            rec["reversal"] = "-"
            rec["desc"] = "-"

            card["trans"][tc] = rec


def process_coop_data(data: ScriptData) -> None:
    for card in data.coop["cards"].values():
        if card.get("has_reversal_tran") == "Y":
            mark_reversals(card["trans"])

        for ct in card["trans"].values():
            if ct.get("matched") != "N":
                continue

            dna_card = data.dna["cards"].get(ct.get("pan"))
            if not dna_card:
                ct["matched"] = "NP"
                continue

            for d in dna_card["trans"].values():
                if d.get("matched") != "N":
                    continue

                if ct.get("tranamt") == d.get("tranamt") and ct.get("trantyp") == d.get(
                    "trantyp"
                ):
                    if ct.get("local_term") == d.get("local_term"):
                        ct_seq = ct.get("local_seq")
                        d_seq = d.get("local_seq")
                        if ct_seq == d_seq or (
                            ct_seq is not None and d_seq is not None and ct_seq in d_seq
                        ):
                            ct["matched"] = "C"
                            d["matched"] = "C"
                        else:
                            ct["matched"] = "P"
                            d["matched"] = "P"
                        break


def mark_reversals(trans: Dict[int, dict]) -> None:
    for rt in trans.values():
        if rt.get("reversal") != "Y":
            continue

        for ot in trans.values():
            if ot.get("matched") == "RC":
                continue
            if ot.get("reversal") == "Y":
                continue

            if rt.get("sw_term") == ot.get("sw_term") and rt.get("sw_seq") == ot.get(
                "sw_seq"
            ):
                if rt.get("tranamt") == ot.get("tranamt"):
                    rt["matched"] = "RC"
                    ot["matched"] = "RC"
                    break

                rt["matched"] = "RC"
                ot["tranamt"] = abs(ot.get("tranamt") - rt.get("tranamt"))
                ot["reversal"] = "Y"


def prepare_data_for_file(data: ScriptData) -> None:
    messages = {
        "C": "Complete match to DNA file",
        "P": "Partial - Matched to DNA",
        "NP": "PAN not found in DNA ATM/Recon file",
        "N": "Unmatched transaction",
    }

    for system, sys_data in (("coop", data.coop), ("dna", data.dna)):
        for card in sys_data["cards"].values():
            for tran in card["trans"].values():
                if tran.get("matched") in ("RC", "RP"):
                    continue

                tran["message"] = messages.get(tran.get("matched"), "")

                if system == "coop" and tran.get("matched") in ("C", "P"):
                    data.matched.append(tran)
                elif tran.get("matched") in ("NP", "N"):
                    if tran.get("matched") == "N":
                        tran["message"] += " - " + system.upper()
                    data.exceptions.append(tran)


def write_file(records: List[dict], filename: str, field_order: List[str]) -> None:
    with open(filename, "w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(
            fh,
            delimiter="|",
            quoting=csv.QUOTE_NONE,
            escapechar="\\",
            lineterminator="\n",
        )

        if not records:
            return

        for rec in records:
            row = []
            for field in field_order:
                value = rec.get(field)
                if field == "tranamt":
                    row.append(format_decimal(value))
                elif value is None:
                    row.append("")
                else:
                    row.append(str(value))
            writer.writerow(row)


def dna_trancode_convert(tc: str) -> str:
    mapping = {
        "DWTH": "DEBIT",
        "PWTH": "DEBIT",
        "DWTF": "DEBIT",
        "DDEP": "CREDIT",
        "PDEP": "CREDIT",
        "DWTT": "CREDIT",
    }
    return mapping.get(tc, tc)


if __name__ == "__main__":
    process()
