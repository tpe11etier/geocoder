-------------------------------------------------------------------------------
--
--  BulkLoadContactGeoLocations.sql
--
--  This utility takes a comma delimited file containing the user Login Name (or SourceIdentifier)
--  along with their address information (containing Zip Code) or predetermined Latitude / Longitude:
--    DataFile: contains this comma delimited structure:
--	          * LoginName (or SourceIdentifier)
--	          * Address1
--	          * Address2
--	          * City
--	          * State
--	          * Zip
--	          * Country
--	          * Latitude
--	          * Longitude
--  And loads this file into a temporary table where it will do the following:
--    1. Find the Organization and Contact Id for the LoginName / SourceIdentifier provided
--    2. Determine if there is an existing ContactGeoLocation row for the specified AddressType
--    3. Look up the Zip Code (if no Latitude/Longitude were provided)
--    4. Mark any invalid LatLng / ZipCodes as "Broken" (will not be updated)
--    5. Check for Records that exactly match the current data
--    6. Get counts of Invalid LoginNames (or SourceIds), Bad Address, "Current" data
--    7. If in reporting mode, count # of rows to Create / Update / Delete and report back (**END**)
--    8. Begin looping through records that need to be updated (commit every XXX rows)
--    9. Disable the existing row (if found)
--    10. Calculate point and insert new Address Row
--
--  An output file will be produced with the information:
--    1. Any errors that prevented the process from running properly (Invalid file / Organization / AddressType)
--    2. The Organization Name and Address Type Name to be imported
--    3. The Data file (with full path) containing the Member Identifier and address info
--    4. The total records loaded from the file
--    5. A list of any Members/SourceIdentifiers that could not be found
--    6. A list of Members with Zip Codes that could not be found
--    7. The count of any ContactGeoLocation rows to be ignored (current) / created / updated / deleted
--  
--  Input (using -v):
--  
--  OrgId:         A valid Organization Id that the provided Members can be found in (or the MBAdmin level OrganizationId for a multi-org import)
--  AddressTypeId: The OrganizationGISAddressTypeId that the addresses should be loaded as (resolves to 'Home' / 'Work' / 'Alternate' for the organization)
--  DataFile:      The file containing the list of Members and their address (and zip / geocode) information
--                 This file should be comma delimited with the following structure: 
--                 {LoginName}, {Address1}, {Address2}, {City}, {State}, {Zip}, {Country}, {Latitude}, {Longitude}
--  FilePath:      Can be specified instead of including the full path on each File - must be provided as "" to ignore
--  ReportOnly:    A "1" Indicates that No Data creation should be performed (leave blank or 0 to perform work).  
--  UseSourceId:   A "1" Indicates that "LoginName" field contains the organization Source Identifier value (leave blank or 0 to default to LoginName).  
--
--
--  Examples: sqlcmd -S MyServer -d ep_db -E -I -i BulkLoadContactGeoLocations.sql -vOrgId="143" AddressTypeId="3" DataFile="c:\work\SQLUtil\DataFile.csv" FilePath="" ReportOnly="1" UseSourceId="0"
--            sqlcmd -S MyServer -d ep_db -E -I -i BulkLoadContactGeoLocations.sql -vOrgId="143" AddressTypeId="3" DataFile="DataFile.csv" FilePath="c:\work\SQLUtil\" ReportOnly="0" UseSourceId="1" 
--
-------------------------------------------------------------------------------

/*  To run in a SQL Query window, add two dashes to the beginning of this line 
-- These are defined for hard-coded testing purposes in Dev.  Each of these values
-- needs to be passed into this function
:SetVar OrgId 10
:SetVar AddressTypeId 9
:SetVar DataFile FSecure3.csv
:SetVar FilePath d:\work\sqlutil\
:SetVar ReportOnly 0
:SetVar UseSourceId 1
-- */

-- This one cannot be set from the command line
:SetVar CommitLoop 100

-- Turn on Error Handling (Abort on Error)
:ON ERROR EXIT

SET NOCOUNT ON;
DECLARE @aOrgId INT;
DECLARE @aAddressTypeId INT;
DECLARE @aOrgName NVARCHAR(256);
DECLARE @aAddressTypeName NVARCHAR(256);
DECLARE @aMemberName NVARCHAR(256);
DECLARE @aDomainId INT;
DECLARE @aFilePath VARCHAR(256);
DECLARE @aDataFile VARCHAR(256);
DECLARE @aReportOnly INT;
DECLARE @aUseSourceId INT;
DECLARE @aCommitLoop INT;
DECLARE @aFolderDesc NVARCHAR(64);  
DECLARE @aGroupDesc NVARCHAR(64);   

