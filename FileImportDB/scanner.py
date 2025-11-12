#!/usr/bin/env python3
"""
FileImportDB scanner

Scans directories, collects file metadata and (optionally) SHA256 hashes
in parallel, and writes results into a SQLite database. Designed for
efficient batch inserts and resumable runs.

Usage examples (see README.md):
  python scanner.py --roots C:\\share C:\\data --db fileindex.db --workers 4 --hash

This script has no external dependencies beyond the Python standard library.
"""

from __future__ import annotations
import argparse
import os
import sys
import sqlite3
import time
import hashlib
from multiprocessing import Pool, cpu_count
from typing import Iterable, Tuple, Optional, Dict, Any, List

# Optional import for SQL Server support
try:
    import pyodbc  # type: ignore
    _HAS_PYODBC = True
except Exception:
    pyodbc = None  # type: ignore
    _HAS_PYODBC = False
import fnmatch


def init_db(conn: sqlite3.Connection) -> None:
    cur = conn.cursor()
    cur.executescript("""
    PRAGMA journal_mode=WAL;
    CREATE TABLE IF NOT EXISTS files (
        path TEXT PRIMARY KEY,
        name TEXT,
        dir TEXT,
        extension TEXT,
        size INTEGER,
        mtime REAL,
        ctime REAL,
        atime REAL,
        is_readonly INTEGER,
        attributes TEXT,
        sha256 TEXT,
        scanned_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_files_dir ON files(dir);
    """)
    conn.commit()


def iter_files(roots: Iterable[str], follow_symlinks: bool=False,
               include: Optional[str]=None, exclude: Optional[str]=None) -> Iterable[str]:
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root, followlinks=follow_symlinks):
            for name in filenames:
                path = os.path.join(dirpath, name)
                if include and not fnmatch.fnmatch(name, include):
                    continue
                if exclude and fnmatch.fnmatch(name, exclude):
                    continue
                yield path


def compute_sha256(path: str, block_size: int = 4 * 1024 * 1024) -> Optional[str]:
    try:
        h = hashlib.sha256()
        with open(path, 'rb') as f:
            while True:
                data = f.read(block_size)
                if not data:
                    break
                h.update(data)
        return h.hexdigest()
    except Exception:
        return None


def process_path(args: Tuple[str, bool]) -> Tuple[str, Dict[str, Any]]:
    path, do_hash = args
    try:
        st = os.stat(path)
        name = os.path.basename(path)
        dirn = os.path.dirname(path)
        ext = os.path.splitext(name)[1].lower()
        size = st.st_size
        mtime = st.st_mtime
        ctime = getattr(st, 'st_ctime', None)
        atime = st.st_atime
        is_readonly = int(not os.access(path, os.W_OK))
        attributes = None
        sha = None
        if do_hash:
            sha = compute_sha256(path)

        return path, {
            'name': name,
            'dir': dirn,
            'extension': ext,
            'size': size,
            'mtime': mtime,
            'ctime': ctime,
            'atime': atime,
            'is_readonly': is_readonly,
            'attributes': attributes,
            'sha256': sha,
            'scanned_at': time.time()
        }
    except Exception:
        return path, {'error': True}


def batched(iterable: Iterable, batch_size: int):
    batch = []
    for item in iterable:
        batch.append(item)
        if len(batch) >= batch_size:
            yield batch
            batch = []
    if batch:
        yield batch


def insert_batch(conn: sqlite3.Connection, rows: List[Tuple[str, Dict[str, Any]]]) -> None:
    cur = conn.cursor()
    now = time.time()
    to_upsert = []
    for path, meta in rows:
        if meta.get('error'):
            continue
        to_upsert.append((
            path,
            meta['name'],
            meta['dir'],
            meta['extension'],
            meta['size'],
            meta['mtime'],
            meta['ctime'],
            meta['atime'],
            meta['is_readonly'],
            meta['attributes'],
            meta['sha256'],
            meta['scanned_at']
        ))

    if not to_upsert:
        return

    cur.execute('BEGIN')
    cur.executemany('''
        INSERT INTO files(path,name,dir,extension,size,mtime,ctime,atime,is_readonly,attributes,sha256,scanned_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(path) DO UPDATE SET
          name=excluded.name,
          dir=excluded.dir,
          extension=excluded.extension,
          size=excluded.size,
          mtime=excluded.mtime,
          ctime=excluded.ctime,
          atime=excluded.atime,
          is_readonly=excluded.is_readonly,
          attributes=excluded.attributes,
          sha256=excluded.sha256,
          scanned_at=excluded.scanned_at;
    ''', to_upsert)
    conn.commit()


def init_mssql(conn: Any) -> None:
    cur = conn.cursor()
    # Create table if not exists (T-SQL pattern)
    cur.execute("""
    IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='files' AND xtype='U')
    BEGIN
        CREATE TABLE dbo.files (
            path NVARCHAR(4000) PRIMARY KEY,
            name NVARCHAR(1024),
            dir NVARCHAR(4000),
            extension NVARCHAR(64),
            size BIGINT,
            mtime FLOAT,
            ctime FLOAT,
            atime FLOAT,
            is_readonly BIT,
            attributes NVARCHAR(4000),
            sha256 NVARCHAR(128),
            scanned_at FLOAT
        );
    END
    """)
    conn.commit()


