r"""
Async Microsoft Graph Drive Scanner

Features:
- App-only client_credentials token (TenantId, ClientId, ClientSecret)
- Token caching and automatic refresh
- Async HTTP using aiohttp with bounded concurrency
- Retry/backoff and 429 handling (honors Retry-After)
- Two-step approach: read folder structure first, then fetch file details in parallel
- Sensitivity label extraction via listItem.fields (fallback to sensitivityLabel)
- Progress bar via tqdm
- JSON/CSV export

Usage (PowerShell example):
  pwsh -NoProfile -Command "python .\SharepointAnalysis\graph_drive_scanner.py --tenant-id <tid> --client-id <cid> --client-secret <secret> --site-id <siteid> --drive-id <driveid> --concurrency 8 --output-dir .\SharepointAnalysis\output --export-json"

Requires: Python 3.8+, packages: aiohttp, asyncio, aiofiles (optional), tqdm, python-dateutil
Install deps: pip install aiohttp tqdm python-dateutil
"""
from __future__ import annotations
import asyncio
import aiohttp
import argparse
import time
import json
import logging
import os
import math
from typing import Optional, Dict, Any, List, Tuple
from datetime import datetime, timedelta, timezone
import asyncio
import sys
import signal
import traceback
import getpass
# Optional Azure Key Vault support
try:
    from azure.identity import DefaultAzureCredential  # type: ignore
    from azure.keyvault.secrets import SecretClient  # type: ignore
    AZURE_KV_AVAILABLE = True
except Exception:
    AZURE_KV_AVAILABLE = False

try:
    from tqdm import tqdm
except Exception:
    # Simple fallback progress if tqdm not installed. Provide a small
    # dummy progress-bar object with the methods used in this script so
    # code can call `.update()`, `.close()`, `.set_description()` etc.
    class _DummyPbar:
        def __init__(self, total=0, desc=None, **kwargs):
            self.total = total or 0
            self.desc = desc
        def update(self, n=1):
            pass
        def set_description(self, desc):
            self.desc = desc
        def refresh(self):
            pass
        def close(self):
            pass

    def tqdm(*args, **kwargs):
        # Support both `tqdm(iterable)` and `tqdm(total=..., desc=...)` calls.
        # If an iterable is provided as the first positional arg, return it
        # (we don't iterate through it here); otherwise return a dummy pbar.
        if args and not kwargs:
            return args[0]
        # When called with keyword args or a numeric total, return dummy pbar
        total = kwargs.get('total') or (args[0] if args else 0)
        desc = kwargs.get('desc')
        return _DummyPbar(total=total, desc=desc)

LOG = logging.getLogger("graph_drive_scanner")

# Diagnostic startup log to capture PID, argv and signals when a process
# is terminated externally (Stop-Process, taskkill, etc.). This file is
# intentionally separate from the normal logger so it is written even
# when the process is killed abruptly.
DIAG_LOG_PATH = os.path.join(os.path.dirname(__file__), 'diagnostic_startup.log')


def _append_diag(msg: str):
    try:
        with open(DIAG_LOG_PATH, 'a', encoding='utf-8') as df:
            df.write(f"{datetime.utcnow().isoformat()}Z {msg}\n")
    except Exception:
        # best-effort; do not crash if diagnostics cannot be written
        try:
            LOG.debug("Failed to write diagnostic log")
        except Exception:
            pass


def install_startup_diagnostics():
    try:
        _append_diag("--- startup diagnostics ---")
        _append_diag(f"PID={os.getpid()} PPID={getattr(os, 'getppid', lambda: None)()} PY={sys.executable}")
        _append_diag(f"CWD={os.getcwd()} ARGV={' '.join(sys.argv)} USER={getpass.getuser()}")
        # note presence of selected env vars (mask values)
        keys = ['GRAPH_TENANT_ID', 'TENANT_ID', 'GRAPH_CLIENT_ID', 'CLIENT_ID', 'GRAPH_CLIENT_SECRET', 'CLIENT_SECRET', 'SITE_ID', 'DRIVE_ID']
        for k in keys:
            v = os.environ.get(k)
            if v is None:
                _append_diag(f"ENV {k}=<missing>")
            else:
                _append_diag(f"ENV {k}=<present len={len(v)}>" )

        def _exc_hook(exc_type, exc, tb):
            try:
                _append_diag("UNCAUGHT EXCEPTION:")
                _append_diag(''.join(traceback.format_exception(exc_type, exc, tb)))
            except Exception:
                pass
            # also call the default hook
            try:
                sys.__excepthook__(exc_type, exc, tb)
            except Exception:
                pass

        sys.excepthook = _exc_hook

        def _sig_handler(sig, frame):
            try:
                _append_diag(f"RECEIVED SIGNAL: {sig}")
                # append a small stack sample
                try:
                    _append_diag(''.join(traceback.format_stack(frame)))
                except Exception:
                    pass
            finally:
                try:
                    # flush standard logging handlers
                    for h in logging.root.handlers:
                        try:
                            h.flush()
                        except Exception:
                            pass
                except Exception:
                    pass
                # best-effort immediate exit with no cleanup that might be interrupted
                try:
                    os._exit(1)
                except Exception:
                    pass

        for s in ('SIGINT', 'SIGTERM'):
            try:
                sigobj = getattr(signal, s)
                signal.signal(sigobj, _sig_handler)
            except Exception:
                # signal may not be available on all platforms
                pass

    except Exception:
        try:
            LOG.debug("Failed to install startup diagnostics")
        except Exception:
            pass