-- Output Variables
DECLARE @aRowCount   		 INT;	-- Total Rows Bulk loaded
DECLARE @aInvalidMemberCount INT;   -- Number of Rows with an Invalid LoginName / SourceIdentifier
DECLARE @aInvalidDataCount	 INT;	-- Number of DataFile rows with no valid zip and no valid Lat/Lng
DECLARE @aDeletedCount 		 INT;	-- Number of DataFile rows with a completely empty address (to be deleted)
DECLARE @aCreatedCount		 INT;	-- Number of ContactGeoLocation rows Created
DECLARE @aUpdatedCount		 INT;	-- Number of ContactGeoLocation rows Updated
DECLARE @aSkippedCount		 INT;	-- Number of ContactGeoLocation rows that were already up to date
DECLARE @aDuplicateCount	 INT;	-- Number of DataFile loginnames that are duplicated 

-- Ensure that Required Variables were provided
SET @aFilePath = '$(FilePath)';
IF @aFilePath = '$' + '(FilePath)' BEGIN
	SET @aFilePath = '';
END 

IF '$(OrgId)' = '' BEGIN
	PRINT 'Organization Id Not Provided';
	RETURN;
END

IF '$(AddressTypeId)' = '' BEGIN
	PRINT 'Address Type Id Not Provided';
	RETURN;
END

IF '$(DataFile)' = '' BEGIN
	PRINT 'Data File Not Provided';
	RETURN;
END

IF ISNUMERIC('$(OrgId)') = 0 BEGIN
	PRINT 'Invalid Org Id Provided: $(OrgId)';
	RETURN;
END
SET @aOrgId = CAST('$(OrgId)' as INT);

IF ISNUMERIC('$(AddressTypeId)') = 0 BEGIN
	PRINT 'Invalid Address Type Id Provided: $(AddressTypeId)';
	RETURN;
END
SET @aAddressTypeId = CAST('$(AddressTypeId)' as INT);


-- Validate ReportOnly flag
IF '$(ReportOnly)' != '' AND '$(ReportOnly)' != '1' AND '$(ReportOnly)' != '0' BEGIN -- ISNUMERIC('$(ReportOnly)') = 0 BEGIN
	PRINT 'Invalid ReportOnly Flag Provided: $(ReportOnly)';
	RETURN;
END
SET @aReportOnly = CAST('$(ReportOnly)' as INT);

-- Validate SourceId parameter
IF '$(UseSourceId)' != '' AND '$(UseSourceId)' != '1' AND '$(UseSourceId)' != '0' BEGIN -- ISNUMERIC('$(UseSourceId)') = 0 BEGIN
	PRINT 'Invalid UseSourceId Flag Provided: $(UseSourceId)';
	RETURN;
END
SET @aUseSourceId = CAST('$(UseSourceId)' as INT);

-- Check for CommitLoop 
IF '$(CommitLoop)' != '' AND ISNUMERIC('$(CommitLoop)') = 0 OR CAST('$(CommitLoop)' as INT) <= 0 BEGIN
	PRINT 'Invalid CommitLoop value Provided: $(CommitLoop)';
	RETURN;
END
SET @aCommitLoop = CAST('$(CommitLoop)' as INT);

IF @aCommitLoop <= 0 BEGIN
	SET @aCommitLoop = 100;
END;

-- Set up the File variable with the correct path and validate:
SET @aDataFile = '$(DataFile)';

-- Tack on the FilePath if Provided
IF @aFilePath <> '' BEGIN
    -- If they didn't add the '\' to the FilePath, put it in for them
	IF Right(@aFilePath,1) <> '\' BEGIN
		SET @aDataFile = '\' + @aDataFile;
	END
	SET @aDataFile = @aFilePath + @aDataFile;
END

-- Let's check to see if the file exists....
DECLARE @aFileExists INT 
EXEC Master.dbo.xp_fileexist @aDataFile, @aFileExists OUT 

IF @aFileExists = 0 BEGIN
	PRINT 'Invalid data file provided: ' + @aDataFile;
	RETURN;
