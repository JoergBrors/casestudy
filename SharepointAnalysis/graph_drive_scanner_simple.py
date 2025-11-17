"""
Simple synchronous Microsoft Graph Drive scanner.

Features:
- App-only client_credentials token via requests
- Recursive drive listing (paging)
- Parallel per-file enrichment using ThreadPoolExecutor
- Dry-run mode using existing `dryrun_mock.json`
- JSON export

This script is a simpler alternative to the async scanner and is
designed to be more predictable on Windows terminals and easier to
debug when external signals are present.
"""
from __future__ import annotations
import argparse
import json
import os
import sys
import time
import logging
from typing import List, Dict, Any, Optional
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed
import signal
import traceback
import getpass

try:
    from tqdm import tqdm
except Exception:
    # minimal fallback
    def tqdm(it=None, **kwargs):
        return it if it is not None else []

LOG = logging.getLogger("graph_drive_scanner_simple")

# Diagnostic startup log for the simple scanner
DIAG_SIMPLE_PATH = os.path.join(os.path.dirname(__file__), 'diagnostic_simple_startup.log')


def _append_diag_simple(msg: str):
    try:
        with open(DIAG_SIMPLE_PATH, 'a', encoding='utf-8') as df:
            df.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {msg}\n")
    except Exception:
        try:
            LOG.debug("Failed to write diagnostic_simple_startup.log")
        except Exception:
            pass


def install_simple_startup_diagnostics():
    try:
        _append_diag_simple("--- startup diagnostics (simple scanner) ---")
        _append_diag_simple(f"PID={os.getpid()} PPID={getattr(os, 'getppid', lambda: None)()} PY={sys.executable}")
        _append_diag_simple(f"CWD={os.getcwd()} ARGV={' '.join(sys.argv)} USER={getpass.getuser()}")
        keys = ['GRAPH_TENANT_ID', 'TENANT_ID', 'GRAPH_CLIENT_ID', 'CLIENT_ID', 'GRAPH_CLIENT_SECRET', 'CLIENT_SECRET', 'DRIVE_ID']
        for k in keys:
            v = os.environ.get(k)
            if v is None:
                _append_diag_simple(f"ENV {k}=<missing>")
            else:
                _append_diag_simple(f"ENV {k}=<present len={len(v)}>")

        def _exc_hook(exc_type, exc, tb):
            try:
                _append_diag_simple("UNCAUGHT EXCEPTION:")
                _append_diag_simple(''.join(traceback.format_exception(exc_type, exc, tb)))
            except Exception:
                pass
            try:
                sys.__excepthook__(exc_type, exc, tb)
            except Exception:
                pass

        sys.excepthook = _exc_hook

        def _sig_handler(sig, frame):
            try:
                _append_diag_simple(f"RECEIVED SIGNAL: {sig}")
                try:
                    _append_diag_simple(''.join(traceback.format_stack(frame)))
                except Exception:
                    pass
            finally:
                try:
                    for h in logging.root.handlers:
                        try:
                            h.flush()
                        except Exception:
                            pass
                except Exception:
                    pass
                try:
                    os._exit(1)
                except Exception:
                    pass

        for s in ('SIGINT', 'SIGTERM'):
            try:
                sigobj = getattr(signal, s)
                signal.signal(sigobj, _sig_handler)
            except Exception:
                pass
    except Exception:
        try:
            LOG.debug("Failed to install simple startup diagnostics")
        except Exception:
            pass


# Install simple diagnostics early
install_simple_startup_diagnostics()


def acquire_token(tenant_id: str, client_id: str, client_secret: str) -> str:
    url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"
    data = {
        "client_id": client_id,
        "scope": "https://graph.microsoft.com/.default",
        "client_secret": client_secret,
        "grant_type": "client_credentials",
    }
    r = requests.post(url, data=data, timeout=30)
    if r.status_code != 200:
        raise RuntimeError(f"Token request failed: {r.status_code} {r.text}")
    return r.json()["access_token"]


def paged_get(access_token: str, url: str) -> List[Dict[str, Any]]:
    headers = {"Authorization": f"Bearer {access_token}", "Accept": "application/json"}
    items: List[Dict[str, Any]] = []
    while url:
        r = requests.get(url, headers=headers, timeout=30)
        r.raise_for_status()
        j = r.json()
        if isinstance(j, dict) and "value" in j:
            items.extend(j.get("value", []))
            url = j.get("@odata.nextLink")
        else:
            break
    return items


