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

# Optional imports for Windows metadata
try:
    import win32security  # type: ignore
    import win32api  # type: ignore
    import win32con  # type: ignore
    _HAS_PYWIN32 = True
except Exception:
    win32security = None  # type: ignore
    win32api = None  # type: ignore
    win32con = None  # type: ignore
    _HAS_PYWIN32 = False

import fnmatch


def init_db(conn: sqlite3.Connection) -> None:
    cur = conn.cursor()
    cur.executescript("""
    PRAGMA journal_mode=WAL;
    CREATE TABLE IF NOT EXISTS files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        path TEXT UNIQUE NOT NULL,
        name TEXT,
        dir TEXT,
        extension TEXT,
        size INTEGER,
        mtime_unix REAL,
        ctime_unix REAL,
        atime_unix REAL,
        mtime_datetime TEXT,
        ctime_datetime TEXT,
        atime_datetime TEXT,
        is_readonly INTEGER,
        is_hidden INTEGER,
        is_system INTEGER,
        is_archive INTEGER,
        attributes TEXT,
        sha256 TEXT,
        md5 TEXT,
        path_length INTEGER,
        path_depth INTEGER,
        owner TEXT,
        file_version TEXT,
        scanned_at_unix REAL,
        scanned_at_datetime TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_files_dir ON files(dir);
    CREATE INDEX IF NOT EXISTS idx_files_extension ON files(extension);
    CREATE INDEX IF NOT EXISTS idx_files_size ON files(size);
    CREATE INDEX IF NOT EXISTS idx_files_mtime ON files(mtime_datetime);
    CREATE INDEX IF NOT EXISTS idx_files_path_length ON files(path_length);
    CREATE INDEX IF NOT EXISTS idx_files_scanned_at ON files(scanned_at_datetime);
    CREATE INDEX IF NOT EXISTS idx_files_sha256 ON files(sha256);
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


def compute_md5(path: str, block_size: int = 4 * 1024 * 1024) -> Optional[str]:
    try:
        h = hashlib.md5()
        with open(path, 'rb') as f:
            while True:
                data = f.read(block_size)
                if not data:
                    break
                h.update(data)
        return h.hexdigest()
    except Exception:
        return None


def unix_to_datetime(timestamp: float) -> str:
    """Convert Unix timestamp to ISO datetime string"""
    try:
        from datetime import datetime
        return datetime.fromtimestamp(timestamp).isoformat()
    except Exception:
        return None


def get_file_owner(path: str) -> Optional[str]:
    """Get file owner (Windows or Unix)"""
    try:
        if sys.platform == 'win32':
            import win32security
            sd = win32security.GetFileSecurity(path, win32security.OWNER_SECURITY_INFORMATION)
            owner_sid = sd.GetSecurityDescriptorOwner()
            name, domain, type = win32security.LookupAccountSid(None, owner_sid)
            return f"{domain}\\{name}" if domain else name
        else:
            import pwd
            stat_info = os.stat(path)
            return pwd.getpwuid(stat_info.st_uid).pw_name
    except Exception:
        return None


def get_file_version(path: str) -> Optional[str]:
    """Get file version info (Windows only)"""
    try:
        if sys.platform == 'win32':
            import win32api
            info = win32api.GetFileVersionInfo(path, '\\')
            ms = info['FileVersionMS']
            ls = info['FileVersionLS']
            return f"{ms >> 16}.{ms & 0xFFFF}.{ls >> 16}.{ls & 0xFFFF}"
    except Exception:
        pass
    return None


def get_windows_attributes(path: str) -> Tuple[bool, bool, bool, str]:
    """Get Windows file attributes: hidden, system, archive, and raw attributes string"""
    try:
        if sys.platform == 'win32':
            import win32api
            import win32con
            attrs = win32api.GetFileAttributes(path)
            is_hidden = bool(attrs & win32con.FILE_ATTRIBUTE_HIDDEN)
            is_system = bool(attrs & win32con.FILE_ATTRIBUTE_SYSTEM)
            is_archive = bool(attrs & win32con.FILE_ATTRIBUTE_ARCHIVE)
            
            # Build attribute string
            attr_list = []
            if attrs & win32con.FILE_ATTRIBUTE_READONLY: attr_list.append('READONLY')
            if attrs & win32con.FILE_ATTRIBUTE_HIDDEN: attr_list.append('HIDDEN')
            if attrs & win32con.FILE_ATTRIBUTE_SYSTEM: attr_list.append('SYSTEM')
            if attrs & win32con.FILE_ATTRIBUTE_ARCHIVE: attr_list.append('ARCHIVE')
            if attrs & win32con.FILE_ATTRIBUTE_COMPRESSED: attr_list.append('COMPRESSED')
            if attrs & win32con.FILE_ATTRIBUTE_ENCRYPTED: attr_list.append('ENCRYPTED')
            
            return is_hidden, is_system, is_archive, '|'.join(attr_list)
    except Exception:
        pass
    return False, False, False, None


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
        
        # Get Windows-specific attributes
        is_hidden, is_system, is_archive, attributes = get_windows_attributes(path)
        
        # Calculate path metrics
        path_length = len(path)
        path_depth = path.count(os.sep)
        
        # Get owner (optional, may require pywin32)
        owner = get_file_owner(path)
        
        # Get file version (Windows only)
        file_version = get_file_version(path)
        
        sha = None
        md5_hash = None
        if do_hash:
            sha = compute_sha256(path)
            md5_hash = compute_md5(path)

        scanned_at = time.time()
        
        return path, {
            'name': name,
            'dir': dirn,
            'extension': ext,
            'size': size,
            'mtime_unix': mtime,
            'ctime_unix': ctime,
            'atime_unix': atime,
            'mtime_datetime': unix_to_datetime(mtime),
            'ctime_datetime': unix_to_datetime(ctime),
            'atime_datetime': unix_to_datetime(atime),
            'is_readonly': is_readonly,
            'is_hidden': int(is_hidden),
            'is_system': int(is_system),
            'is_archive': int(is_archive),
            'attributes': attributes,
            'sha256': sha,
            'md5': md5_hash,
            'path_length': path_length,
            'path_depth': path_depth,
            'owner': owner,
            'file_version': file_version,
            'scanned_at_unix': scanned_at,
            'scanned_at_datetime': unix_to_datetime(scanned_at)
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
            meta['mtime_unix'],
            meta['ctime_unix'],
            meta['atime_unix'],
            meta.get('mtime_datetime'),
            meta.get('ctime_datetime'),
            meta.get('atime_datetime'),
            meta['is_readonly'],
            meta.get('is_hidden', 0),
            meta.get('is_system', 0),
            meta.get('is_archive', 0),
            meta['attributes'],
            meta['sha256'],
            meta.get('md5'),
            meta.get('path_length', 0),
            meta.get('path_depth', 0),
            meta.get('owner'),
            meta.get('file_version'),
            meta['scanned_at_unix'],
            meta.get('scanned_at_datetime')
        ))

    if not to_upsert:
        return

    cur.execute('BEGIN')
    cur.executemany('''
        INSERT INTO files(path,name,dir,extension,size,mtime_unix,ctime_unix,atime_unix,mtime_datetime,ctime_datetime,atime_datetime,is_readonly,is_hidden,is_system,is_archive,attributes,sha256,md5,path_length,path_depth,owner,file_version,scanned_at_unix,scanned_at_datetime)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(path) DO UPDATE SET
          name=excluded.name,
          dir=excluded.dir,
          extension=excluded.extension,
          size=excluded.size,
          mtime_unix=excluded.mtime_unix,
          ctime_unix=excluded.ctime_unix,
          atime_unix=excluded.atime_unix,
          mtime_datetime=excluded.mtime_datetime,
          ctime_datetime=excluded.ctime_datetime,
          atime_datetime=excluded.atime_datetime,
          is_readonly=excluded.is_readonly,
          is_hidden=excluded.is_hidden,
          is_system=excluded.is_system,
          is_archive=excluded.is_archive,
          attributes=excluded.attributes,
          sha256=excluded.sha256,
          md5=excluded.md5,
          path_length=excluded.path_length,
          path_depth=excluded.path_depth,
          owner=excluded.owner,
          file_version=excluded.file_version,
          scanned_at_unix=excluded.scanned_at_unix,
          scanned_at_datetime=excluded.scanned_at_datetime;
    ''', to_upsert)
    conn.commit()


def init_mssql(conn: Any) -> None:
    cur = conn.cursor()
    # Create table if not exists (T-SQL pattern)
    cur.execute("""
    IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='files' AND xtype='U')
    BEGIN
        CREATE TABLE dbo.files (
            id BIGINT IDENTITY(1,1) PRIMARY KEY,
            path NVARCHAR(4000) UNIQUE NOT NULL,
            name NVARCHAR(1024),
            dir NVARCHAR(4000),
            extension NVARCHAR(64),
            size BIGINT,
            mtime_unix FLOAT,
            ctime_unix FLOAT,
            atime_unix FLOAT,
            mtime_datetime DATETIME2,
            ctime_datetime DATETIME2,
            atime_datetime DATETIME2,
            is_readonly BIT,
            is_hidden BIT,
            is_system BIT,
            is_archive BIT,
            attributes NVARCHAR(4000),
            sha256 NVARCHAR(128),
            md5 NVARCHAR(64),
            path_length INT,
            path_depth INT,
            owner NVARCHAR(512),
            file_version NVARCHAR(256),
            scanned_at_unix FLOAT,
            scanned_at_datetime DATETIME2
        );
        CREATE INDEX idx_dir ON dbo.files(dir);
        CREATE INDEX idx_extension ON dbo.files(extension);
        CREATE INDEX idx_size ON dbo.files(size);
        CREATE INDEX idx_mtime_datetime ON dbo.files(mtime_datetime);
        CREATE INDEX idx_path_length ON dbo.files(path_length);
        CREATE INDEX idx_scanned_at ON dbo.files(scanned_at_datetime);
        CREATE INDEX idx_sha256 ON dbo.files(sha256);
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
      name = ?, dir = ?, extension = ?, size = ?, 
      mtime_unix = ?, ctime_unix = ?, atime_unix = ?,
      mtime_datetime = ?, ctime_datetime = ?, atime_datetime = ?,
      is_readonly = ?, is_hidden = ?, is_system = ?, is_archive = ?, attributes = ?, 
      sha256 = ?, md5 = ?, path_length = ?, path_depth = ?, owner = ?, file_version = ?, 
      scanned_at_unix = ?, scanned_at_datetime = ?
    WHERE path = ?
    """)
    insert_sql = ("""
    INSERT INTO dbo.files(path,name,dir,extension,size,mtime_unix,ctime_unix,atime_unix,mtime_datetime,ctime_datetime,atime_datetime,is_readonly,is_hidden,is_system,is_archive,attributes,sha256,md5,path_length,path_depth,owner,file_version,scanned_at_unix,scanned_at_datetime)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """)

    try:
        for path, meta in rows:
            if meta.get('error'):
                continue
            params_update = (
                meta['name'], meta['dir'], meta['extension'], meta['size'], 
                meta['mtime_unix'], meta['ctime_unix'], meta['atime_unix'],
                meta.get('mtime_datetime'), meta.get('ctime_datetime'), meta.get('atime_datetime'),
                meta['is_readonly'], meta.get('is_hidden', 0), meta.get('is_system', 0), meta.get('is_archive', 0),
                meta['attributes'], meta['sha256'], meta.get('md5'), meta.get('path_length', 0), meta.get('path_depth', 0),
                meta.get('owner'), meta.get('file_version'), meta['scanned_at_unix'], meta.get('scanned_at_datetime'), path
            )
            cur.execute(update_sql, params_update)
            if cur.rowcount == 0:
                params_insert = (
                    path, meta['name'], meta['dir'], meta['extension'], meta['size'], 
                    meta['mtime_unix'], meta['ctime_unix'], meta['atime_unix'],
                    meta.get('mtime_datetime'), meta.get('ctime_datetime'), meta.get('atime_datetime'),
                    meta['is_readonly'], meta.get('is_hidden', 0), meta.get('is_system', 0), meta.get('is_archive', 0),
                    meta['attributes'], meta['sha256'], meta.get('md5'), meta.get('path_length', 0), meta.get('path_depth', 0),
                    meta.get('owner'), meta.get('file_version'), meta['scanned_at_unix'], meta.get('scanned_at_datetime')
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
