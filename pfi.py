import os
import queue
import re
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Callable, Iterable

import yaml
from ftfcu_appworx import Apwx, JobTime
from oracledb import Connection as DbConnection

__version__ = "2.05"

DATE_RE = re.compile(r"\d{2}[-./]\d{2}[-./]\d{4}$")


@dataclass(frozen=True)
class ScriptArgs:
    tns_service_name: str
    output_path: str
    audit_rpt_yn: str
    report_only: str
    post_date: str
    post_date_file: str
    config_file: str
    max_threads: int


@dataclass(frozen=True)
class ScriptConfig:
    sql: dict[str, str]
    package_pfi_sql: str | None = None


@dataclass
class ScriptData:
    apwx: Apwx
    args: ScriptArgs
    config: ScriptConfig
    job_start_time: datetime


def run(apwx: Apwx) -> bool:
    script_data = initialize(apwx)

    print(f"{datetime.now()}: Starting PFI Job")

    process_entities(script_data)

    print(f"{datetime.now()}: PFI Job Complete")
    return True


def initialize(apwx: Apwx) -> ScriptData:
    with open(apwx.args.CONFIG_FILE, "r", encoding="ascii") as handle:
        config = yaml.safe_load(handle) or {}

    script_args = normalize_args(apwx)
    script_config = ScriptConfig(
        sql=config.get("sql", {}),
        package_pfi_sql=config.get("package_pfi_sql"),
    )

    return ScriptData(
        apwx=apwx,
        args=script_args,
        config=script_config,
        job_start_time=datetime.now(),
    )


def normalize_args(apwx: Apwx) -> ScriptArgs:
    def get_arg(*names: str, default: Any | None = None) -> Any | None:
        for name in names:
            value = getattr(apwx.args, name, None)
            if value is not None:
                return value
        return default

    tns_service_name = get_arg("TNS_SERVICE_NAME")
    output_path = get_arg("OUTPUTPATH", "OUTPUT_FILE_PATH", "OUTPUT_PATH")
    audit_rpt_yn = get_arg("AUDITRPTYN", "AUDIT_RPT_YN", default="N")
    report_only = get_arg("REPORTONLY", "RPTONLY_YN", default="N")
    post_date = get_arg("POSTDATE", "POST_DATE")
    config_file = get_arg("CONFIG_FILE")
    max_threads = int(get_arg("MAX_THREADS", default=1))

    missing = []
    if not tns_service_name:
        missing.append("TNS_SERVICE_NAME")
    if not output_path:
        missing.append("OUTPUTPATH/OUTPUT_FILE_PATH/OUTPUT_PATH")
    if not post_date:
        missing.append("POSTDATE/POST_DATE")
    if not config_file:
        missing.append("CONFIG_FILE")
    if missing:
        raise ValueError(f"Missing required parameters: {', '.join(missing)}")

    audit_rpt_yn = str(audit_rpt_yn).upper()
    report_only = str(report_only).upper()
    if audit_rpt_yn not in {"Y", "N"}:
        raise ValueError("AUDITRPTYN must be Y or N")
    if report_only not in {"Y", "N"}:
        raise ValueError("REPORTONLY must be Y or N")
    if max_threads < 1:
        raise ValueError("MAX_THREADS must be 1 or greater")

    normalized_post_date, file_post_date = normalize_post_date(post_date)

    return ScriptArgs(
        tns_service_name=str(tns_service_name),
        output_path=str(output_path),
        audit_rpt_yn=audit_rpt_yn,
        report_only=report_only,
        post_date=normalized_post_date,
        post_date_file=file_post_date,
        config_file=str(config_file),
        max_threads=max_threads,
    )


def normalize_post_date(post_date: str) -> tuple[str, str]:
    if not DATE_RE.match(post_date):
        raise ValueError(
            "POSTDATE must be in MM/DD/YYYY, MM-DD-YYYY, or MM.DD.YYYY format"
        )

    normalized = re.sub(r"[-.]", "/", post_date)
    compact = re.sub(r"[-./]", "", post_date)
    return normalized, compact