# Install diagnostics early so we capture signals even if the run is short
install_startup_diagnostics()

# Asyncio-based live monitor queue. We create an asyncio.Queue that
# worker coroutines put small update events into. The live display runs
# as an async task in the main event loop (foreground) and renders a
# concise status line when events arrive or periodically.
LIVE_QUEUE: Optional[asyncio.Queue] = None


def set_live_queue(q: Optional[asyncio.Queue]):
    global LIVE_QUEUE
    LIVE_QUEUE = q


def monitor_set_initial(folders: int, files: int):
    q = LIVE_QUEUE
    if q is None:
        return
    try:
        q.put_nowait({"type": "set_initial", "folders": int(folders), "files": int(files)})
    except Exception:
        pass


def monitor_add_folders(n: int = 1):
    q = LIVE_QUEUE
    if q is None:
        return
    try:
        q.put_nowait({"type": "add_folders", "n": int(n)})
    except Exception:
        pass


def monitor_add_files(n: int = 1):
    q = LIVE_QUEUE
    if q is None:
        return
    try:
        q.put_nowait({"type": "add_files", "n": int(n)})
    except Exception:
        pass


def monitor_add_details(n: int = 1):
    q = LIVE_QUEUE
    if q is None:
        return
    try:
        q.put_nowait({"type": "add_details", "n": int(n)})
    except Exception:
        pass


async def live_display_loop(queue: asyncio.Queue, interval: float = 1.0):
    """Runs in the main event loop; consumes events from `queue` and
    updates a single-line status display. Terminates when it receives a
    `{'type':'stop'}` event.
    """
    folders = 0
    files = 0
    details = 0
    last_print = 0.0
    try:
        # Use a small tqdm bar if available; otherwise fallback to carriage-return printing
        try:
            pbar = tqdm(total=0, desc="Live status", position=2)
        except Exception:
            pbar = None

        while True:
            try:
                ev = await asyncio.wait_for(queue.get(), timeout=interval)
            except asyncio.TimeoutError:
                ev = None

            if ev:
                et = ev.get("type")
                if et == "stop":
                    break
                if et == "set_initial":
                    folders = int(ev.get("folders", folders))
                    files = int(ev.get("files", files))
                elif et == "add_folders":
                    folders += int(ev.get("n", 1))
                elif et == "add_files":
                    files += int(ev.get("n", 1))
                elif et == "add_details":
                    details += int(ev.get("n", 1))
            # Immediate render on event (responsive) and periodic render
            def _render():
                desc = f"Folders: {folders} | Files: {files} | Details: {details}"
                try:
                    if pbar:
                        pbar.set_description(desc)
                        pbar.refresh()
                    else:
                        # print a newline so it's visible even if carriage-return
                        print(desc, flush=True)
                except Exception:
                    try:
                        print(desc, flush=True)
                    except Exception:
                        LOG.debug(desc)

            # If we processed an event, render immediately
            if ev is not None:
                _render()
                last_print = asyncio.get_event_loop().time()
            else:
                # Periodic render if no events
                now = asyncio.get_event_loop().time()
                if now - last_print >= interval:
                    _render()
                    last_print = now

        # final render before exit
        final = f"Done. Folders: {folders} | Files: {files} | Details: {details}"
        try:
            if pbar:
                pbar.set_description(final)
                pbar.close()
                print("", flush=True)
            else:
                print(final)
        except Exception:
            LOG.info(final)
    except Exception as ex:
        LOG.exception("Live display loop failed: %s", ex)