def insert_batch_mssql(conn: Any, rows: List[Tuple[str, Dict[str, Any]]]) -> None:
    cur = conn.cursor()
    # Try to enable fast_executemany if available (improves executemany perf)
    try:
        cur.fast_executemany = True  # type: ignore
    except Exception:
        pass

    # We'll perform a transactional upsert: try UPDATE, then INSERT if no rows affected
    update_sql = ("""
    UPDATE dbo.files SET
      name = ?, dir = ?, extension = ?, size = ?, mtime = ?, ctime = ?, atime = ?, is_readonly = ?, attributes = ?, sha256 = ?, scanned_at = ?
    WHERE path = ?
    """)
    insert_sql = ("""
    INSERT INTO dbo.files(path,name,dir,extension,size,mtime,ctime,atime,is_readonly,attributes,sha256,scanned_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
    """)

    try:
        for path, meta in rows:
            if meta.get('error'):
                continue
            params_update = (
                meta['name'], meta['dir'], meta['extension'], meta['size'], meta['mtime'], meta['ctime'], meta['atime'],
                meta['is_readonly'], meta['attributes'], meta['sha256'], meta['scanned_at'], path
            )
            cur.execute(update_sql, params_update)
            if cur.rowcount == 0:
                params_insert = (
                    path, meta['name'], meta['dir'], meta['extension'], meta['size'], meta['mtime'], meta['ctime'], meta['atime'],
                    meta['is_readonly'], meta['attributes'], meta['sha256'], meta['scanned_at']
                )
                cur.execute(insert_sql, params_insert)
        conn.commit()
    except Exception:
        conn.rollback()
        raise


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description='File metadata scanner -> SQLite')
    parser.add_argument('--roots', '-r', required=True, nargs='+', help='Root directories to scan')
    parser.add_argument('--db', default='fileindex.db', help='SQLite DB file to write')
    parser.add_argument('--workers', '-w', type=int, default=max(1, cpu_count() - 1), help='Number of worker processes to compute hashes')
    parser.add_argument('--hash', action='store_true', help='Compute SHA256 for each file (slow)')
    parser.add_argument('--batch-size', type=int, default=500, help='DB batch size for inserts')
    parser.add_argument('--follow-symlinks', action='store_true', help='Follow symlinks when walking')
    parser.add_argument('--include', help='Include file pattern (fnmatch)')
    parser.add_argument('--exclude', help='Exclude file pattern (fnmatch)')
    # MSSQL / SQL Server target (optional)
    parser.add_argument('--mssql-server', help='SQL Server host or instance (e.g. localhost\\SQLEXPRESS)')
    parser.add_argument('--mssql-database', help='Target database name')
    parser.add_argument('--mssql-user', help='SQL user (omit for integrated auth)')
    parser.add_argument('--mssql-password', help='SQL password')
    parser.add_argument('--mssql-driver', default='ODBC Driver 17 for SQL Server', help='ODBC driver name')
    args = parser.parse_args(argv)

    roots = [os.path.abspath(r) for r in args.roots]
    dbpath = args.db

    use_mssql = bool(args.mssql_server and args.mssql_database)
    mssql_conn = None
    conn = None
    insert_func = None

    if use_mssql:
        if not _HAS_PYODBC:
            print('pyodbc is not installed or could not be imported. Install pyodbc to use MSSQL target.')
            return 2
        # Build connection string
        driver = args.mssql_driver
        server = args.mssql_server
        database = args.mssql_database
        # Build a connection string with encryption enabled. For ODBC Driver 18 the default is to require encryption.
        # We explicitly set Encrypt and TrustServerCertificate to help connect to local developer instances.
        if args.mssql_user:
            conn_str = (
                f"DRIVER={{{driver}}};SERVER={server};DATABASE={database};UID={args.mssql_user};PWD={args.mssql_password};"
                f"Encrypt=YES;TrustServerCertificate=YES"
            )
        else:
            conn_str = (
                f"DRIVER={{{driver}}};SERVER={server};DATABASE={database};Trusted_Connection=Yes;"
                f"Encrypt=YES;TrustServerCertificate=YES"
            )
        try:
            mssql_conn = pyodbc.connect(conn_str, autocommit=False)
        except pyodbc.InterfaceError as e:
            # Provide a clearer error message for common driver/DSN issues
            raise pyodbc.InterfaceError(
                f"ODBC driver or data source not found. Check that the driver '{driver}' is installed and the server name is correct. Original error: {e}"
            )
        init_mssql(mssql_conn)
        insert_func = lambda c, rows: insert_batch_mssql(mssql_conn, rows)
        conn = mssql_conn
    else:
        conn = sqlite3.connect(dbpath, timeout=30)
        init_db(conn)
        insert_func = lambda c, rows: insert_batch(conn, rows)

    # Build generator of file paths
    files_iter = iter_files(roots, follow_symlinks=args.follow_symlinks, include=args.include, exclude=args.exclude)

    # We'll use a pool to process file metadata (and compute hash if requested)
    worker_count = args.workers if args.hash else 0

    if args.hash and worker_count > 0:
        pool = Pool(processes=worker_count)
        try:
            # Map file paths to worker input tuples
            mapped = ( (p, True) for p in files_iter )
            result_iter = pool.imap_unordered(process_path, mapped, chunksize=64)

            batch = []
            for res in result_iter:
                batch.append(res)
                if len(batch) >= args.batch_size:
                    insert_func(conn, batch)
                    print(f"Inserted batch of {len(batch)} rows")
                    batch = []
            if batch:
                insert_func(conn, batch)
                print(f"Inserted final batch of {len(batch)} rows")
        finally:
            pool.close()
            pool.join()
    else:
        # No hashing/workers requested; process inline for minimal overhead
        batch = []
        for p in files_iter:
            path, meta = process_path((p, False))
            batch.append((path, meta))
            if len(batch) >= args.batch_size:
                insert_func(conn, batch)
                print(f"Inserted batch of {len(batch)} rows")
                batch = []
        if batch:
            insert_func(conn, batch)
            print(f"Inserted final batch of {len(batch)} rows")

    if mssql_conn:
        mssql_conn.close()
    else:
        conn.close()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