def build_path(item: Dict[str, Any]) -> str:
    parent = item.get("parentReference", {}).get("path")
    if parent:
        trim = parent.replace("/drive/root:", "")
        if trim == "":
            return "/" + item.get("name", "")
        return trim.rstrip("/") + "/" + item.get("name", "")
    return item.get("name", "")


def list_all_items(access_token: str, drive_id: str, page_size: int = 200) -> (List[Dict[str, Any]], List[Dict[str, Any]]):
    api_base = "https://graph.microsoft.com/v1.0"
    # initial children of root
    url = f"{api_base}/drives/{drive_id}/root/children?$top={page_size}&$select=id,name,folder,file,parentReference,size,createdDateTime,lastModifiedDateTime"
    all_items = paged_get(access_token, url)
    folders = [it for it in all_items if it.get("folder")]
    files = [it for it in all_items if not it.get("folder")]

    idx = 0
    while idx < len(folders):
        f = folders[idx]
        children_url = f"{api_base}/drives/{drive_id}/items/{f['id']}/children?$top={page_size}&$select=id,name,folder,file,parentReference,size,createdDateTime,lastModifiedDateTime"
        children = paged_get(access_token, children_url)
        for c in children:
            if c.get("folder"):
                folders.append(c)
            else:
                files.append(c)
        idx += 1

    return folders, files


def fetch_file_detail(access_token: str, drive_id: str, item: Dict[str, Any]) -> Dict[str, Any]:
    api_base = "https://graph.microsoft.com/v1.0"
    base = {
        "id": item.get("id"),
        "name": item.get("name"),
        "path": build_path(item),
        "size": item.get("size", 0),
        "isFolder": False,
        "quickXorHash": None,
        "sensitivityLabelId": None,
        "sensitivityLabelName": None,
        "createdDateTime": item.get("createdDateTime"),
        "lastModifiedDateTime": item.get("lastModifiedDateTime"),
    }
    # try to get file.hashes from listing
    ff = item.get("file")
    if ff and isinstance(ff, dict):
        hashes = ff.get("hashes")
        if hashes and hashes.get("quickXorHash"):
            base["quickXorHash"] = hashes.get("quickXorHash")

    if base["quickXorHash"] is None:
        # perform per-item GET
        url = f"{api_base}/drives/{drive_id}/items/{item['id']}?$select=file,sensitivityLabel"
        headers = {"Authorization": f"Bearer {access_token}", "Accept": "application/json"}
        r = requests.get(url, headers=headers, timeout=30)
        if r.status_code == 200:
            j = r.json()
            ffacet = j.get("file")
            if ffacet and isinstance(ffacet, dict):
                hashes = ffacet.get("hashes")
                if hashes and hashes.get("quickXorHash"):
                    base["quickXorHash"] = hashes.get("quickXorHash")
            sl = j.get("sensitivityLabel")
            if sl and isinstance(sl, dict):
                base["sensitivityLabelId"] = sl.get("id")
                base["sensitivityLabelName"] = sl.get("name") or sl.get("displayName")

    return base


def save_json(items: List[Dict[str, Any]], path: str):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(items, f, indent=2, default=str, ensure_ascii=False)


def parse_args():
    p = argparse.ArgumentParser(description="Simple Graph Drive Scanner (sync)")
    p.add_argument("--tenant-id", required=False)
    p.add_argument("--client-id", required=False)
    p.add_argument("--client-secret", required=False)
    p.add_argument("--drive-id", required=False)
    p.add_argument("--page-size", type=int, default=200)
    p.add_argument("--concurrency", type=int, default=8)
    p.add_argument("--hold-start-seconds", type=int, default=0, help="Seconds to wait before starting network calls (diagnostic)")
    p.add_argument("--ignore-sigint-seconds", type=int, default=0, help="Temporarily ignore SIGINT for N seconds at startup (diagnostic)")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--dry-run-file", default=os.path.join(os.path.dirname(__file__), "dryrun_mock.json"))
    p.add_argument("--output", default=os.path.join(os.path.dirname(__file__), "output", "drive_analysis_simple.json"))
    p.add_argument("--export-csv", action="store_true")
    p.add_argument("--verbose", action="store_true")
    return p.parse_args()


