-- Setup script for FileImportDB
-- Run this as SA or a user with CREATE DATABASE permissions
-- For SQL Server Developer/Express/Standard/Enterprise

USE master;
GO

-- Create database if it doesn't exist
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'FileImportDB')
BEGIN
    CREATE DATABASE FileImportDB;
    PRINT 'Database FileImportDB created.';
END
ELSE
BEGIN
    PRINT 'Database FileImportDB already exists.';
END
GO

USE FileImportDB;
GO

-- The scanner will create the table automatically with all metadata fields:
IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='files' AND xtype='U')
BEGIN
    CREATE TABLE dbo.files (
        id BIGINT IDENTITY(1,1) PRIMARY KEY,
        path NVARCHAR(4000) UNIQUE NOT NULL,
        name NVARCHAR(1024),
        dir NVARCHAR(4000),
        extension NVARCHAR(64),
        size BIGINT,
        -- Unix timestamps (FLOAT)
        mtime_unix FLOAT,
        ctime_unix FLOAT,
        atime_unix FLOAT,
        -- DateTime fields (SQL Server native)
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
        scanned_at_datetime DATETIME2,
        INDEX idx_dir (dir),
        INDEX idx_extension (extension),
        INDEX idx_size (size),
        INDEX idx_mtime_datetime (mtime_datetime),
        INDEX idx_path_length (path_length),
        INDEX idx_scanned_at (scanned_at_datetime),
        INDEX idx_sha256 (sha256)
    );
    PRINT 'Table dbo.files created with extended metadata fields (Unix + DateTime).';
END
GO

-- Grant permissions to current Windows user (if using integrated auth)
-- Replace 'DOMAIN\Username' with your actual login name if needed
-- Example: EXEC sp_grantdbaccess 'AzureAD\JoergBrors', 'JoergBrors';

-- For the current user running this script, grant db_owner (or more restricted permissions as needed)
-- EXEC sp_addrolemember 'db_datareader', 'JoergBrors';
-- EXEC sp_addrolemember 'db_datawriter', 'JoergBrors';
-- EXEC sp_addrolemember 'db_ddladmin', 'JoergBrors';

-- Or grant full db_owner role for testing (not recommended for production):
-- EXEC sp_addrolemember 'db_owner', 'JoergBrors';

PRINT 'Setup complete. If you need to grant access to a specific user, run:';
PRINT 'USE FileImportDB; EXEC sp_grantdbaccess ''DOMAIN\Username'', ''Username''; EXEC sp_addrolemember ''db_owner'', ''Username'';';
GO
