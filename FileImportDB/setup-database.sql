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

-- The scanner will create the table automatically, but you can also create it manually:
-- IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='files' AND xtype='U')
-- BEGIN
--     CREATE TABLE dbo.files (
--         path NVARCHAR(4000) PRIMARY KEY,
--         name NVARCHAR(1024),
--         dir NVARCHAR(4000),
--         extension NVARCHAR(64),
--         size BIGINT,
--         mtime FLOAT,
--         ctime FLOAT,
--         atime FLOAT,
--         is_readonly BIT,
--         attributes NVARCHAR(4000),
--         sha256 NVARCHAR(128),
--         scanned_at FLOAT
--     );
--     PRINT 'Table dbo.files created.';
-- END
-- GO

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