def main():
    args = parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)

    # Optional hold before network calls (diagnostic)
    if getattr(args, 'hold_start_seconds', 0) and args.hold_start_seconds > 0:
        h = int(args.hold_start_seconds)
        LOG.info(f"Holding start for {h}s (diagnostic) PID={os.getpid()}")
        _append_diag_simple(f"Hold start for {h}s requested by CLI")
        time.sleep(h)

    # Optionally ignore SIGINT for a short period
    if getattr(args, 'ignore_sigint_seconds', 0) and args.ignore_sigint_seconds > 0:
        try:
            n = int(args.ignore_sigint_seconds)
            LOG.info(f"Temporarily ignoring SIGINT for {n}s (simple diagnostic)")
            _append_diag_simple(f"Temporarily ignoring SIGINT for {n}s")
            prev = None
            try:
                prev = signal.getsignal(signal.SIGINT)
                signal.signal(signal.SIGINT, signal.SIG_IGN)
            except Exception:
                prev = None
            time.sleep(n)
            try:
                if prev is not None:
                    signal.signal(signal.SIGINT, prev)
                _append_diag_simple("SIGINT handler restored after ignore period")
                LOG.info("SIGINT handler restored after ignore period")
            except Exception:
                LOG.debug("Could not restore SIGINT handler")
        except Exception as ex:
            LOG.debug(f"ignore-sigint handling failed: {ex}")

    if args.dry_run:
        LOG.info("Dry-run mode: loading mock file")
        if not os.path.exists(args.dry_run_file):
            raise RuntimeError(f"Dry-run file not found: {args.dry_run_file}")
        with open(args.dry_run_file, "r", encoding="utf-8") as f:
            data = json.load(f)
        # convert mock to details
        details = []
        for it in data:
            d = {
                "id": it.get("id"),
                "name": it.get("name"),
                "path": build_path(it),
                "size": it.get("size", 0),
                "isFolder": bool(it.get("folder")),
                "quickXorHash": None,
                "sensitivityLabelId": None,
                "sensitivityLabelName": None,
                "createdDateTime": it.get("createdDateTime"),
                "lastModifiedDateTime": it.get("lastModifiedDateTime"),
            }
            ff = it.get("file")
            if ff and isinstance(ff, dict):
                hashes = ff.get("hashes")
                if hashes:
                    d["quickXorHash"] = hashes.get("quickXorHash")
            details.append(d)

        save_json(details, args.output)
        LOG.info(f"Dry-run exported to {args.output}")
        if args.export_csv:
            csv_path = os.path.splitext(args.output)[0] + ".csv"
            import csv
            keys = list(details[0].keys()) if details else []
            with open(csv_path, "w", encoding="utf-8", newline="") as cf:
                w = csv.DictWriter(cf, fieldnames=keys, extrasaction="ignore")
                w.writeheader()
                for r in details:
                    w.writerow(r)
            LOG.info(f"CSV exported: {csv_path}")
        return

    # production mode
    tenant_id = args.tenant_id or os.environ.get("TENANT_ID") or os.environ.get("GRAPH_TENANT_ID")
    client_id = args.client_id or os.environ.get("CLIENT_ID") or os.environ.get("GRAPH_CLIENT_ID")
    client_secret = args.client_secret or os.environ.get("CLIENT_SECRET") or os.environ.get("GRAPH_CLIENT_SECRET")
    drive_id = args.drive_id or os.environ.get("DRIVE_ID") or os.environ.get("GRAPH_DRIVE_ID")

    if not tenant_id or not client_id or not client_secret or not drive_id:
        raise RuntimeError("Missing required credentials/drive id. Provide --tenant-id, --client-id, --client-secret and --drive-id or set env vars.")

    token = acquire_token(tenant_id, client_id, client_secret)
    LOG.info("Acquired access token")

    LOG.info("Collecting items...")
    folders, files = list_all_items(token, drive_id, page_size=args.page_size)
    LOG.info(f"Found {len(folders)} folders and {len(files)} files")

    # fetch details in parallel
    details = []
    with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
        futures = {ex.submit(fetch_file_detail, token, drive_id, it): it for it in files}
        for fut in tqdm(as_completed(futures), total=len(futures)):
            try:
                r = fut.result()
                details.append(r)
            except Exception as ex:
                LOG.warning(f"Per-item fetch failed: {ex}")

    save_json(details, args.output)
    LOG.info(f"Exported results to {args.output}")
    if args.export_csv:
        csv_path = os.path.splitext(args.output)[0] + ".csv"
        import csv
        keys = ["id", "name", "path", "size", "quickXorHash", "sensitivityLabelId", "sensitivityLabelName", "createdDateTime", "lastModifiedDateTime"]
        with open(csv_path, "w", encoding="utf-8", newline="") as cf:
            w = csv.DictWriter(cf, fieldnames=keys, extrasaction="ignore")
            w.writeheader()
            for r in details:
                w.writerow(r)
        LOG.info(f"CSV exported: {csv_path}")


if __name__ == "__main__":
    main()