END

-- Get the Org Name for Logging
SELECT @aOrgName = Name 
FROM MBOrganization
WHERE OrganizationId = @aOrgId;

IF ISNULL(@aOrgName,'') = '' BEGIN
	PRINT 'Org Id provided was not found: $(OrgId)';
	RETURN;
END

-- Get the Address Type Name for Logging
SELECT @aAddressTypeName = Name 
FROM MBOrganizationGISAddressType
WHERE OrganizationId = @aOrgId 
AND OrganizationGISAddressTypeId = @aAddressTypeId;

IF ISNULL(@aAddressTypeName,'') = '' BEGIN
	PRINT 'Address Type Id ("$(AddressTypeId)") was not found for: ' + @aOrgName;
	RETURN;
END

PRINT 'Importing GIS Location (' + @aAddressTypeName + ') data for: ' + @aOrgName;

-- Clean up Temp tables (if exist)
IF OBJECT_ID('tempdb..#tmpAddressData','local') IS NOT NULL
BEGIN
	DROP TABLE #tmpAddressData
END

IF OBJECT_ID('tempdb..#tmpLoadTable','local') IS NOT NULL
BEGIN
	DROP TABLE #tmpLoadTable
END


-- Load up the Address Data 
CREATE TABLE #tmpLoadTable
(	[LoginName] [nvarchar](150), 
	[Address1]  [nvarchar](256),
	[Address2]  [nvarchar](256), 
	[City]      [nvarchar](256), 
	[State]     [nvarchar](256), 
	[ZipCode]   [nvarchar](30), 
	[Country]   [nvarchar](256),
	[Latitude]  [numeric] (14,8),
	[Longitude] [numeric] (14,8)
)

CREATE TABLE #tmpAddressData
(	[LoginName] [nvarchar](150), 
	[Address1]  [nvarchar](256),
	[Address2]  [nvarchar](256), 
	[City]      [nvarchar](256), 
	[State]     [nvarchar](256), 
	[ZipCode]   [nvarchar](30), 
	[Country]   [nvarchar](256),
	[Latitude]  [numeric] (14,8),
	[Longitude] [numeric] (14,8),
	[OrganizationId] [int],
	[ContactId] [int],
	[LookupStatus] [int]
)
PRINT 'Loading data from: ' + @aDataFile;
DECLARE @aBulkCmd varchar(1000);

SET @aBulkCmd = 'BULK INSERT #tmpLoadTable FROM ' + 
				'''' + @aDataFile + ''' ' + 
			    'WITH (FIELDTERMINATOR = '','', ROWTERMINATOR = ''\n'')';
EXEC(@aBulkCmd);

IF (@@ERROR != 0) BEGIN
	PRINT 'Failed to Complete Bulk Load Operation' 
	RETURN;
END

SELECT @aRowCount = COUNT(*)
FROM #tmpLoadTable;

PRINT 'Loaded ' + CAST(@aRowCount as VARCHAR(6)) + ' Records' 

-- Get the Domain for finding the appropriate Member
SELECT @aDomainId = dbo.fn_GetDomainIdFromOrganizationId(@aOrgId);

IF @aUseSourceId = 1 BEGIN
	PRINT 'Finding Members By SourceIdentifier';
	INSERT INTO #tmpAddressData
	([LoginName], [Address1], [Address2], [City], [State], [ZipCode], [Country], 
	 [Latitude], [Longitude], [OrganizationId], [ContactId], [LookupStatus])
	SELECT tmp.*, 
			-- This shouldn't happen, but if it does, take the top level org for the Member (we need to guarantee one row ONLY)
		   (SELECT TOP 1 OrganizationId FROM MBContext WHERE MemberId = MBMember.MemberID) [OrganizationId],
		   MBMember.[ContactId], 3 [LookupStatus]
	FROM #tmpLoadTable tmp
	LEFT OUTER JOIN MBMember ON MBMember.DomainId = @aDomainId AND 
								MBMember.SourceIdentifier = tmp.LoginName AND
								MBMember.Enabled = 1