class GraphClient:
    def __init__(self, tenant_id: str, client_id: str, client_secret: str, session: aiohttp.ClientSession, use_beta: bool = False, max_retries: int = 6, fail_on_throttle: bool = False):
        self.tenant_id = tenant_id
        self.client_id = client_id
        self.client_secret = client_secret
        self.session = session
        self.use_beta = use_beta
        self.token: Optional[str] = None
        self.token_expiry: datetime = datetime.fromtimestamp(0, timezone.utc)
        self.lock = asyncio.Lock()
        self.max_retries = max_retries
        self.fail_on_throttle = fail_on_throttle

    async def _acquire_token(self) -> Tuple[str, int]:
        url = f"https://login.microsoftonline.com/{self.tenant_id}/oauth2/v2.0/token"
        data = {
            "client_id": self.client_id,
            "scope": "https://graph.microsoft.com/.default",
            "client_secret": self.client_secret,
            "grant_type": "client_credentials",
        }
        async with self.session.post(url, data=data) as r:
            if r.status != 200:
                text = await r.text()
                raise RuntimeError(f"Token request failed: {r.status} {text}")
            resp = await r.json()
            return resp["access_token"], int(resp.get("expires_in", 3600))

    async def ensure_token(self):
        async with self.lock:
            # Refresh if token missing or expires within 60 seconds
            if self.token is None or datetime.now(timezone.utc) + timedelta(seconds=60) >= self.token_expiry:
                LOG.debug("Refreshing access token")
                token, expires_in = await self._acquire_token()
                self.token = token
                self.token_expiry = datetime.now(timezone.utc) + timedelta(seconds=expires_in)

    def api_base(self) -> str:
        return "https://graph.microsoft.com/beta" if self.use_beta else "https://graph.microsoft.com/v1.0"

    async def request(self, method: str, url: str, **kwargs) -> Any:
        # High-level request with retry/backoff and token refresh on 401
        attempt = 0
        backoff_base = 1.5
        while True:
            await self.ensure_token()
            headers = kwargs.pop("headers", {}) or {}
            headers.setdefault("Authorization", f"Bearer {self.token}")
            headers.setdefault("Accept", "application/json")
            try:
                async with self.session.request(method, url, headers=headers, **kwargs) as resp:
                    if resp.status == 401 and attempt < self.max_retries:
                        LOG.info("401 received, forcing token refresh and retry")
                        # force refresh next time
                        async with self.lock:
                            self.token = None
                            self.token_expiry = datetime.utcfromtimestamp(0)
                        attempt += 1
                        continue

                    if resp.status == 429 or 500 <= resp.status < 600:
                        # Optionally fail fast instead of retrying when throttled
                        if getattr(self, "fail_on_throttle", False):
                            text = await resp.text()
                            raise RuntimeError(f"Request failed {resp.status} and fail_on_throttle=True: {text}")
                        if attempt >= self.max_retries:
                            text = await resp.text()
                            raise RuntimeError(f"Request failed {resp.status}: {text}")
                        # honor Retry-After if present
                        retry_after = None
                        try:
                            ra = resp.headers.get("Retry-After")
                            if ra:
                                retry_after = float(ra)
                        except Exception:
                            retry_after = None
                        if retry_after is None:
                            retry_after = math.pow(backoff_base, attempt + 1)
                        LOG.warning(f"Request {url} returned {resp.status}. Sleeping {retry_after}s and retrying (attempt {attempt+1})")
                        await asyncio.sleep(retry_after)
                        attempt += 1
                        continue

                    if resp.status >= 400:
                        text = await resp.text()
                        raise RuntimeError(f"Request failed {resp.status}: {text}")

                    # success
                    # try json, fallback to text
                    try:
                        return await resp.json()
                    except aiohttp.ContentTypeError:
                        return await resp.text()
            except aiohttp.ClientError as ex:
                if attempt >= self.max_retries:
                    raise
                wait = math.pow(backoff_base, attempt + 1)
                LOG.warning(f"HTTP error {ex}, sleeping {wait}s and retrying")
                await asyncio.sleep(wait)
                attempt += 1


async def paged_get(client: GraphClient, url: str) -> List[Dict[str, Any]]:
    results: List[Dict[str, Any]] = []
    next_url = url
    while next_url:
        resp = await client.request("GET", next_url)
        if isinstance(resp, dict) and "value" in resp:
            results.extend(resp.get("value", []))
            next_url = resp.get("@odata.nextLink")
        else:
            break
    return results


async def list_drive_children(client: GraphClient, drive_id: str, page_size: int = 200, include_file: bool = True) -> List[Dict[str, Any]]:
    # include_file controls whether the 'file' facet is selected in the listing
    base_select = "id,name,size,createdDateTime,lastModifiedDateTime,createdBy,lastModifiedBy,parentReference,folder"
    if include_file:
        select = base_select + ",file"
    else:
        select = base_select
    base = f"{client.api_base()}/drives/{drive_id}/root/children?$select={select}&$top={page_size}"
    return await paged_get(client, base)


async def list_item_children(client: GraphClient, drive_id: str, item_id: str, page_size: int = 200, include_file: bool = True) -> List[Dict[str, Any]]:
    base_select = "id,name,size,createdDateTime,lastModifiedDateTime,createdBy,lastModifiedBy,parentReference,folder"
    if include_file:
        select = base_select + ",file"
    else:
        select = base_select
    base = f"{client.api_base()}/drives/{drive_id}/items/{item_id}/children?$select={select}&$top={page_size}"
    return await paged_get(client, base)


def build_path(item: Dict[str, Any]) -> str:
    parent = item.get("parentReference", {}).get("path")
    if parent:
        trim = parent.replace("/drive/root:", "")
        if trim == "":
            return "/" + item.get("name", "")
        return trim.rstrip("/") + "/" + item.get("name", "")
    return item.get("name", "")


async def collect_folders_and_files(client: GraphClient, drive_id: str, page_size: int = 200, include_file: bool = True) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    """Collects items recursively but returns two lists: folders and files (minimal metadata)."""
    folders: List[Dict[str, Any]] = []
    files: List[Dict[str, Any]] = []
    # BFS queue
    queue = await list_drive_children(client, drive_id, page_size, include_file=include_file)
    for item in queue:
        if item.get("folder") is not None:
            folders.append(item)
        else:
            files.append(item)

    # iterate folder queue with progress bars
    total_folders = len(folders)
    total_files = len(files)
    
    try:
        # Create progress bars with different colors and counts
        folder_pbar = tqdm(total=total_folders, desc=f"Folders ({total_folders})", 
                          colour="blue", position=0, leave=True)
        file_pbar = tqdm(total=total_files, desc=f"Files ({total_files})", 
                        colour="green", position=1, leave=True)
    except:
        # Fallback if tqdm doesn't support color
        folder_pbar = tqdm(total=total_folders, desc=f"Folders ({total_folders})", position=0)
        file_pbar = tqdm(total=total_files, desc=f"Files ({total_files})", position=1)
    # Mark initially-discovered files as already counted on the file progress bar
    try:
        if total_files:
            file_pbar.update(total_files)
    except Exception:
        pass

    # Tell the live monitor the initial counts so the background thread can
    # show live totals while discovery continues
    try:
        monitor_set_initial(total_folders, total_files)
    except Exception:
        pass
    
    idx = 0
    while idx < len(folders):
        folder = folders[idx]
        children = await list_item_children(client, drive_id, folder["id"], page_size, include_file=include_file)
        new_folders = 0
        new_files = 0
        for c in children:
            if c.get("folder") is not None:
                folders.append(c)
                new_folders += 1
            else:
                files.append(c)
                new_files += 1
        
        # Update progress bars and totals
        if new_folders > 0:
            folder_pbar.total = len(folders)
            folder_pbar.set_description(f"Folders ({len(folders)})")
            folder_pbar.refresh()
            # update monitor with new folders
            try:
                monitor_add_folders(new_folders)
            except Exception:
                pass
        
        if new_files > 0:
            file_pbar.total = len(files)
            file_pbar.set_description(f"Files ({len(files)})")
            file_pbar.update(new_files)
            # update monitor with new files
            try:
                monitor_add_files(new_files)
            except Exception:
                pass
        
        folder_pbar.update(1)
        idx += 1
    
    # Close progress bars
    folder_pbar.close()
    file_pbar.close()

    return folders, files


