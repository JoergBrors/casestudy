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
    # Simple fallback progress if tqdm not installed
    def tqdm(iterable=None, **kwargs):
        return iterable

LOG = logging.getLogger("graph_drive_scanner")


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

    # iterate folder queue
    idx = 0
    while idx < len(folders):
        folder = folders[idx]
        children = await list_item_children(client, drive_id, folder["id"], page_size, include_file=include_file)
        for c in children:
            if c.get("folder") is not None:
                folders.append(c)
            else:
                files.append(c)
        idx += 1

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


def save_json(items: List[Dict[str, Any]], path: str):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(items, f, indent=2, default=str, ensure_ascii=False)


async def main_async(args):
    logging.basicConfig(level=logging.INFO if not args.verbose else logging.DEBUG)
    # Dry-run mode: generate mock items and export without calling Graph
    if args.dry_run:
        LOG.info("DryRun mode: loading mock items locally (no network calls)")
        # Determine mock source: CLI arg -> env var -> default file
        mock_file = args.dry_run_file or os.environ.get('DRYRUN_MOCK_FILE') or os.path.join(os.path.dirname(__file__), 'dryrun_mock.json')
        if not os.path.exists(mock_file):
            raise RuntimeError(f"Dry-run mock file not found: {mock_file}")
        with open(mock_file, 'r', encoding='utf-8') as mf:
            mock = json.load(mf)

        # build details directly from loaded mock
        details = []
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
            # Request the file facet in listings to reduce per-item GETs
            folders, files = await collect_folders_and_files(client, args.drive_id, args.page_size, include_file=True)
            LOG.info(f"Collected {len(folders)} folders and {len(files)} files (initial scan)")

            # Now fetch file details in parallel; if --no-per-item-get is set we will not perform per-item GETs
            details = await gather_file_details(client, args.drive_id, files, args.site_id, args.concurrency, args.request_delay_ms, show_progress=not args.no_progress, no_per_item_get=args.no_per_item_get)

        # Export
        outdir = args.output_dir or "./output"
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
    p.add_argument("--concurrency", type=int, default=8, help="Number of concurrent file detail requests")
    p.add_argument("--request-delay-ms", type=int, default=0, help="Max random delay per request (ms)")
    p.add_argument("--output-dir", default="./SharepointAnalysis/output")
    p.add_argument("--progress-interval", type=int, default=10, help="Seconds between textual progress logs (0 disables)")
    p.add_argument("--fail-on-throttle", action="store_true", help="Do not retry on 429/5xx; fail immediately (useful when another sync is causing transient errors)")
    p.add_argument("--export-json", dest="export_json", action="store_true")
    p.add_argument("--export-csv", dest="export_csv", action="store_true")
    p.add_argument("--use-beta", action="store_true")
    p.add_argument("--use-keyvault", action="store_true", help="Retrieve client secret from Azure Key Vault (requires --keyvault-name and --keyvault-secret-name)")
    p.add_argument("--keyvault-name", required=False, help="Azure Key Vault name (no .vault.azure.net suffix)")
    p.add_argument("--keyvault-secret-name", required=False, help="Name of the secret in Key Vault to read the client secret from")
    p.add_argument("--no-per-item-get", action="store_true", help="Do not perform per-item GETs for file.hashes; rely on file facet from the initial listing")
    p.add_argument("--no-progress", action="store_true")
    p.add_argument("--max-retry", type=int, default=6)
    p.add_argument("--verbose", action="store_true")
    return p.parse_args()


def main():
    args = parse_args()
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        LOG.info("Interrupted by user")


if __name__ == "__main__":
    main()