END ELSE BEGIN
	PRINT 'Finding Members By LoginName';
	INSERT INTO #tmpAddressData
	([LoginName], [Address1], [Address2], [City], [State], [ZipCode], [Country], 
	 [Latitude], [Longitude], [OrganizationId], [ContactId], [LookupStatus])
	SELECT tmp.*, 
		    -- This shouldn't happen, but if it does, take first org for the Member (we need to guarantee one row ONLY)
  		   (SELECT TOP 1 OrganizationId FROM MBContext WHERE MemberId = MBMember.MemberID) [OrganizationId],
  		   MBMember.[ContactId], 3 [LookupStatus]
	FROM #tmpLoadTable tmp
	LEFT OUTER JOIN MBMember ON MBMember.DomainId = @aDomainId AND 
								MBMember.Enabled = 1 AND
								MBMember.LoginName = tmp.LoginName
END

-- A list of internal status values we'll use:
-- Null - no update required
-- 3 - User Supplied
-- 4 - Zip Code look up
-- 5 - Invalid Zip Code / LatLng

-- Match the loaded addresses against the ZipCode table (where necessary)
UPDATE #tmpAddressData
SET Latitude = zip.Latitude,
    Longitude = zip.Longitude,
	LookupStatus = CASE ISNULL(zip.ZipCode,'00000') WHEN '00000' THEN 5 ELSE 4 END
FROM #tmpAddressData tmp
LEFT OUTER JOIN MBZipCodeGeoLocation [zip] ON zip.ZipCode = tmp.ZipCode
WHERE ISNULL(tmp.Latitude,0) = 0
AND   ISNULL(tmp.Longitude,0) = 0
AND   ContactId IS NOT NULL
AND   OrganizationId IS NOT NULL

-- Mark any still unmatched data (or bad to begin with) with status = 5
-- We'll also check for any "To Be Deleted" address records - which is where *all* data is empty
UPDATE #tmpAddressData
SET LookupStatus = CASE WHEN (    ISNULL(Address1,'') = ''
							  AND ISNULL(Address2,'') = ''
							  AND ISNULL(City,'') = ''
							  AND ISNULL(State,'') = ''
							  AND ISNULL(ZipCode,'') = ''
							  AND ISNULL(Country,'') = ''
							  AND ISNULL(Latitude,0) = 0
							  AND ISNULL(Longitude,0) = 0) THEN -1 ELSE 5 END
WHERE ((ISNULL(Latitude,0) = 0 AND ISNULL(Longitude,0) = 0) OR
(ISNULL(Latitude,0) < -90 OR ISNULL(Latitude,0) > 90) OR
(ISNULL(Longitude,0) < -180 OR ISNULL(Longitude,0) > 180))
AND   ContactId IS NOT NULL
AND   OrganizationId IS NOT NULL

-- If only one of latitude and longitude are set, set the status to 5 (invalid)
UPDATE #tmpAddressData
SET LookupStatus = 5 
WHERE ((Latitude IS NULL AND Longitude IS NOT NULL) OR 
       (Latitude IS NOT NULL AND Longitude IS NULL)) 