def process_entities(script_data: ScriptData) -> None:
    args = script_data.args
    sqls = script_data.config.sql
    audit_enabled = args.audit_rpt_yn == "Y"
    report_only = args.report_only == "Y"

    work_q: queue.Queue[dict[str, Any] | None] = queue.Queue()
    scribe_q: queue.Queue[tuple[Any, Any, Any, Any] | None] = queue.Queue()
    error_q: queue.Queue[Exception] = queue.Queue()

    worker_count = max(1, args.max_threads - (1 if audit_enabled else 0))
    workers = [
        threading.Thread(
            target=worker,
            args=(
                script_data.apwx,
                sqls,
                args,
                work_q,
                scribe_q,
                worker_id,
                report_only,
                audit_enabled,
                error_q,
            ),
        )
        for worker_id in range(1, worker_count + 1)
    ]

    scribe_thread = None
    if audit_enabled:
        audit_handle, format_line = open_audit_report(args)
        scribe_thread = threading.Thread(
            target=scribe,
            args=(scribe_q, audit_handle, format_line, error_q),
        )
        scribe_thread.start()

    for thread in workers:
        thread.start()

    total = 0
    conn = create_connection(script_data.apwx)
    try:
        for entity in stream_entities(conn, sqls.get("fetch_entities", "")):
            while work_q.qsize() > 50000:
                time.sleep(0.01)
            work_q.put(entity)
            total += 1
    finally:
        conn.close()

    print(f"{datetime.now()}: fetched {total} entities to process")

    for _ in workers:
        work_q.put(None)

    for thread in workers:
        thread.join()

    if audit_enabled and scribe_thread:
        scribe_q.put(None)
        scribe_thread.join()

    if not error_q.empty():
        raise error_q.get()


def stream_entities(conn: DbConnection, sql: str) -> Iterable[dict[str, Any]]:
    if not sql:
        raise ValueError("Missing sql.fetch_entities in config.yaml")

    cursor = conn.cursor()
    try:
        cursor.execute(sql)
        columns = [col[0] for col in cursor.description]
        while True:
            rows = cursor.fetchmany(10000)
            if not rows:
                break
            for row in rows:
                yield dict(zip(columns, row))
    finally:
        cursor.close()


def worker(
    apwx: Apwx,
    sqls: dict[str, str],
    args: ScriptArgs,
    work_q: queue.Queue[dict[str, Any] | None],
    scribe_q: queue.Queue[tuple[Any, Any, Any, Any] | None],
    worker_id: int,
    report_only: bool,
    audit_enabled: bool,
    error_q: queue.Queue[Exception],
) -> None:
    print(f"{datetime.now()}: Starting worker {worker_id}")
    conn = create_connection(apwx)
    cursor = conn.cursor()

    processed = 0
    try:
        while True:
            entity = work_q.get()
            if entity is None:
                work_q.task_done()
                break

            result = process_entity(cursor, sqls, entity, report_only)
            if audit_enabled:
                scribe_q.put(result)

            processed += 1
            if processed % 1000 == 0 and not report_only:
                conn.commit()

            if processed % 10000 == 0:
                print(
                    f"{datetime.now()}: worker {worker_id} processed {processed} records"
                )

            work_q.task_done()

        if report_only:
            conn.rollback()
        else:
            conn.commit()
    except Exception as exc:
        error_q.put(exc)
    finally:
        cursor.close()
        conn.close()
        print(f"{datetime.now()}: Worker {worker_id} finished")


def scribe(
    scribe_q: queue.Queue[tuple[Any, Any, Any, Any] | None],
    handle: Any,
    format_line: Callable[[Any, Any, Any, Any], str],
    error_q: queue.Queue[Exception],
) -> None:
    print(f"{datetime.now()}: Starting scribe")
    count = 0
    try:
        while True:
            result = scribe_q.get()
            if result is None:
                scribe_q.task_done()
                break
            handle.write(format_line(*result))
            handle.write("\n")
            count += 1
            if count % 10000 == 0:
                print(f"{datetime.now()}: scribe wrote {count} records")
            scribe_q.task_done()
    except Exception as exc:
        error_q.put(exc)
    finally:
        handle.close()
        print(f"{datetime.now()}: Scribe finished")