async def fetch_file_detail(client: GraphClient, drive_id: str, item: Dict[str, Any], site_id: Optional[str], semaphore: asyncio.Semaphore, delay_ms: int = 0, no_per_item_get: bool = False) -> Dict[str, Any]:
    """Fetch per-file details: file.hashes.quickXorHash and sensitivity label (via listItem.fields)."""
    async with semaphore:
        if delay_ms > 0:
            await asyncio.sleep(delay_ms / 1000.0 * (0.5 + 0.5 * (os.getpid() % 5)))
        result = {
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

        # Try to use existing file.hashes from listing
        file_facet = item.get("file")
        if file_facet and isinstance(file_facet, dict):
            hashes = file_facet.get("hashes")
            if hashes and hashes.get("quickXorHash"):
                result["quickXorHash"] = hashes.get("quickXorHash")

        # If missing, request item with file select (unless disabled)
        if not result["quickXorHash"] and not no_per_item_get:
            try:
                url = f"{client.api_base()}/drives/{drive_id}/items/{item['id']}?$select=file"
                resp = await client.request("GET", url)
                if resp and isinstance(resp, dict):
                    ff = resp.get("file")
                    if ff:
                        hashes = ff.get("hashes")
                        if hashes and hashes.get("quickXorHash"):
                            result["quickXorHash"] = hashes.get("quickXorHash")
            except Exception as ex:
                LOG.debug(f"Could not fetch file.hashes for {item['id']}: {ex}")

        # Sensitivity label: try listItem?expand=fields (drives-based), then fallback to drive item sensitivityLabel
        if site_id:
            list_urls = [f"{client.api_base()}/drives/{drive_id}/items/{item['id']}/listItem?$expand=fields",
                         f"{client.api_base()}/sites/{site_id}/drives/{drive_id}/items/{item['id']}/listItem?$expand=fields"]
        else:
            list_urls = [f"{client.api_base()}/drives/{drive_id}/items/{item['id']}/listItem?$expand=fields"]

        label_found = False
        for lu in list_urls:
            try:
                resp = await client.request("GET", lu)
                fields = resp.get("fields") if isinstance(resp, dict) else None
                if fields:
                    # search likely property names
                    for k, v in fields.items():
                        if not v:
                            continue
                        if k.lower().endswith("id") and ("compliance" in k.lower() or "label" in k.lower()):
                            result["sensitivityLabelId"] = v
                        if ("label" in k.lower() or "compliance" in k.lower() or k.lower().endswith("displayname") or k.lower().endswith("display_name")):
                            if not result.get("sensitivityLabelName"):
                                result["sensitivityLabelName"] = v
                    if result.get("sensitivityLabelId") or result.get("sensitivityLabelName"):
                        label_found = True
                        break
            except Exception:
                continue

        if not label_found:
            try:
                url = f"{client.api_base()}/drives/{drive_id}/items/{item['id']}?$select=sensitivityLabel"
                resp = await client.request("GET", url)
                if resp and isinstance(resp, dict) and resp.get("sensitivityLabel"):
                    sl = resp.get("sensitivityLabel")
                    result["sensitivityLabelId"] = sl.get("id")
                    result["sensitivityLabelName"] = sl.get("name") or sl.get("displayName") or sl.get("label")
            except Exception:
                pass

        return result



async def gather_file_details(client: GraphClient, drive_id: str, files: List[Dict[str, Any]], site_id: Optional[str], concurrency: int, delay_ms: int, show_progress: bool, no_per_item_get: bool = False) -> List[Dict[str, Any]]:
    sem = asyncio.Semaphore(concurrency)
    tasks = []
    results: List[Dict[str, Any]] = []

    it = files
    total = len(it)
    if show_progress:
        pbar = tqdm(total=total, desc="Files")
    else:
        pbar = None

    # periodic textual progress reporter (useful in non-TTY logs)
    progress_interval = getattr(client, "progress_interval", 10)
    if progress_interval is None:
        progress_interval = 0

    completed = 0
    progress_done = asyncio.Event()

    async def progress_reporter():
        start = time.time()
        while not progress_done.is_set():
            await asyncio.sleep(progress_interval)
            now = time.time()
            elapsed = now - start
            rate = (completed / elapsed) if elapsed > 0 else 0.0
            remaining = max(0, total - completed)
            eta = int(remaining / rate) if rate > 0 else None
            if eta is not None:
                LOG.info(f"Processed {completed}/{total} files; rate {rate:.2f}/s; ETA {eta}s")
            else:
                LOG.info(f"Processed {completed}/{total} files; rate {rate:.2f}/s")

    async def _wrap(item):
        nonlocal completed
        try:
            r = await fetch_file_detail(client, drive_id, item, site_id, sem, delay_ms, no_per_item_get=no_per_item_get)
            results.append(r)
        finally:
            # update monitor for each processed detail
            try:
                monitor_add_details(1)
            except Exception:
                pass
            completed += 1
            if pbar:
                pbar.update(1)

    reporter_task = None
    if progress_interval and progress_interval > 0:
        reporter_task = asyncio.create_task(progress_reporter())

    for item in it:
        tasks.append(asyncio.create_task(_wrap(item)))

    # wait with concurrency controls
    await asyncio.gather(*tasks)

    # finish reporter
    progress_done.set()
    if reporter_task:
        try:
            await reporter_task
        except Exception:
            pass

    if pbar:
        pbar.close()
    return results


async def batch_gather_file_details(client: GraphClient, drive_id: str, files: List[Dict[str, Any]], site_id: Optional[str], batch_size: int, concurrency: int, delay_ms: int, show_progress: bool) -> List[Dict[str, Any]]:
    """Use Graph $batch endpoint to fetch per-item details in batches.
    This sends one GET per item requesting `file` and `sensitivityLabel`.
    Batch size should be <= 20 (Graph limit for requests per batch).
    """
    sem = asyncio.Semaphore(concurrency)
    results: List[Dict[str, Any]] = []
    total = len(files)
    if show_progress:
        pbar = tqdm(total=total, desc="Files(batch)")
    else:
        pbar = None

    # chunk items into batches of batch_size
    batches = [files[i:i+batch_size] for i in range(0, total, batch_size)]

    async def _process_batch(batch_items: List[Dict[str, Any]]):
        async with sem:
            if delay_ms > 0:
                await asyncio.sleep(delay_ms / 1000.0)
            # build batch body
            reqs = []
            for idx, it in enumerate(batch_items):
                # request item selecting file and sensitivityLabel
                url = f"/drives/{drive_id}/items/{it['id']}?$select=file,sensitivityLabel"
                reqs.append({"id": it['id'], "method": "GET", "url": url})

            body = {"requests": reqs}
            try:
                resp = await client.request("POST", f"{client.api_base()}/$batch", json=body)
            except Exception as ex:
                LOG.warning(f"Batch request failed: {ex}")
                # on failure, fallback to per-item fetch
                for it in batch_items:
                    try:
                        r = await fetch_file_detail(client, drive_id, it, site_id, asyncio.Semaphore(1), delay_ms, no_per_item_get=False)
                        results.append(r)
                    except Exception as ex2:
                        LOG.debug(f"Fallback per-item failed for {it.get('id')}: {ex2}")
                    finally:
                        if pbar:
                            pbar.update(1)
                        try:
                            monitor_add_details(1)
                        except Exception:
                            pass
                return

            # process batch responses
            responses = resp.get("responses", []) if isinstance(resp, dict) else []
            # map responses by id
            resp_map = {r.get("id"): r for r in responses}
            for it in batch_items:
                rid = it['id']
                entry = {
                    "id": it.get("id"),
                    "name": it.get("name"),
                    "path": build_path(it),
                    "size": it.get("size", 0),
                    "isFolder": False,
                    "quickXorHash": None,
                    "sensitivityLabelId": None,
                    "sensitivityLabelName": None,
                    "createdDateTime": it.get("createdDateTime"),
                    "lastModifiedDateTime": it.get("lastModifiedDateTime"),
                }
                r = resp_map.get(rid)
                if not r:
                    LOG.debug(f"No batch response for {rid}")
                    results.append(entry)
                    if pbar:
                        pbar.update(1)
                    continue

                status = r.get("status")
                if status and 200 <= int(status) < 300:
                    body = r.get("body") or {}
                    ff = body.get("file") if isinstance(body, dict) else None
                    if ff and isinstance(ff, dict):
                        hashes = ff.get("hashes")
                        if hashes and hashes.get("quickXorHash"):
                            entry["quickXorHash"] = hashes.get("quickXorHash")
                    sl = body.get("sensitivityLabel") if isinstance(body, dict) else None
                    if sl:
                        entry["sensitivityLabelId"] = sl.get("id")
                        entry["sensitivityLabelName"] = sl.get("name") or sl.get("displayName") or sl.get("label")
                else:
                    # non-success: log and leave fields empty
                    LOG.debug(f"Batch item {rid} returned status {status}")

                results.append(entry)
                if pbar:
                    pbar.update(1)
                try:
                    monitor_add_details(1)
                except Exception:
                    pass

    # launch batches with concurrency limit
    tasks = [asyncio.create_task(_process_batch(b)) for b in batches]
    await asyncio.gather(*tasks)
    if pbar:
        pbar.close()
    return results


def save_json(items: List[Dict[str, Any]], path: str):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(items, f, indent=2, default=str, ensure_ascii=False)


async def main_async(args):
    logging.basicConfig(level=logging.INFO if not args.verbose else logging.DEBUG)
    # Optionally ignore SIGINT for a short period to work around external killers
    if getattr(args, 'ignore_sigint_seconds', 0) and args.ignore_sigint_seconds > 0:
        try:
            n = int(args.ignore_sigint_seconds)
            LOG.info(f"Temporarily ignoring SIGINT for {n}s (diagnostic)")
            try:
                _append_diag(f"Temporarily ignoring SIGINT for {n}s")
            except Exception:
                pass
            try:
                prev = signal.getsignal(signal.SIGINT)
                signal.signal(signal.SIGINT, signal.SIG_IGN)
            except Exception:
                prev = None
            import time as _t
            _t.sleep(n)
            try:
                if prev is not None:
                    signal.signal(signal.SIGINT, prev)
                _append_diag("SIGINT handler restored after ignore period")
                LOG.info("SIGINT handler restored after ignore period")
            except Exception:
                LOG.debug("Could not restore SIGINT handler")
        except Exception as ex:
            LOG.debug(f"ignore-sigint handling failed: {ex}")
    # Diagnostic hold before starting network calls so operator can observe PID
    if getattr(args, 'hold_start_seconds', 0) and args.hold_start_seconds > 0:
        hold = int(args.hold_start_seconds)
        LOG.info(f"Holding start for {hold}s to allow diagnostic observation (PID={os.getpid()})")
        try:
            _append_diag(f"Hold start for {hold}s requested by CLI")
        except Exception:
            pass
        # synchronous sleep here on purpose so signal handlers can be observed
        import time as _t
        _t.sleep(hold)
    # Dry-run mode: generate mock items and export without calling Graph
    if args.dry_run:
        LOG.info("DryRun mode: loading mock items locally (no network calls)")
        # Determine mock source: CLI arg -> env var -> default file
        mock_file = args.dry_run_file or os.environ.get('DRYRUN_MOCK_FILE') or os.path.join(os.path.dirname(__file__), 'dryrun_mock.json')
        if not os.path.exists(mock_file):
            raise RuntimeError(f"Dry-run mock file not found: {mock_file}")
        with open(mock_file, 'r', encoding='utf-8') as mf:
            mock = json.load(mf)

        # Optionally start the live monitor for dry-run so we can test it
        monitor_queue = None
        monitor_task = None
        if not args.no_progress and args.progress_interval and args.progress_interval > 0:
            monitor_queue = asyncio.Queue()
            set_live_queue(monitor_queue)
            monitor_task = asyncio.create_task(live_display_loop(monitor_queue, interval=1.0))

        # build details directly from loaded mock
        details = []
        # pre-count folders/files for monitor initial state
        total_folders = sum(1 for it in mock if it.get('folder') is not None)
        total_files = sum(1 for it in mock if it.get('folder') is None)
        monitor_set_initial(total_folders, total_files)
        for it in mock:
            d = {
                "id": it.get("id"),
                "name": it.get("name"),
                "path": build_path(it),
                "size": it.get("size", 0),
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
            # optionally map a sample label if present in mock
            fields = it.get("fields")
            if fields and isinstance(fields, dict):
                # copy some common names
                for k in fields:
                    if k.lower().endswith('displayname') or 'label' in k.lower() or 'compliance' in k.lower():
                        if not d.get('sensitivityLabelName'):
                            d['sensitivityLabelName'] = fields[k]
            details.append(d)
            try:
                monitor_add_details(1)
            except Exception:
                pass

        # stop monitor if running
        try:
            if monitor_task and monitor_queue:
                await monitor_queue.put({"type": "stop"})
                await monitor_task
        except Exception:
            pass
        finally:
            set_live_queue(None)
    else:
        async with aiohttp.ClientSession() as session:
            # Resolve client secret: CLI -> env -> Key Vault
            client_secret = args.client_secret
            if not client_secret:
                client_secret = os.environ.get('GRAPH_CLIENT_SECRET') or os.environ.get('MS_GRAPH_CLIENT_SECRET')

            if args.use_keyvault:
                if not AZURE_KV_AVAILABLE:
                    raise RuntimeError("Azure Key Vault support not available. Install 'azure-identity' and 'azure-keyvault-secrets' packages to use --use-keyvault.")
                if not args.keyvault_name or not args.keyvault_secret_name:
                    raise RuntimeError("When using --use-keyvault you must provide --keyvault-name and --keyvault-secret-name")
                vault_url = f"https://{args.keyvault_name}.vault.azure.net"
                LOG.info(f"Fetching client secret from Key Vault: {vault_url} (secret: {args.keyvault_secret_name})")
                cred = DefaultAzureCredential()
                secret_client = SecretClient(vault_url=vault_url, credential=cred)
                sec = secret_client.get_secret(args.keyvault_secret_name)
                client_secret = sec.value

            if not client_secret:
                raise RuntimeError("Client secret not provided. Pass --client-secret, set GRAPH_CLIENT_SECRET env var, or use --use-keyvault.")

            client = GraphClient(args.tenant_id, args.client_id, client_secret, session, use_beta=args.use_beta, max_retries=args.max_retry, fail_on_throttle=args.fail_on_throttle)
            # attach progress interval from args so gather_file_details can read it
            setattr(client, "progress_interval", args.progress_interval)

            LOG.info("Collecting folder structure and file list (fast scan)")
            # Start a background live monitor showing folders/files/details if
            # progress is enabled. Use a short interval for responsive updates.
            monitor_queue = None
            monitor_task = None
            if not args.no_progress and args.progress_interval and args.progress_interval > 0:
                monitor_queue = asyncio.Queue()
                set_live_queue(monitor_queue)
                monitor_task = asyncio.create_task(live_display_loop(monitor_queue, interval=1.0))
            # Request the file facet in listings to reduce per-item GETs
            folders, files = await collect_folders_and_files(client, args.drive_id, args.page_size, include_file=True)
            LOG.info(f"Collected {len(folders)} folders and {len(files)} files (initial scan)")

            # Now fetch file details
            if args.use_batch:
                details = await batch_gather_file_details(client, args.drive_id, files, args.site_id, args.batch_size, args.concurrency, args.request_delay_ms, show_progress=not args.no_progress)
            else:
                # parallel per-item GETs; if --no-per-item-get is set we will not perform per-item GETs
                details = await gather_file_details(client, args.drive_id, files, args.site_id, args.concurrency, args.request_delay_ms, show_progress=not args.no_progress, no_per_item_get=args.no_per_item_get)
            # Stop live monitor (if any) now that details are complete
            try:
                if monitor_task and monitor_queue:
                    await monitor_queue.put({"type": "stop"})
                    await monitor_task
            except Exception:
                pass
            finally:
                set_live_queue(None)
        # Export or show only progress
        outdir = args.output_dir or "./output"
        if args.only_progress:
            # Show a final progress bar for the number of processed items
            total_final = len(details)
            try:
                final_pbar = tqdm(total=total_final, desc="Finalizing (no files)")
            except Exception:
                final_pbar = None
            for _ in range(total_final):
                if final_pbar:
                    final_pbar.update(1)
                else:
                    # small sleep to make a readable log stream
                    time.sleep(0.01)
            if final_pbar:
                final_pbar.close()
            LOG.info(f"Done: processed {total_final} items (no files written)")
        else:
            os.makedirs(outdir, exist_ok=True)
            if args.export_json:
                json_path = os.path.join(outdir, "drive_analysis.json")
                save_json(details, json_path)
                LOG.info(f"JSON exported: {json_path}")
            if args.export_csv:
                csv_path = os.path.join(outdir, "drive_analysis.csv")
                # write simple CSV
                import csv
                keys = ["id", "name", "path", "size", "quickXorHash", "sensitivityLabelId", "sensitivityLabelName", "createdDateTime", "lastModifiedDateTime"]
                with open(csv_path, "w", encoding="utf-8", newline="") as cf:
                    w = csv.DictWriter(cf, fieldnames=keys, extrasaction="ignore")
                    w.writeheader()
                    for r in details:
                        w.writerow(r)
                LOG.info(f"CSV exported: {csv_path}")


def parse_args():
    p = argparse.ArgumentParser(description="Async Graph Drive Scanner")
    p.add_argument("--tenant-id", required=True)
    p.add_argument("--client-id", required=True)
    p.add_argument("--client-secret", required=False, help="Client secret. If omitted, will try environment variable or Key Vault.")
    p.add_argument("--dry-run", action="store_true", help="Run local dry-run without calling Graph (uses mock data)")
    p.add_argument("--dry-run-file", required=False, help="Path to a JSON file with mock items to use for --dry-run (default: ./SharepointAnalysis/dryrun_mock.json)")
    p.add_argument("--site-id", required=False)
    p.add_argument("--drive-id", required=True)
    p.add_argument("--page-size", type=int, default=200)
    p.add_argument("--hold-start-seconds", type=int, default=0, help="Seconds to wait before starting network calls (useful for diagnostic PID observation)")
    p.add_argument("--ignore-sigint-seconds", type=int, default=0, help="Temporarily ignore SIGINT for N seconds at startup (diagnostic)")
    p.add_argument("--concurrency", type=int, default=8, help="Number of concurrent file detail requests")
    p.add_argument("--request-delay-ms", type=int, default=0, help="Max random delay per request (ms)")
    p.add_argument("--output-dir", default="./SharepointAnalysis/output")
    p.add_argument("--progress-interval", type=int, default=10, help="Seconds between textual progress logs (0 disables)")
    p.add_argument("--use-batch", action="store_true", help="Use Microsoft Graph $batch endpoint to fetch file details in batches")
    p.add_argument("--batch-size", type=int, default=20, help="Number of items per batch request (max 20 requests per batch)")
    p.add_argument("--fail-on-throttle", action="store_true", help="Do not retry on 429/5xx; fail immediately (useful when another sync is causing transient errors)")
    p.add_argument("--export-json", dest="export_json", action="store_true")
    p.add_argument("--export-csv", dest="export_csv", action="store_true")
    p.add_argument("--use-beta", action="store_true")
    p.add_argument("--use-keyvault", action="store_true", help="Retrieve client secret from Azure Key Vault (requires --keyvault-name and --keyvault-secret-name)")
    p.add_argument("--keyvault-name", required=False, help="Azure Key Vault name (no .vault.azure.net suffix)")
    p.add_argument("--keyvault-secret-name", required=False, help="Name of the secret in Key Vault to read the client secret from")
    p.add_argument("--no-per-item-get", action="store_true", help="Do not perform per-item GETs for file.hashes; rely on file facet from the initial listing")
    p.add_argument("--no-progress", action="store_true")
    p.add_argument("--only-progress", action="store_true", help="Do not write JSON/CSV files; only show a final progress bar and summary")
    p.add_argument("--max-retry", type=int, default=6)
    p.add_argument("--verbose", action="store_true")
    return p.parse_args()


def main():
    # Load .env.local and merge env-provided defaults into CLI args so callers
    # that invoke `main()` (or other wrappers) get the same behavior as
    # running the script directly.
    env_path = os.path.join(os.path.dirname(__file__), '.env.local')
    if os.path.exists(env_path):
        try:
            from dotenv import load_dotenv  # type: ignore
            load_dotenv(env_path)
        except Exception:
            try:
                with open(env_path, 'r', encoding='utf-8') as ef:
                    for ln in ef:
                        ln = ln.strip()
                        if not ln or ln.startswith('#'):
                            continue
                        if '=' not in ln:
                            continue
                        k, v = ln.split('=', 1)
                        k = k.strip()
                        v = v.strip().strip('"')
                        if k and v and k not in os.environ:
                            os.environ[k] = v
            except Exception:
                pass

    # Merge selected environment variables into sys.argv as defaults
    import sys
    cli_args = sys.argv[1:]
    env_map = {
        '--tenant-id': 'GRAPH_TENANT_ID',
        '--client-id': 'GRAPH_CLIENT_ID',
        '--client-secret': 'GRAPH_CLIENT_SECRET',
        '--site-id': 'GRAPH_SITE_ID',
        '--drive-id': 'GRAPH_DRIVE_ID',
        '--output-dir': 'GRAPH_OUTPUT_DIR',
    }
    env_args: List[str] = []
    for opt, env_var in env_map.items():
        val = os.environ.get(env_var)
        if val:
            present = False
            for a in cli_args:
                if a == opt or a.startswith(opt + "="):
                    present = True
                    break
            if not present:
                env_args.extend([opt, val])

    sys.argv = [sys.argv[0]] + env_args + cli_args

    args = parse_args()
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        LOG.info("Interrupted by user")


if __name__ == "__main__":
    # Load .env.local from the script directory if present. Prefer python-dotenv when available,
    # otherwise fall back to a simple key=value loader.
    env_path = os.path.join(os.path.dirname(__file__), '.env.local')
    if os.path.exists(env_path):
        try:
            from dotenv import load_dotenv  # type: ignore
            load_dotenv(env_path)
        except Exception:
            try:
                with open(env_path, 'r', encoding='utf-8') as ef:
                    for ln in ef:
                        ln = ln.strip()
                        if not ln or ln.startswith('#'):
                            continue
                        if '=' not in ln:
                            continue
                        k, v = ln.split('=', 1)
                        k = k.strip()
                        v = v.strip().strip('"')
                        if k and v and k not in os.environ:
                            os.environ[k] = v
            except Exception:
                pass

    # Construct default CLI args from environment variables, but allow explicit
    # command-line arguments to override them. We only add an env-provided
    # option if that option/key is not already present on the command line.
    import sys
    cli_args = sys.argv[1:]
    # Map CLI options to one or more environment variable names. Values may be
    # supplied either with a GRAPH_* prefix or with simpler names in `.env.local`.
    env_map = {
        '--tenant-id': ['GRAPH_TENANT_ID', 'TENANT_ID'],
        '--client-id': ['GRAPH_CLIENT_ID', 'CLIENT_ID'],
        '--client-secret': ['GRAPH_CLIENT_SECRET', 'CLIENT_SECRET', 'MS_GRAPH_CLIENT_SECRET'],
        '--site-id': ['GRAPH_SITE_ID', 'SITE_ID'],
        '--drive-id': ['GRAPH_DRIVE_ID', 'DRIVE_ID'],
        '--output-dir': ['GRAPH_OUTPUT_DIR', 'OUTPUT_DIR'],
        '--batch-size': ['GRAPH_BATCH_SIZE', 'BATCH_SIZE'],
        '--concurrency': ['GRAPH_CONCURRENCY', 'CONCURRENCY'],
        '--page-size': ['GRAPH_PAGE_SIZE', 'PAGE_SIZE'],
        '--export-json': ['GRAPH_EXPORT_JSON', 'EXPORT_JSON'],
        '--export-csv': ['GRAPH_EXPORT_CSV', 'EXPORT_CSV'],
        '--use-batch': ['GRAPH_USE_BATCH', 'USE_BATCH'],
        '--use-beta': ['GRAPH_USE_BETA', 'USE_BETA'],
    }

    # Options that are flags (no value expected). If the env var is truthy,
    # we add the option name alone. All other options are key/value pairs.
    flag_options = {'--export-json', '--export-csv', '--use-batch', '--use-beta', '--no-per-item-get', '--no-progress', '--dry-run', '--verbose', '--fail-on-throttle'}

    env_args: List[str] = []
    for opt, env_vars in env_map.items():
        val = None
        # env_vars may be a list of candidate env var names
        for ev in env_vars:
            v = os.environ.get(ev)
            if v is not None and v != "":
                val = v
                break
        if val is None:
            continue

        # check if option already provided on CLI (either as `--opt value` or `--opt=value`)
        present = False
        for a in cli_args:
            if a == opt or a.startswith(opt + "="):
                present = True
                break
        if present:
            continue

        if opt in flag_options:
            if str(val).lower() in ("1", "true", "yes", "on"):
                env_args.append(opt)
        else:
            env_args.extend([opt, val])

    # Place env defaults before CLI args so CLI values win when both are present.
    sys.argv = [sys.argv[0]] + env_args + cli_args

    # Parse args and run
    args = parse_args()
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        LOG.info("Interrupted by user")