-- Mark duplicates as invalid
UPDATE #tmpAddressData 
SET lookupStatus = 6 
WHERE loginname in 
(SELECT loginname FROM #tmpAddressData GROUP BY loginname HAVING count(*)> 1) 

SELECT @aDuplicateCount = @@ROWCOUNT 




-- Clear out any rows that exactly match the current row in the ContactGeoLocation table
-- or any deletes that don't have a enabled row in ContactGeoLocation 
UPDATE #tmpAddressData
SET LookupStatus = NULL
FROM #tmpAddressData tmp
LEFT OUTER JOIN MBContactGeoLocation geo ON geo.OrganizationId = tmp.OrganizationId
										AND geo.Enabled = 1
										AND geo.ContactId = tmp.ContactId
										AND geo.GISAddressTypeId = @aAddressTypeId
WHERE tmp.ContactId IS NOT NULL
AND   tmp.OrganizationId IS NOT NULL
AND   (
         (tmp.LookupStatus NOT IN (-1,5,6) 
			AND geo.ContactGeoLocationId IS NOT NULL
			AND ISNULL(geo.Address1,'') = ISNULL(tmp.Address1,'')
			AND ISNULL(geo.Address2,'') = ISNULL(tmp.Address2,'')
			AND ISNULL(geo.City,'') = ISNULL(tmp.City,'')
			AND ISNULL(geo.State,'') = ISNULL(tmp.State,'')
			AND ISNULL(geo.ZipCode,'') = ISNULL(tmp.ZipCode,'')
			AND ISNULL(geo.Country,'') = ISNULL(tmp.Country,'')
			AND ISNULL(geo.Latitude,0) = ISNULL(tmp.Latitude,0)
			AND ISNULL(geo.Longitude,0) = ISNULL(tmp.Longitude,0)
			AND geo.LookupStatus = tmp.LookupStatus
		  )
      OR (tmp.LookupStatus = -1 AND geo.ContactGeoLocationId IS NULL)
      )

-- Get the counts of Invalid Members, Invalid Data records and up to date records
SELECT @aInvalidMemberCount = SUM(CASE WHEN ContactId IS NULL OR OrganizationId IS NULL THEN 1 ELSE 0 END),
	   @aInvalidDataCount = SUM(CASE WHEN LookUpStatus = 5 THEN 1 ELSE 0 END),
	   @aSkippedCount = SUM(CASE WHEN LookUpStatus IS NULL THEN 1 ELSE 0 END)
FROM #tmpAddressData

PRINT '';

-- Dump out the Login Names we didn't match to the provided Org (tree).
IF ISNULL(@aInvalidMemberCount,0) > 0 BEGIN
	PRINT 'Found ' + CAST(@aInvalidMemberCount as VARCHAR(6)) + ' Login Names that cannot be matched to Org' 
	SELECT LoginName [Members_Not_Found]
	FROM #tmpAddressData
	WHERE ContactId IS NULL OR OrganizationId IS NULL;
	PRINT '';
END

IF ISNULL(@aInvalidDataCount,0) > 0 BEGIN
	PRINT 'Found ' + CAST(@aInvalidDataCount as VARCHAR(6)) + ' Records with invalid address data' 
	SELECT LoginName [Members_With_Invalid_Data], ZipCode, Latitude, Longitude
	FROM #tmpAddressData
	WHERE LookUpStatus = 5;
	PRINT '';
END


IF ISNULL(@aDuplicateCount,0) > 0 BEGIN
	PRINT 'Found ' + CAST(@aDuplicateCount as VARCHAR(6)) + ' Records with duplicated login names' 
	SELECT LoginName [Members_With_Duplicate_Names], ZipCode, Latitude, Longitude
	FROM #tmpAddressData
	WHERE LookUpStatus = 6;
	PRINT '';
END


IF ISNULL(@aSkippedCount,0) > 0 BEGIN
	PRINT 'Found ' + CAST(@aSkippedCount as VARCHAR(6)) + ' Records with address info already up to date' 
	PRINT '';
END

-- If they just want to know what data we'll create, let's give that to them
IF @aReportOnly = 1 BEGIN
	-- Let's give them a count of what we'll create
	PRINT 'Data to be Created...'
	SELECT @aUpdatedCount = SUM(CASE WHEN tmp.LookupStatus > 0 AND ContactGeoLocationId IS NOT NULL THEN 1 ELSE 0 END),
		   @aCreatedCount = SUM(CASE WHEN tmp.LookupStatus > 0 AND ContactGeoLocationId IS NULL THEN 1 ELSE 0 END),
		   @aDeletedCount = SUM(CASE WHEN tmp.LookupStatus = -1 THEN 1 ELSE 0 END)
	FROM #tmpAddressData tmp
	LEFT OUTER JOIN MBContactGeoLocation geo ON geo.OrganizationId = tmp.OrganizationId
											AND geo.Enabled = 1
											AND geo.ContactId = tmp.ContactId
											AND geo.GISAddressTypeId = @aAddressTypeId
	WHERE tmp.ContactId IS NOT NULL 
	AND	  tmp.OrganizationId IS NOT NULL 
	AND   tmp.LookupStatus IN (-1,3,4)
	
	SET @aUpdatedCount = ISNULL(@aUpdatedCount,0);
	SET @aCreatedCount = ISNULL(@aCreatedCount,0);
	SET @aDeletedCount = ISNULL(@aDeletedCount,0);
	
	PRINT '  Updates: ' + CAST(@aUpdatedCount AS VARCHAR(6));
	PRINT '  Creates: ' + CAST(@aCreatedCount AS VARCHAR(6));
	PRINT '  Deletes: ' + CAST(@aDeletedCount AS VARCHAR(6));

	-- Stop Processing
	RETURN;
END

-- Reset the RowCount to the number of rows we should be processing:
SET @aRowCount = @aRowCount - (@aInvalidMemberCount + @aInvalidDataCount + @aSkippedCount + @aDuplicateCount) 
IF @aRowCount = 0 BEGIN
	PRINT 'Load Complete: No Rows to Process.'
	RETURN;
END;

-- Get the timestamp for cleaning up manually later (if necessary)
DECLARE @aCreationDblts DateTime;
DECLARE @aEndDblts DateTime;

SET @aCreationDblts = getDate();

DECLARE @aCurrentRow INT;
DECLARE @aCommitEnd INT;

SET @aCurrentRow = 1;

DECLARE @aAddress1  [nvarchar](256);
DECLARE @aAddress2  [nvarchar](256); 
DECLARE @aCity      [nvarchar](256); 
DECLARE @aState     [nvarchar](256); 
DECLARE @aZipCode   [nvarchar](30); 
DECLARE @aCountry   [nvarchar](256);
DECLARE @aLatitude  [numeric] (14,8);
DECLARE @aLongitude [numeric] (14,8);
DECLARE @aOrganizationId [int];
DECLARE @aContactId [int];
DECLARE @aLookupStatus [int];
DECLARE @aIsUpdate [int];

SET @aUpdatedCount = 0;
SET @aCreatedCount = 0;
SET @aDeletedCount = 0;

-- Set up a cursor to step through the rows that need updating/creating
DECLARE Update_Cursor CURSOR FOR
SELECT tmp.[Address1], tmp.[Address2], tmp.[City], tmp.[State], tmp.[ZipCode], tmp.[Country], 
	 tmp.[Latitude], tmp.[Longitude], tmp.[OrganizationId], tmp.[ContactId], tmp.[LookupStatus], CASE WHEN ContactGeoLocationId IS NULL THEN 0 ELSE 1 END [IsUpdate]
FROM #tmpAddressData tmp
LEFT OUTER JOIN MBContactGeoLocation geo ON geo.OrganizationId = tmp.OrganizationId
										AND geo.Enabled = 1
										AND geo.ContactId = tmp.ContactId
										AND geo.GISAddressTypeId = @aAddressTypeId
WHERE tmp.ContactId IS NOT NULL 
AND	  tmp.OrganizationId IS NOT NULL 
AND   tmp.LookupStatus IN (-1,3,4)
ORDER BY CASE WHEN ContactGeoLocationId IS NULL THEN 0 ELSE 1 END DESC  -- do records that need updates first

OPEN Update_Cursor;

FETCH NEXT FROM Update_Cursor 
INTO @aAddress1, @aAddress2, @aCity, @aState, @aZipCode, @aCountry, @aLatitude, @aLongitude, @aOrganizationId, @aContactId, @aLookupStatus, @aIsUpdate;

PRINT '**Beginning Commit Loop**'
WHILE @@FETCH_STATUS = 0
BEGIN
	
	SET @aCommitEnd = @aCurrentRow + @aCommitLoop;
	-- Loop through the Address Data file and Update/Create the new data (with points)
	IF  @aCommitEnd > @aRowCount BEGIN
		SET @aCommitEnd = @aRowCount + 2;
		PRINT '.Processing Update/Insert ' + CAST(@aCurrentRow AS VARCHAR(6)) + ' to ' + CAST((@aRowCount) AS VARCHAR(6)) + ' of ' + CAST(@aRowCount AS VARCHAR(6));  -- X to Y of total
		-- This shouldn't be necessary, but adding to the rowcount here will prevent any unknown defects from looping forever
		SET @aRowCount = @aRowCount + @aCommitLoop;
	END ELSE BEGIN
		PRINT '.Processing Update/Insert ' + CAST(@aCurrentRow AS VARCHAR(6)) + ' to ' + CAST((@aCommitEnd - 1) AS VARCHAR(6)) + ' of ' + CAST(@aRowCount AS VARCHAR(6));  -- X to Y of total
	END

	BEGIN TRANSACTION;

	WHILE (@aCurrentRow < @aCommitEnd) AND @@FETCH_STATUS = 0
	BEGIN
			-- Update the Existing Row (if necessary)
		IF @aIsUpdate = 1 BEGIN
			IF @aLookupStatus = -1 BEGIN
				SET @aDeletedCount = @aDeletedCount + 1;
			END ELSE BEGIN
				SET @aUpdatedCount = @aUpdatedCount + 1;
			END
			
			UPDATE MBContactGeoLocation
			SET Enabled = 0, 
				DeletionDblts = @aCreationDblts
			WHERE 
				OrganizationId = @aOrganizationId
			AND Enabled = 1
			AND ContactId = @aContactId
			AND GISAddressTypeId = @aAddressTypeId

			IF @@ROWCOUNT != 1 BEGIN
				-- This should never happen and you need to do weird locking/stepping stuff to test
				PRINT 'There was an error updating ContactId ' + CAST(@aContactId as VARCHAR(10)) + '. Rolling Back to last commit.';
				ROLLBACK;
				BREAK;
			END

		END ELSE BEGIN
			SET @aCreatedCount = @aCreatedCount + 1;
		END

		-- Insert the new row (if it's not a delete)
		IF @aLookupStatus > 0 BEGIN
			DECLARE @aGeog geography
			SELECT @aGeog = NULL

			SELECT @aGeog =  geography::STGeomFromText('POINT('+convert(nvarchar(16),@aLongitude)+' ' + convert(nvarchar(16),@aLatitude) + ')', 4326)

			INSERT MBContactGeoLocation 
			( [Address1],[Address2],[City],[State],[Country],[ZipCode],[LookupDblts],[LookupStatus],[Longitude],[Latitude],[ContactId],[GISAddressTypeId],[OrganizationId], [Point] ) 
			VALUES ( @aAddress1,@aAddress2,@aCity,@aState,@aCountry,@aZipCode,@aCreationDblts,@aLookupStatus,@aLongitude,@aLatitude,@aContactId,@aAddressTypeId,@aOrganizationId,@aGeog ) 
		END
		
		SET @aCurrentRow = @aCurrentRow + 1;
		
		FETCH NEXT FROM Update_Cursor 
		INTO @aAddress1, @aAddress2, @aCity, @aState, @aZipCode, @aCountry, @aLatitude, @aLongitude, @aOrganizationId, @aContactId, @aLookupStatus, @aIsUpdate;
		
	END;

	COMMIT;

END

CLOSE Update_Cursor
DEALLOCATE Update_Cursor

PRINT ''
PRINT '**Process Complete**'
PRINT ''
PRINT '  Updated ' + CAST(@aUpdatedCount AS VARCHAR(6)) + ' ContactGeoLocation Rows';
PRINT '  Created ' + CAST(@aCreatedCount AS VARCHAR(6)) + ' ContactGeoLocation Rows';
PRINT '  Deleted ' + CAST(@aDeletedCount AS VARCHAR(6)) + ' ContactGeoLocation Rows';
PRINT ''
PRINT ''
SELECT @aEndDblts = DateAdd(s, 1, GetDate());
PRINT 'All Data was created between ' + 
	  CONVERT(NVARCHAR(32), @aCreationDblts, 120) + ' and ' + 
	  CONVERT(NVARCHAR(32), @aEndDblts, 120)
PRINT 'To back this out, the following command can be changed to DELETE FROM ' 
PRINT '    SELECT * FROM MBContactGeoLocation WHERE ' + 
      ' dbo.fn_GetDomainIdFromOrganizationId(OrganizationId) = ' + CAST(@aDomainId AS VARCHAR(10)) +
      ' AND CreationDblts >= ''' + CONVERT(NVARCHAR(32), @aCreationDblts, 120) + '''' +
      ' AND CreationDblts <= ''' + CONVERT(NVARCHAR(32), @aEndDblts, 120) + '''' 
PRINT 'And this one to UPDATE MBContactGeoLocation Set Enabled = 1, DeletionDblts = NULL ' 
PRINT '    SELECT * FROM MBContactGeoLocation WHERE OrganizationId = ' + CAST(@aOrgId AS VARCHAR(10)) +
      ' AND dbo.fn_GetDomainIdFromOrganizationId(OrganizationId) = ' + CAST(@aDomainId AS VARCHAR(10)) +
      ' AND Enabled = 0 '  +
      ' AND DeletionDblts >= ''' + CONVERT(NVARCHAR(32), @aCreationDblts, 120) + ''''  +
      ' AND DeletionDblts <= ''' + CONVERT(NVARCHAR(32), @aEndDblts, 120) + '''' 