def process_entity(
    cursor: Any,
    sqls: dict[str, str],
    entity: dict[str, Any],
    report_only: bool,
) -> tuple[Any, Any, Any, str]:
    entnbr = entity.get("ENTNBR")
    enttype = entity.get("ENTTYPE")
    pfiyn = entity.get("PFIYN")

    result_msg = ""

    if enttype == "P":
        if pfiyn == "Y":
            if not report_only:
                execute_dml(cursor, sqls.get("pers_uf_merge", ""), {"id": entnbr})
                execute_dml(cursor, sqls.get("pers_warn_delete", ""), {"id": entnbr})
            result_msg = "Added PFI UserField, Deleted PFI Warning Flag"
        else:
            if not report_only:
                execute_dml(cursor, sqls.get("pers_uf_delete", ""), {"id": entnbr})
                execute_dml(cursor, sqls.get("pers_warn_merge", ""), {"id": entnbr})
            result_msg = "Deleted PFI UserField, Added PFI Warning Flag"
    elif enttype == "O":
        if pfiyn == "Y":
            if not report_only:
                execute_dml(cursor, sqls.get("org_uf_merge", ""), {"id": entnbr})
            result_msg = "Added PFI UserField"
        else:
            if not report_only:
                execute_dml(cursor, sqls.get("org_uf_delete", ""), {"id": entnbr})
            result_msg = "Deleted PFI UserField"
    else:
        result_msg = f"Missing Entype for given EntObj {entity}"

    return entnbr, enttype, pfiyn, result_msg


def execute_dml(cursor: Any, sql: str, params: dict[str, Any]) -> None:
    if not sql:
        raise ValueError("Missing DML SQL in config.yaml")
    cursor.execute(sql, params)


def open_audit_report(args: ScriptArgs) -> tuple[Any, Callable[[Any, Any, Any, Any], str]]:
    file_name = f"pfi_flag_audit_report_{args.post_date_file}.txt"
    output_path = os.path.join(args.output_path, file_name)
    handle = open(output_path, "w", encoding="ascii")

    columns = ["EntityNbr", "EntityType", "PFI Y/N", "Notes"]
    format_line = "{:<25.25}{:<15.15}{:<15.15}{:<100.100}".format

    jobid = os.environ.get("JOBID", str(args.post_date))
    handle.write("FIRST TECH FEDERAL CREDIT UNION\n\n")
    handle.write(f"JOBID: {jobid}\n")
    handle.write("JOB NAME: Preferred Financial Institution (PFI)\n")
    handle.write(f"POST DATE: {args.post_date}\n\nPFI Audit Report\n\n")
    handle.write(format_line(*columns))
    handle.write("\n")

    return handle, format_line


def create_connection(apwx: Apwx) -> DbConnection:
    return apwx.db_connect(autocommit=False)


def get_apwx() -> Apwx:
    return Apwx(["OSIUPDATE", "OSIUPDATE_PW"])


def parse_args(apwx: Apwx) -> Apwx:
    parser = apwx.parser
    parser.add_arg("TNS_SERVICE_NAME", type=str, required=True)
    parser.add_arg("OUTPUTPATH", type=str, required=False)
    parser.add_arg("OUTPUT_FILE_PATH", type=str, required=False)
    parser.add_arg("OUTPUT_PATH", type=str, required=False)
    parser.add_arg("AUDITRPTYN", choices=["Y", "N"], default="N", required=False)
    parser.add_arg("AUDIT_RPT_YN", choices=["Y", "N"], default="N", required=False)
    parser.add_arg("REPORTONLY", choices=["Y", "N"], default="N", required=False)
    parser.add_arg("RPTONLY_YN", choices=["Y", "N"], default=None, required=False)
    parser.add_arg("POSTDATE", type=str, required=False)
    parser.add_arg("POST_DATE", type=str, required=False)
    parser.add_arg("CONFIG_FILE", type=r"(.yml|.yaml)$", required=True)
    parser.add_arg("MAX_THREADS", type=int, default=1, required=False)
    apwx.parse_args()
    return apwx


if __name__ == "__main__":
    JobTime().print_start()
    run(parse_args(get_apwx()))
    JobTime().print_end()
