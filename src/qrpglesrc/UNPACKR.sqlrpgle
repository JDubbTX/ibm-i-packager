**FREE
// ============================================================================
// Program:     UNPACKR
// Source File: UNPACKR.sqlrpgle
// Description: Core SQLRPGLE unpackaging engine for #UNPACK command.
//              1. Inspects Save File inventory via QSZRTVSO (SAVI0200)
//              2. Resolves target libraries using LIBMAP (by Object Type
//                 and Extended Attribute) or DFTLIB
//              3. Backs up existing target objects to Rollback Save File
//              4. Sorts objects by strict Dependency Precedence Tiers (10..80)
//              5. Replaces existing objects while preserving:
//                 - ALL Object Authorities (Owner, PGP, AUTL, *PUBLIC, and
//                   all private user authorities via GRTOBJAUT REFOBJ +
//                   QSYS2.OBJECT_PRIVILEGES replay)
//                 - Existing Physical File / SQL Table data (via CPYF
//                   FMTOPT(*MAP *DROP)) and dependent Logical Files
// ============================================================================
ctl-opt dftactgrp(*no) actgrp(*caller) option(*srcstmt:*nodebugio);

/include 'PKGTYPES.rpgleinc'

// ----------------------------------------------------------------------------
// Program Entry Parameters (from UNPACKC.pgm.clle)
// ----------------------------------------------------------------------------
dcl-pi UNPACKR;
  inInpType   char(6)    const;
  inStmf      char(256)  const;
  inWrkSavf   char(10)   const;
  inWrkLib    char(10)   const;
  inDftLib    char(10)   const;
  inLibMapBuf char(1024) const;
  inMapFile   char(256)  const;
  inCpyDta    char(4)    const;
  inBkpSavf   char(10)   const;
  inBkpLib    char(10)   const;
  inManifest  char(256)  const;
  outFullMnft char(256);
  outRtnCde   char(1);
end-pi;

// ----------------------------------------------------------------------------
// Data Structures for Authority Snapshot & Package Inventory
// ----------------------------------------------------------------------------
dcl-ds PrivEntry_t qualified template;
  UserName   char(10);
  ObjAut     varchar(128);
  ObjOper    char(3);
  ObjMgt     char(3);
  ObjExist   char(3);
  ObjAlter   char(3);
  ObjRef     char(3);
  DataRead   char(3);
  DataAdd    char(3);
  DataUpd    char(3);
  DataDlt    char(3);
  DataExec   char(3);
end-ds;

dcl-ds AuthSnapshot_t qualified template;
  Owner      char(10);
  Pgp        char(10);
  Autl       char(10);
  PrivCount  int(10);
  Privs      likeds(PrivEntry_t) dim(200);
end-ds;

dcl-ds PkgItem_t qualified template;
  ObjName      char(10);
  SavedLib     char(10);
  ObjType      char(10);
  ExtAttr      char(10);
  DataSaved    char(1);
  ObjSize      int(10);
  TextDesc     char(50);
  TgtLib       char(10);
  PrecTier     int(10);
  ExistsNow    ind;
  PreserveData ind;
  Version      char(10);
end-ds;

// ----------------------------------------------------------------------------
// Global / Module-Level Working Storage
// ----------------------------------------------------------------------------
dcl-ds LibMapRules     likeds(LibMapEntry_t) dim(200);
dcl-s  LibMapCount     int(10) inz(0);

dcl-ds FileOverrides   likeds(FileDataOverride_t) dim(500);
dcl-s  FileOverrideCnt int(10) inz(0);

dcl-s  JsonDftLib      char(10) inz(*blanks);
dcl-s  JsonDftPreserve char(1)  inz(' ');

dcl-ds PkgItems        likeds(PkgItem_t) dim(5000);
dcl-s  PkgItemCnt      int(10) inz(0);

dcl-s  SeqCounter      int(10) inz(0);

// ----------------------------------------------------------------------------
// Main Procedure
// ----------------------------------------------------------------------------
exec sql SET OPTION COMMIT = *NONE, CLOSQLCSR = *ENDMOD, NAMING = *SYS;

outRtnCde   = '0';
outFullMnft = *blanks;

// 1a. Parse LIBMAP command parameter buffer into LibMapRules array
ParseLibMap(inLibMapBuf: LibMapRules: LibMapCount);

// 1b. If JSON MAPFILE is provided, load library mappings & file overrides
if %trim(inMapFile) <> '*NONE' and %trim(inMapFile) <> '';
  if not LoadJsonMapFile(inMapFile);
    outRtnCde = '1';
    return;
  endif;
endif;

// 2. Load Save File inventory via QSZRTVSO API and assign Precedence Tiers
if not LoadSaveFileInventory(inWrkLib: inWrkSavf);
  outRtnCde = '1';
  return;
endif;

if PkgItemCnt = 0;
  SendJobLogMsg('Save file ' + %trim(inWrkLib) + '/' + %trim(inWrkSavf)
                + ' contains no objects to unpack.');
  outRtnCde = '1';
  return;
endif;

// 3. Sort Package Items by Precedence Tier (10..80), Object Type, Object Name
SortPackageByPrecedence();

// 4. Verify all target libraries exist
if not ValidateTargetLibraries();
  outRtnCde = '1';
  return;
endif;

// 5. If Rollback Save File specified, backup existing objects before replacing
if %trim(inBkpSavf) <> '*NONE' and %trim(inBkpSavf) <> '';
  if not BackupExistingObjects(inBkpLib: inBkpSavf);
    outRtnCde = '1';
    return;
  endif;
endif;

// 6. Unpack all objects in Precedence Order
if not UnpackAllObjects();
  outRtnCde = '1';
  return;
endif;

// 7. Generate HTML Unpack Manifest Report in IFS (unless MANIFEST(*NONE))
if %trim(inManifest) <> '*NONE' and %trim(inManifest) <> '';
  outFullMnft = ResolveUnpackManifestPath(inManifest: inInpType: inStmf:
                                          inWrkLib: inWrkSavf);
  WriteUnpackHtmlManifest(outFullMnft);
endif;

SendJobLogMsg('Successfully unpacked ' + %char(PkgItemCnt)
              + ' objects in precedence order. Manifest: '
              + %trim(outFullMnft));
return;

// ============================================================================
// Procedure: ParseLibMap
// Description: Parses the IBM i CL mixed-list parameter buffer for LIBMAP.
//              Layout of CL mixed list (MAX > 1 of ELEM):
//              - Bytes 1..2: INT(5) EntryCount
//              - Next EntryCount * 2 bytes: INT(5) 0-based byte offsets
//              - At each offset: INT(5) SubElemCount (3) +
//                CHAR(10) ObjType + CHAR(10) ObjAttr + CHAR(10) TgtLib
// ============================================================================
dcl-proc ParseLibMap;
  dcl-pi *n;
    pBuf      char(1024) const;
    pRules    likeds(LibMapEntry_t) dim(200);
    pRuleCnt  int(10);
  end-pi;

  dcl-ds ListHeader qualified based(pHdrPtr);
    Count   int(5);
    Offsets int(5) dim(30);
  end-ds;

  dcl-ds ElemData qualified based(pElemPtr);
    SubCount int(5);
    ObjType  char(10);
    ObjAttr  char(10);
    TgtLib   char(10);
  end-ds;

  dcl-s LocalBuf char(1024);
  dcl-s idx int(10);

  pRuleCnt = 0;
  LocalBuf = pBuf;
  pHdrPtr = %addr(LocalBuf);

  if ListHeader.Count <= 0 or ListHeader.Count > 30;
    return;
  endif;

  // Check for single value SNGVAL((*NONE))
  if ListHeader.Count = 1 and %subst(LocalBuf: 3: 5) = '*NONE';
    return;
  endif;

  for idx = 1 to ListHeader.Count;
    if ListHeader.Offsets(idx) <= 0 or ListHeader.Offsets(idx) > 990;
      iter;
    endif;

    pElemPtr = %addr(LocalBuf) + ListHeader.Offsets(idx);
    if %trim(ElemData.ObjType) = '*NONE' or %trim(ElemData.TgtLib) = '';
      iter;
    endif;

    if pRuleCnt < %elem(pRules);
      pRuleCnt += 1;
      pRules(pRuleCnt).ObjName      = '*ALL';
      pRules(pRuleCnt).ObjType      = ElemData.ObjType;
      pRules(pRuleCnt).ObjAttr      = ElemData.ObjAttr;
      pRules(pRuleCnt).TgtLib       = ElemData.TgtLib;
      pRules(pRuleCnt).PreserveData = ' ';
    endif;
  endfor;
end-proc;

// ============================================================================
// Procedure: LoadJsonMapFile
// Description: Parses the JSON configuration file specified on MAPFILE using
//              Db2 for i JSON_TABLE and QSYS2.GET_CLOB_FROM_FILE.
//              Supports:
//              - "defaultLibrary": "PRODPGM"
//              - "defaultPreserveData": true | false
//              - "libraryMap": [
//                  { "objectName": "*ALL", "objectType": "*FILE",
//                    "objectAttribute": "PF", "targetLibrary": "PRODDTA",
//                    "preserveData": true }
//                ]
//              - "fileOverrides": [
//                  { "fileName": "SYSCFG", "targetLibrary": "PRODDTA",
//                    "preserveData": false }
//                ]
// ============================================================================
dcl-proc LoadJsonMapFile;
  dcl-pi *n ind;
    pMapFile char(256) const;
  end-pi;

  dcl-s JsonPath    varchar(256);
  dcl-s JsonDoc     varchar(32000) inz('');
  dcl-s LineStr     varchar(4096) inz('');
  dcl-s DftLibStr   varchar(10) inz('');
  dcl-s DftPresStr  varchar(10) inz('');
  dcl-s ObjNameStr  varchar(10) inz('');
  dcl-s ObjTypeStr  varchar(10) inz('');
  dcl-s ObjAttrStr  varchar(10) inz('');
  dcl-s TgtLibStr   varchar(10) inz('');
  dcl-s PresDataStr varchar(10) inz('');

  JsonPath = %trim(pMapFile);

  // 0. Read UTF-8 JSON file into memory without LOB locators (COMMIT(*NONE) safe)
  exec sql
    DECLARE ifs_json_csr CURSOR FOR
      SELECT COALESCE(CAST(LINE AS VARCHAR(4096)), '')
        FROM TABLE(QSYS2.IFS_READ_UTF8(PATH_NAME => :JsonPath));

  exec sql OPEN ifs_json_csr;
  if sqlcode < 0;
    SendJobLogMsg('Failed to open JSON MAPFILE at ' + JsonPath
                  + ' (SQLCODE ' + %char(sqlcode) + ')');
    return *off;
  endif;

  dow 1 = 1;
    exec sql FETCH NEXT FROM ifs_json_csr INTO :LineStr;
    if sqlcode <> 0;
      leave;
    endif;
    if %len(JsonDoc) + %len(LineStr) + 1 <= 32000;
      JsonDoc += LineStr + ' ';
    endif;
  enddo;
  exec sql CLOSE ifs_json_csr;

  if %trim(JsonDoc) = '';
    SendJobLogMsg('Failed to read or empty JSON MAPFILE at ' + JsonPath);
    return *off;
  endif;

  // 1. Parse top-level defaultLibrary and defaultPreserveData
  exec sql
    SELECT UPPER(TRIM(COALESCE(DFT_LIB, ''))),
           UPPER(TRIM(COALESCE(DFT_PRESERVE, '')))
      INTO :DftLibStr, :DftPresStr
      FROM JSON_TABLE(
             :JsonDoc,
             '$'
             COLUMNS(
               DFT_LIB      VARCHAR(10) PATH '$.defaultLibrary',
               DFT_PRESERVE VARCHAR(10) PATH '$.defaultPreserveData'
             )
           ) AS X
     FETCH FIRST 1 ROW ONLY;

  if sqlcode < 0;
    SendJobLogMsg('Failed to read or parse JSON MAPFILE at ' + JsonPath
                  + ' (SQLCODE ' + %char(sqlcode) + ')');
    return *off;
  endif;

  if DftLibStr <> '';
    JsonDftLib = DftLibStr;
  endif;
  JsonDftPreserve = NormalizePreserveFlag(DftPresStr);

  // 2. Parse $.libraryMap[*] array entries
  exec sql
    DECLARE json_map_csr CURSOR FOR
      SELECT UPPER(TRIM(COALESCE(OBJ_NAME, '*ALL'))),
             UPPER(TRIM(COALESCE(OBJ_TYPE, '*ALL'))),
             UPPER(TRIM(COALESCE(OBJ_ATTR, '*ALL'))),
             UPPER(TRIM(COALESCE(TGT_LIB, ''))),
             UPPER(TRIM(COALESCE(PRES_DATA, '')))
        FROM JSON_TABLE(
               :JsonDoc,
               '$.libraryMap[*]'
               COLUMNS(
                 OBJ_NAME  VARCHAR(10) PATH '$.objectName'
                           DEFAULT '*ALL' ON EMPTY,
                 OBJ_TYPE  VARCHAR(10) PATH '$.objectType'
                           DEFAULT '*ALL' ON EMPTY,
                 OBJ_ATTR  VARCHAR(10) PATH '$.objectAttribute'
                           DEFAULT '*ALL' ON EMPTY,
                 TGT_LIB   VARCHAR(10) PATH '$.targetLibrary',
                 PRES_DATA VARCHAR(10) PATH '$.preserveData'
               )
             ) AS M;

  exec sql OPEN json_map_csr;
  if sqlcode = 0;
    dow 1 = 1;
      exec sql FETCH NEXT FROM json_map_csr
                INTO :ObjNameStr, :ObjTypeStr, :ObjAttrStr,
                     :TgtLibStr, :PresDataStr;
      if sqlcode <> 0;
        leave;
      endif;

      if TgtLibStr <> '' and LibMapCount < %elem(LibMapRules);
        LibMapCount += 1;
        LibMapRules(LibMapCount).ObjName      = ObjNameStr;
        LibMapRules(LibMapCount).ObjType      = ObjTypeStr;
        LibMapRules(LibMapCount).ObjAttr      = ObjAttrStr;
        LibMapRules(LibMapCount).TgtLib       = TgtLibStr;
        LibMapRules(LibMapCount).PreserveData =
          NormalizePreserveFlag(PresDataStr);
      endif;
    enddo;
    exec sql CLOSE json_map_csr;
  endif;

  // 3. Parse $.fileOverrides[*] array entries for specific file names
  exec sql
    DECLARE json_ovr_csr CURSOR FOR
      SELECT UPPER(TRIM(COALESCE(FILE_NAME, ''))),
             UPPER(TRIM(COALESCE(TGT_LIB, ''))),
             UPPER(TRIM(COALESCE(PRES_DATA, '')))
        FROM JSON_TABLE(
               :JsonDoc,
               '$.fileOverrides[*]'
               COLUMNS(
                 FILE_NAME VARCHAR(10) PATH '$.fileName',
                 TGT_LIB   VARCHAR(10) PATH '$.targetLibrary',
                 PRES_DATA VARCHAR(10) PATH '$.preserveData'
               )
             ) AS F;

  exec sql OPEN json_ovr_csr;
  if sqlcode = 0;
    dow 1 = 1;
      exec sql FETCH NEXT FROM json_ovr_csr
                INTO :ObjNameStr, :TgtLibStr, :PresDataStr;
      if sqlcode <> 0;
        leave;
      endif;

      if ObjNameStr <> '' and FileOverrideCnt < %elem(FileOverrides);
        FileOverrideCnt += 1;
        FileOverrides(FileOverrideCnt).FileName = ObjNameStr;
        FileOverrides(FileOverrideCnt).TgtLib   = TgtLibStr;
        FileOverrides(FileOverrideCnt).PreserveData =
          NormalizePreserveFlag(PresDataStr);
      endif;
    enddo;
    exec sql CLOSE json_ovr_csr;
  endif;

  SendJobLogMsg('Loaded JSON mapping file ' + JsonPath + ' ('
                + %char(LibMapCount) + ' library rules, '
                + %char(FileOverrideCnt) + ' file overrides).');
  return *on;
end-proc;

// ============================================================================
// Procedure: NormalizePreserveFlag
// Description: Converts JSON boolean/string ('TRUE','*YES','Y','1' vs
//              'FALSE','*NO','N','0') to 'Y', 'N', or ' ' (unspecified).
// ============================================================================
dcl-proc NormalizePreserveFlag;
  dcl-pi *n char(1);
    pVal varchar(10) const;
  end-pi;

  dcl-s UpperVal varchar(10);

  UpperVal = %trim(pVal);
  if UpperVal = 'TRUE' or UpperVal = '*YES' or UpperVal = 'YES'
     or UpperVal = 'Y' or UpperVal = '1';
    return 'Y';
  elseif UpperVal = 'FALSE' or UpperVal = '*NO' or UpperVal = 'NO'
     or UpperVal = 'N' or UpperVal = '0';
    return 'N';
  endif;

  return ' ';
end-proc;

// ============================================================================
// Procedure: LoadSaveFileInventory
// Description: Calls QSZRTVSO (Format SAVI0200) into QTEMP/UNPKSPC user space
//              to read every object inside the package save file.
// ============================================================================
dcl-proc LoadSaveFileInventory;
  dcl-pi *n ind;
    pSavfLib char(10) const;
    pSavf    char(10) const;
  end-pi;

  dcl-c USRSPC_NAME 'UNPKSPC   QTEMP     ';
  dcl-ds ApiErr     likeds(ApiError_t) inz(*likeds);
  dcl-ds QualSavf   likeds(QualName_t);
  dcl-s  SpcPtr     pointer;
  dcl-ds SpcHdr     likeds(UsrSpcHeader_t) based(SpcPtr);
  dcl-s  EntryPtr   pointer;
  dcl-ds Entry      likeds(SAVI0200_t) based(EntryPtr);
  dcl-s  idx        int(10);

  PkgItemCnt = 0;

  // 1. Create User Space in QTEMP
  QUSCRTUS(USRSPC_NAME: 'UNPACK    ': 65536: x'00': '*ALL      ':
           'Save File Inventory for #UNPACK': '*YES      ': ApiErr);
  if ApiErr.BytesAvailable > 0;
    SendJobLogMsg('Failed to create user space QTEMP/UNPKSPC: '
                  + ApiErr.ExceptionId);
    return *off;
  endif;

  // 2. Retrieve Save File Object List (SAVF0200)
  QualSavf.Name = pSavf;
  QualSavf.Lib  = pSavfLib;

  QSRLSAVF(USRSPC_NAME: 'SAVF0200': QualSavf: '*ALL      ': '*ALL      ':
           *blanks: ApiErr);
  if ApiErr.BytesAvailable > 0;
    SendJobLogMsg('QSRLSAVF failed for save file ' + %trim(pSavfLib)
                  + '/' + %trim(pSavf) + ': ' + ApiErr.ExceptionId);
    QUSDLTUS(USRSPC_NAME: ApiErr);
    return *off;
  endif;

  // 3. Get Pointer to User Space and iterate through SAVI0200 entries
  QUSPTRUS(USRSPC_NAME: SpcPtr: ApiErr);
  if ApiErr.BytesAvailable > 0;
    SendJobLogMsg('QUSPTRUS failed for QTEMP/UNPKSPC: ' + ApiErr.ExceptionId);
    return *off;
  endif;

  for idx = 1 to SpcHdr.NumEntries;
    if PkgItemCnt >= %elem(PkgItems);
      leave;
    endif;

    EntryPtr = SpcPtr + SpcHdr.ListOffset + ((idx - 1) * SpcHdr.EntrySize);

    PkgItemCnt += 1;
    PkgItems(PkgItemCnt).ObjName   = Entry.ObjName;
    PkgItems(PkgItemCnt).SavedLib  = Entry.SavedLib;
    PkgItems(PkgItemCnt).ObjType   = Entry.ObjType;
    PkgItems(PkgItemCnt).ExtAttr   = Entry.ExtObjAttr;
    PkgItems(PkgItemCnt).DataSaved = Entry.DataSaved;
    PkgItems(PkgItemCnt).ObjSize   = Entry.ObjSize;
    PkgItems(PkgItemCnt).TextDesc  = Entry.TextDesc;
    PkgItems(PkgItemCnt).Version   = *blanks;

    // Resolve Target Library using FileOverrides, LIBMAP, or DFTLIB
    PkgItems(PkgItemCnt).TgtLib =
      ResolveTargetLibrary(Entry.ObjName: Entry.ObjType:
                           Entry.ExtObjAttr: Entry.SavedLib);

    // Resolve whether existing data should be preserved for this object
    PkgItems(PkgItemCnt).PreserveData =
      ResolvePreserveData(Entry.ObjName: Entry.ObjType: Entry.ExtObjAttr);

    // Compute Precedence Tier (10..80)
    PkgItems(PkgItemCnt).PrecTier =
      GetPrecedenceTier(Entry.ObjType: Entry.ExtObjAttr);

    // Check if object currently exists in Target Library
    PkgItems(PkgItemCnt).ExistsNow =
      CheckObjectExists(PkgItems(PkgItemCnt).TgtLib:
                        Entry.ObjName:
                        Entry.ObjType);
  endfor;

  // Clean up User Space
  QUSDLTUS(USRSPC_NAME: ApiErr);
  return *on;
end-proc;

// ============================================================================
// Procedure: GetPrecedenceTier
// Description: Assigns each IBM i object type & attribute to its dependency
//              precedence tier so objects unpack in the exact required order.
// ============================================================================
dcl-proc GetPrecedenceTier;
  dcl-pi *n int(10);
    pObjType char(10) const;
    pExtAttr char(10) const;
  end-pi;

  dcl-s TypeStr varchar(10);
  dcl-s AttrStr varchar(10);

  TypeStr = %trim(pObjType);
  AttrStr = %trim(pExtAttr);

  select;
    // Tier 10: System & Security Foundation
    when TypeStr = '*AUTL' or TypeStr = '*CLS'  or TypeStr = '*JOBD'
      or TypeStr = '*SBSD' or TypeStr = '*OUTQ' or TypeStr = '*WSCST';
      return TIER_ENV_FOUNDATION;

    // Tier 15: Message Files, Data Areas, Data Queues
    when TypeStr = '*MSGF' or TypeStr = '*DTAARA' or TypeStr = '*DTAQ';
      return TIER_DATA_CONTAINERS;

    // Tiers 20, 30, 40: *FILE objects classified by Extended Attribute
    when TypeStr = '*FILE';
      select;
        // Tier 40: Device Files (Display, Printer, ICF)
        when AttrStr = 'DSPF' or AttrStr = 'PRTF' or AttrStr = 'ICFF';
          return TIER_DEVICE_UI;

        // Tier 30: Logical Files, SQL Views, Indexes, MQTs
        when AttrStr = 'LF' or AttrStr = 'VW' or AttrStr = 'IX'
          or AttrStr = 'MQT' or %scan('LF': AttrStr) = 1;
          return TIER_LOGICAL_DATA;

        // Tier 20: Physical Files (PF, PF-DTA, PF-SRC) & SQL Tables (TB)
        other;
          return TIER_PHYSICAL_DATA;
      endsl;

    // Tier 40: UI Panel Groups & Menus
    when TypeStr = '*PNLGRP' or TypeStr = '*MENU';
      return TIER_DEVICE_UI;

    // Tier 50: Modules & Binding Directories
    when TypeStr = '*MODULE' or TypeStr = '*BNDDIR';
      return TIER_MODULES_BND;

    // Tier 60: Service Programs (depend on Modules/BndDirs/Files)
    when TypeStr = '*SRVPGM';
      return TIER_SRVPGM;

    // Tier 70: Programs & SQL Packages (depend on SrvPgms/Files/DataAreas)
    when TypeStr = '*PGM' or TypeStr = '*SQLPKG';
      return TIER_PROGRAMS;

    // Tier 80: Commands (depend on CPP *PGMs) & any remaining types
    other;
      return TIER_COMMANDS_OTHER;
  endsl;
end-proc;

// ============================================================================
// Procedure: ResolveTargetLibrary
// Description: Resolves the target library for an object using:
//              1. Per-file overrides from JSON "fileOverrides" (if *FILE)
//              2. LIBMAP rules (from command parameter and JSON "libraryMap")
//              3. JSON "defaultLibrary" or command DFTLIB (or SavedLib)
// ============================================================================
dcl-proc ResolveTargetLibrary;
  dcl-pi *n char(10);
    pObjName  char(10) const;
    pObjType  char(10) const;
    pExtAttr  char(10) const;
    pSavedLib char(10) const;
  end-pi;

  dcl-s idx       int(10);
  dcl-s RuleType  varchar(10);
  dcl-s RuleAttr  varchar(10);
  dcl-s TypeStr   varchar(10);
  dcl-s AttrStr   varchar(10);
  dcl-s NameMatch ind;
  dcl-s TypeMatch ind;
  dcl-s AttrMatch ind;

  TypeStr = %trim(pObjType);
  AttrStr = %trim(pExtAttr);

  // 1. Check explicit per-file overrides first (for *FILE objects)
  if TypeStr = '*FILE';
    for idx = 1 to FileOverrideCnt;
      if MatchesNamePattern(pObjName: FileOverrides(idx).FileName)
         and %trim(FileOverrides(idx).TgtLib) <> '';
        if %trim(FileOverrides(idx).TgtLib) = '*SAVLIB';
          return pSavedLib;
        endif;
        return FileOverrides(idx).TgtLib;
      endif;
    endfor;
  endif;

  // 2. Check LIBMAP rules (both command parameter & JSON libraryMap entries)
  for idx = 1 to LibMapCount;
    NameMatch = MatchesNamePattern(pObjName: LibMapRules(idx).ObjName);
    RuleType  = %trim(LibMapRules(idx).ObjType);
    RuleAttr  = %trim(LibMapRules(idx).ObjAttr);

    TypeMatch = (RuleType = '*ALL' or RuleType = '' or RuleType = TypeStr);

    AttrMatch = *off;
    if RuleAttr = '*ALL' or RuleAttr = '' or RuleAttr = AttrStr;
      AttrMatch = *on;
    elseif RuleAttr = 'PF'
       and (AttrStr = 'PF-DTA' or AttrStr = 'PF-SRC' or AttrStr = 'TB');
      AttrMatch = *on;
    elseif RuleAttr = 'LF'
       and (AttrStr = 'VW' or AttrStr = 'IX' or AttrStr = 'MQT');
      AttrMatch = *on;
    endif;

    if NameMatch and TypeMatch and AttrMatch;
      if %trim(LibMapRules(idx).TgtLib) = '*SAVLIB';
        return pSavedLib;
      endif;
      return LibMapRules(idx).TgtLib;
    endif;
  endfor;

  // 3. Check JSON defaultLibrary
  if %trim(JsonDftLib) <> '';
    if %trim(JsonDftLib) = '*SAVLIB';
      return pSavedLib;
    endif;
    return JsonDftLib;
  endif;

  // 4. Fall back to DFTLIB command parameter
  if %trim(inDftLib) = '*SAVLIB' or %trim(inDftLib) = '';
    return pSavedLib;
  endif;

  return inDftLib;
end-proc;

// ============================================================================
// Procedure: ResolvePreserveData
// Description: Determines whether existing Physical File / SQL Table data
//              should be preserved when replacing pObjName:
//              1. Checks JSON "fileOverrides" for a specific fileName match
//              2. Checks matching JSON "libraryMap" rule for preserveData
//              3. Checks JSON "defaultPreserveData"
//              4. Falls back to command parameter CPYDTA (*YES / *NO)
// ============================================================================
dcl-proc ResolvePreserveData;
  dcl-pi *n ind;
    pObjName char(10) const;
    pObjType char(10) const;
    pExtAttr char(10) const;
  end-pi;

  dcl-s idx       int(10);
  dcl-s RuleType  varchar(10);
  dcl-s RuleAttr  varchar(10);
  dcl-s TypeStr   varchar(10);
  dcl-s AttrStr   varchar(10);
  dcl-s NameMatch ind;
  dcl-s TypeMatch ind;
  dcl-s AttrMatch ind;

  TypeStr = %trim(pObjType);
  AttrStr = %trim(pExtAttr);

  // 1. Check explicit per-file overrides in JSON "fileOverrides"
  if TypeStr = '*FILE';
    for idx = 1 to FileOverrideCnt;
      if MatchesNamePattern(pObjName: FileOverrides(idx).FileName)
         and FileOverrides(idx).PreserveData <> ' ';
        return (FileOverrides(idx).PreserveData = 'Y');
      endif;
    endfor;
  endif;

  // 2. Check matching rule in LibMapRules if it specifies PreserveData
  for idx = 1 to LibMapCount;
    if LibMapRules(idx).PreserveData = ' ';
      iter;
    endif;

    NameMatch = MatchesNamePattern(pObjName: LibMapRules(idx).ObjName);
    RuleType  = %trim(LibMapRules(idx).ObjType);
    RuleAttr  = %trim(LibMapRules(idx).ObjAttr);

    TypeMatch = (RuleType = '*ALL' or RuleType = '' or RuleType = TypeStr);

    AttrMatch = *off;
    if RuleAttr = '*ALL' or RuleAttr = '' or RuleAttr = AttrStr;
      AttrMatch = *on;
    elseif RuleAttr = 'PF'
       and (AttrStr = 'PF-DTA' or AttrStr = 'PF-SRC' or AttrStr = 'TB');
      AttrMatch = *on;
    elseif RuleAttr = 'LF'
       and (AttrStr = 'VW' or AttrStr = 'IX' or AttrStr = 'MQT');
      AttrMatch = *on;
    endif;

    if NameMatch and TypeMatch and AttrMatch;
      return (LibMapRules(idx).PreserveData = 'Y');
    endif;
  endfor;

  // 3. Check JSON top-level defaultPreserveData
  if JsonDftPreserve <> ' ';
    return (JsonDftPreserve = 'Y');
  endif;

  // 4. Fall back to CPYDTA command parameter
  return (%trim(inCpyDta) = '*YES');
end-proc;

// ============================================================================
// Procedure: MatchesNamePattern
// Description: Matches an object name against '*ALL', an exact name, or a
//              generic prefix pattern ('ABC*').
// ============================================================================
dcl-proc MatchesNamePattern;
  dcl-pi *n ind;
    pObjName char(10) const;
    pPattern char(10) const;
  end-pi;

  dcl-s PatStr  varchar(10);
  dcl-s NameStr varchar(10);
  dcl-s StarPos int(10);
  dcl-s Prefix  varchar(10);

  PatStr  = %trim(pPattern);
  NameStr = %trim(pObjName);

  if PatStr = '' or PatStr = '*ALL' or PatStr = '*';
    return *on;
  endif;

  StarPos = %scan('*': PatStr);
  if StarPos > 0;
    Prefix = %subst(PatStr: 1: StarPos - 1);
    if %len(NameStr) >= %len(Prefix)
       and %subst(NameStr: 1: %len(Prefix)) = Prefix;
      return *on;
    endif;
    return *off;
  endif;

  return (NameStr = PatStr);
end-proc;

// ============================================================================
// Procedure: SortPackageByPrecedence
// Description: In-place insertion sort ordering PkgItems by:
//              1. PrecTier ASC (10 -> 80)
//              2. ObjType  ASC
//              3. ObjName  ASC
// ============================================================================
dcl-proc SortPackageByPrecedence;
  dcl-pi *n;
  end-pi;

  dcl-s  i       int(10);
  dcl-s  j       int(10);
  dcl-ds KeyItem likeds(PkgItem_t);

  for i = 2 to PkgItemCnt;
    KeyItem = PkgItems(i);
    j = i - 1;

    dow j >= 1 and ShouldSwap(PkgItems(j): KeyItem);
      PkgItems(j + 1) = PkgItems(j);
      j -= 1;
    enddo;

    PkgItems(j + 1) = KeyItem;
  endfor;
end-proc;

dcl-proc ShouldSwap;
  dcl-pi *n ind;
    pLeft  likeds(PkgItem_t) const;
    pRight likeds(PkgItem_t) const;
  end-pi;

  if pLeft.PrecTier <> pRight.PrecTier;
    return (pLeft.PrecTier > pRight.PrecTier);
  endif;
  if pLeft.ObjType <> pRight.ObjType;
    return (pLeft.ObjType > pRight.ObjType);
  endif;
  return (pLeft.ObjName > pRight.ObjName);
end-proc;

// ============================================================================
// Procedure: ValidateTargetLibraries
// Description: Verifies that every resolved target library exists on the system
// ============================================================================
dcl-proc ValidateTargetLibraries;
  dcl-pi *n ind;
  end-pi;

  dcl-s idx    int(10);
  dcl-s CmdStr varchar(256);

  for idx = 1 to PkgItemCnt;
    CmdStr = 'CHKOBJ OBJ(QSYS/' + %trim(PkgItems(idx).TgtLib)
           + ') OBJTYPE(*LIB)';
    if not RunClCommand(CmdStr);
      SendJobLogMsg('Target library ' + %trim(PkgItems(idx).TgtLib)
                    + ' does not exist.');
      return *off;
    endif;
  endfor;

  return *on;
end-proc;

// ============================================================================
// Procedure: BackupExistingObjects
// Description: Saves all existing target objects that will be replaced into
//              the Rollback Backup Save File before unpacking begins.
//              Supports both single-library and multi-library target mappings.
// ============================================================================
dcl-proc BackupExistingObjects;
  dcl-pi *n ind;
    pBkpLib  char(10) const;
    pBkpSavf char(10) const;
  end-pi;

  dcl-s UniqueLibs char(10) dim(30);
  dcl-s LibCnt     int(10) inz(0);
  dcl-s idx        int(10);
  dcl-s j          int(10);
  dcl-s Found      ind;
  dcl-s CurLib     char(10);
  dcl-s ObjNames   varchar(15000);
  dcl-s ObjCnt     int(10);
  dcl-s SubSavf    char(10);
  dcl-s CmdStr     varchar(32000);

  // Collect distinct target libraries that have at least one existing object
  for idx = 1 to PkgItemCnt;
    if not PkgItems(idx).ExistsNow;
      iter;
    endif;
    Found = *off;
    for j = 1 to LibCnt;
      if UniqueLibs(j) = PkgItems(idx).TgtLib;
        Found = *on;
        leave;
      endif;
    endfor;
    if not Found and LibCnt < %elem(UniqueLibs);
      LibCnt += 1;
      UniqueLibs(LibCnt) = PkgItems(idx).TgtLib;
    endif;
  endfor;

  if LibCnt = 0;
    SendJobLogMsg('No existing target objects need rollback backup.');
    return *on;
  endif;

  // If all replaced objects reside in a single target library, save directly
  if LibCnt = 1;
    CurLib = UniqueLibs(1);
    ObjNames = '';
    ObjCnt = 0;
    for idx = 1 to PkgItemCnt;
      if PkgItems(idx).ExistsNow and PkgItems(idx).TgtLib = CurLib;
        ObjNames += ' ' + %trim(PkgItems(idx).ObjName);
        ObjCnt += 1;
      endif;
    endfor;

    CmdStr = 'SAVOBJ OBJ(' + %trim(ObjNames) + ') '
           + 'LIB(' + %trim(CurLib) + ') '
           + 'DEV(*SAVF) OBJTYPE(*ALL) '
           + 'SAVF(' + %trim(pBkpLib) + '/' + %trim(pBkpSavf) + ') '
           + 'SAVACT(*LIB) ACCPTH(*YES) DTACPR(*MEDIUM)';
    if not RunClCommand(CmdStr);
      SendJobLogMsg('Failed to save existing objects from ' + %trim(CurLib)
                    + ' to rollback save file ' + %trim(pBkpLib) + '/'
                    + %trim(pBkpSavf));
      return *off;
    endif;
    SendJobLogMsg('Backed up ' + %char(ObjCnt) + ' existing objects from '
                  + %trim(CurLib) + ' to ' + %trim(pBkpLib) + '/'
                  + %trim(pBkpSavf));
    return *on;
  endif;

  // Multi-library target map: create per-library save files in pBkpLib
  // and also bundle them into pBkpLib/pBkpSavf
  for j = 1 to LibCnt;
    CurLib = UniqueLibs(j);
    SubSavf = 'BKP#' + %subst(%char(100000 + j): 2: 5);
    RunClCommand('DLTF FILE(QTEMP/' + %trim(SubSavf) + ')');
    RunClCommand('CRTSAVF FILE(QTEMP/' + %trim(SubSavf)
                 + ') TEXT(''Rollback for ' + %trim(CurLib) + ''')');

    ObjNames = '';
    for idx = 1 to PkgItemCnt;
      if PkgItems(idx).ExistsNow and PkgItems(idx).TgtLib = CurLib;
        ObjNames += ' ' + %trim(PkgItems(idx).ObjName);
      endif;
    endfor;

    CmdStr = 'SAVOBJ OBJ(' + %trim(ObjNames) + ') '
           + 'LIB(' + %trim(CurLib) + ') '
           + 'DEV(*SAVF) OBJTYPE(*ALL) '
           + 'SAVF(QTEMP/' + %trim(SubSavf) + ') '
           + 'SAVACT(*LIB) ACCPTH(*YES) DTACPR(*MEDIUM)';
    if not RunClCommand(CmdStr);
      SendJobLogMsg('Failed to backup library ' + %trim(CurLib));
      return *off;
    endif;
  endfor;

  // Save all QTEMP/BKP#* save files into the main rollback save file
  CmdStr = 'SAVOBJ OBJ(BKP#*) LIB(QTEMP) DEV(*SAVF) OBJTYPE(*FILE) '
         + 'SAVF(' + %trim(pBkpLib) + '/' + %trim(pBkpSavf) + ')';
  if not RunClCommand(CmdStr);
    SendJobLogMsg('Failed to bundle multi-library rollback into '
                  + %trim(pBkpLib) + '/' + %trim(pBkpSavf));
    return *off;
  endif;

  return *on;
end-proc;

// ============================================================================
// Procedure: UnpackAllObjects
// Description: Iterates through PkgItems (already sorted by Precedence Tier)
//              and unpacks each object into its resolved target library.
// ============================================================================
dcl-proc UnpackAllObjects;
  dcl-pi *n ind;
  end-pi;

  dcl-s idx int(10);

  for idx = 1 to PkgItemCnt;
    if not UnpackSingleObject(PkgItems(idx));
      return *off;
    endif;
    PkgItems(idx).Version =
      GetObjectUsrDfnAtr(PkgItems(idx).TgtLib:
                         PkgItems(idx).ObjName:
                         PkgItems(idx).ObjType);
  endfor;

  return *on;
end-proc;

// ============================================================================
// Procedure: UnpackSingleObject
// Description: Unpacks a single object from the package save file.
//              When replacing an existing object:
//              1. Captures all existing object authorities (Owner, PGP, AUTL,
//                 *PUBLIC, and all user private authorities)
//              2. If replacing a Physical File / SQL Table (Tier 20), handles
//                 dependent Logical Files and migrates existing table data
//                 via CPYF FMTOPT(*MAP *DROP)
//              3. Applies all existing authorities onto the newly unpacked
//                 object so security is 100% preserved
// ============================================================================
dcl-proc UnpackSingleObject;
  dcl-pi *n ind;
    pItem likeds(PkgItem_t) const;
  end-pi;

  dcl-s  ExistsNow   ind;
  dcl-ds AuthSnap    likeds(AuthSnapshot_t) inz(*likeds);
  dcl-s  TmpObjName  char(10);
  dcl-s  RenamedOk   ind inz(*off);
  dcl-s  IsPhysFile  ind inz(*off);
  dcl-s  HasDepLfs   ind inz(*off);
  dcl-s  CmdStr      varchar(32000);

  // Re-check existence right before unpacking (e.g., if a previous tier
  // removed a dependent LF)
  ExistsNow = CheckObjectExists(pItem.TgtLib: pItem.ObjName: pItem.ObjType);

  IsPhysFile = (pItem.PrecTier = TIER_PHYSICAL_DATA
                and %trim(pItem.ObjType) = '*FILE');

  // --------------------------------------------------------------------------
  // Case 1: Object does not currently exist in Target Library -> Direct RSTOBJ
  // --------------------------------------------------------------------------
  if not ExistsNow;
    CmdStr = 'RSTOBJ OBJ(' + %trim(pItem.ObjName) + ') '
           + 'SAVLIB(' + %trim(pItem.SavedLib) + ') '
           + 'DEV(*SAVF) '
           + 'OBJTYPE(' + %trim(pItem.ObjType) + ') '
           + 'SAVF(' + %trim(inWrkLib) + '/' + %trim(inWrkSavf) + ') '
           + 'RSTLIB(' + %trim(pItem.TgtLib) + ') '
           + 'MBROPT(*ALL) ALWOBJDIF(*ALL)';
    if not RunClCommand(CmdStr);
      SendJobLogMsg('RSTOBJ failed for new object ' + %trim(pItem.TgtLib)
                    + '/' + %trim(pItem.ObjName) + ' ('
                    + %trim(pItem.ObjType) + ')');
      return *off;
    endif;
    return *on;
  endif;

  // --------------------------------------------------------------------------
  // Case 2: Replacing an Existing Object in Target Library
  // --------------------------------------------------------------------------
  // 2a. Snapshot all existing authorities (Owner, PGP, AUTL, Private Auths)
  CaptureObjectAuthorities(pItem.TgtLib: pItem.ObjName: pItem.ObjType:
                           AuthSnap);

  // 2b. If replacing a Physical File / SQL Table, temporarily save and remove
  //     dependent Logical Files in TgtLib so PF rename/replace succeeds
  if IsPhysFile;
    HasDepLfs = SuspendDependentLfs(pItem.TgtLib: pItem.ObjName);
  endif;

  // 2c. Rename existing object to a temporary shadow name in TgtLib so we can
  //     use native GRTOBJAUT REFOBJ(...) and CPYF data migration
  SeqCounter += 1;
  TmpObjName = '#U' + %subst(%char(100000000 + SeqCounter): 2: 8);
  RunClCommand('DLTOBJ OBJ(' + %trim(pItem.TgtLib) + '/' + %trim(TmpObjName)
               + ') OBJTYPE(' + %trim(pItem.ObjType) + ')');

  if %trim(pItem.ObjType) = '*FILE';
    RunClCommand('ALCOBJ OBJ((' + %trim(pItem.TgtLib) + '/'
                 + %trim(pItem.ObjName) + ' *FILE *EXCL)) '
                 + 'WAIT(0) CONFLICT(*RQSRLS)');
    RunClCommand('DLCOBJ OBJ((' + %trim(pItem.TgtLib) + '/'
                 + %trim(pItem.ObjName) + ' *FILE *EXCL))');
  endif;

  CmdStr = 'RNMOBJ OBJ(' + %trim(pItem.TgtLib) + '/' + %trim(pItem.ObjName)
         + ') OBJTYPE(' + %trim(pItem.ObjType) + ') '
         + 'NEWOBJ(' + %trim(TmpObjName) + ')';
  RenamedOk = RunClCommand(CmdStr);

  // 2d. Restore the new object from the Package Save File
  CmdStr = 'RSTOBJ OBJ(' + %trim(pItem.ObjName) + ') '
         + 'SAVLIB(' + %trim(pItem.SavedLib) + ') '
         + 'DEV(*SAVF) '
         + 'OBJTYPE(' + %trim(pItem.ObjType) + ') '
         + 'SAVF(' + %trim(inWrkLib) + '/' + %trim(inWrkSavf) + ') '
         + 'RSTLIB(' + %trim(pItem.TgtLib) + ') '
         + 'MBROPT(*ALL) ALWOBJDIF(*ALL)';

  if not RunClCommand(CmdStr);
    SendJobLogMsg('RSTOBJ failed while replacing ' + %trim(pItem.TgtLib)
                  + '/' + %trim(pItem.ObjName) + ' ('
                  + %trim(pItem.ObjType) + ')');
    // Roll back shadow rename if it succeeded
    if RenamedOk;
      RunClCommand('RNMOBJ OBJ(' + %trim(pItem.TgtLib) + '/'
                   + %trim(TmpObjName) + ') OBJTYPE('
                   + %trim(pItem.ObjType) + ') NEWOBJ('
                   + %trim(pItem.ObjName) + ')');
    endif;
    return *off;
  endif;

  // 2e. Apply ALL Object Authorities from the existing object to the new one
  if RenamedOk;
    // Copy AUTL, Primary Group, *PUBLIC, and all private user authorities
    // directly from the renamed existing object via GRTOBJAUT REFOBJ
    CmdStr = 'GRTOBJAUT OBJ(' + %trim(pItem.TgtLib) + '/'
           + %trim(pItem.ObjName) + ') '
           + 'OBJTYPE(' + %trim(pItem.ObjType) + ') '
           + 'REFOBJ(' + %trim(pItem.TgtLib) + '/' + %trim(TmpObjName) + ') '
           + 'REFOBJTYPE(' + %trim(pItem.ObjType) + ')';
    RunClCommand(CmdStr);

    // Restore original Owner and re-sync REFOBJ authorities
    if %trim(AuthSnap.Owner) <> '';
      CmdStr = 'CHGOBJOWN OBJ(' + %trim(pItem.TgtLib) + '/'
             + %trim(pItem.ObjName) + ') '
             + 'OBJTYPE(' + %trim(pItem.ObjType) + ') '
             + 'NEWOWN(' + %trim(AuthSnap.Owner) + ') '
             + 'CUROWNAUT(*REVOKE)';
      RunClCommand(CmdStr);

      CmdStr = 'GRTOBJAUT OBJ(' + %trim(pItem.TgtLib) + '/'
             + %trim(pItem.ObjName) + ') '
             + 'OBJTYPE(' + %trim(pItem.ObjType) + ') '
             + 'REFOBJ(' + %trim(pItem.TgtLib) + '/' + %trim(TmpObjName) + ') '
             + 'REFOBJTYPE(' + %trim(pItem.ObjType) + ')';
      RunClCommand(CmdStr);
    endif;
  endif;

  // Replay captured QSYS2.OBJECT_PRIVILEGES snapshot as well to guarantee
  // complete fidelity even if RNMOBJ was skipped or restricted
  ApplyCapturedAuthorities(pItem.TgtLib: pItem.ObjName: pItem.ObjType:
                           AuthSnap);

  // 2f. If Physical File / SQL Table and PreserveData is enabled for this
  //     specific file (via fileOverrides, libraryMap, or CPYDTA), migrate
  //     existing target data into the newly unpacked file
  if IsPhysFile and RenamedOk and %trim(pItem.ExtAttr) <> 'PF-SRC';
    if pItem.PreserveData;
      CmdStr = 'CPYF FROMFILE(' + %trim(pItem.TgtLib) + '/'
             + %trim(TmpObjName) + ') '
             + 'TOFILE(' + %trim(pItem.TgtLib) + '/'
             + %trim(pItem.ObjName) + ') '
             + 'FROMMBR(*ALL) TOMBR(*FROMMBR) '
             + 'MBROPT(*REPLACE) FMTOPT(*MAP *DROP) ERRLVL(*NOMAX)';
      if not RunClCommand(CmdStr);
        SendJobLogMsg('Note: CPYF data migration returned warning/empty for '
                      + %trim(pItem.TgtLib) + '/' + %trim(pItem.ObjName));
      endif;
    else;
      SendJobLogMsg('Skipping existing data preservation for file '
                    + %trim(pItem.TgtLib) + '/' + %trim(pItem.ObjName)
                    + ' per preserveData=false configuration.');
    endif;
  endif;

  // 2g. Delete the temporary shadow copy of the old object
  if RenamedOk;
    if %trim(pItem.ObjType) = '*FILE';
      RunClCommand('DLTF FILE(' + %trim(pItem.TgtLib) + '/'
                   + %trim(TmpObjName) + ')');
    else;
      RunClCommand('DLTOBJ OBJ(' + %trim(pItem.TgtLib) + '/'
                   + %trim(TmpObjName) + ') OBJTYPE('
                   + %trim(pItem.ObjType) + ')');
    endif;
  endif;

  // 2h. Restore any un-packaged dependent Logical Files that were suspended
  if IsPhysFile and HasDepLfs;
    RestoreSuspendedLfs(pItem.TgtLib);
  endif;

  return *on;
end-proc;

// ============================================================================
// Procedure: CaptureObjectAuthorities
// Description: Queries QSYS2.OBJECT_STATISTICS and QSYS2.OBJECT_PRIVILEGES to
//              record the existing object's Owner, PGP, AUTL, and every user's
//              explicit authority settings before replacement.
// ============================================================================
dcl-proc CaptureObjectAuthorities;
  dcl-pi *n;
    pLib      char(10) const;
    pObj      char(10) const;
    pType     char(10) const;
    pAuthSnap likeds(AuthSnapshot_t);
  end-pi;

  dcl-s OwnerStr   varchar(10) inz('');
  dcl-s PgpStr     varchar(10) inz('');
  dcl-s AutlStr    varchar(10) inz('');
  dcl-s UsrPrf     char(10);
  dcl-s ObjAut     varchar(128);
  dcl-s ObjOper    char(3);
  dcl-s ObjMgt     char(3);
  dcl-s ObjExist   char(3);
  dcl-s ObjAlter   char(3);
  dcl-s ObjRef     char(3);
  dcl-s DataRead   char(3);
  dcl-s DataAdd    char(3);
  dcl-s DataUpd    char(3);
  dcl-s DataDlt    char(3);
  dcl-s DataExec   char(3);

  clear pAuthSnap;

  // 1. Retrieve Owner, Primary Group, and Authorization List
  exec sql
    SELECT COALESCE(OWNER, ''),
           COALESCE(PRIMARY_GROUP, '*NONE'),
           COALESCE(AUTHORIZATION_LIST, '*NONE')
      INTO :OwnerStr, :PgpStr, :AutlStr
      FROM QSYS2.OBJECT_PRIVILEGES
     WHERE SYSTEM_OBJECT_SCHEMA = :pLib
       AND SYSTEM_OBJECT_NAME   = :pObj
       AND OBJECT_TYPE          = :pType
     FETCH FIRST 1 ROW ONLY;

  if sqlcode = 0;
    pAuthSnap.Owner = OwnerStr;
    pAuthSnap.Pgp   = PgpStr;
    pAuthSnap.Autl  = AutlStr;
  endif;

  // 2. Retrieve all Private & *PUBLIC Authorities from QSYS2.OBJECT_PRIVILEGES
  exec sql
    DECLARE priv_csr CURSOR FOR
      SELECT COALESCE(AUTHORIZATION_NAME, ''),
             COALESCE(OBJECT_AUTHORITY, ''),
             COALESCE(OBJECT_OPERATIONAL, 'NO'),
             COALESCE(OBJECT_MANAGEMENT, 'NO'),
             COALESCE(OBJECT_EXISTENCE, 'NO'),
             COALESCE(OBJECT_ALTER, 'NO'),
             COALESCE(OBJECT_REFERENCE, 'NO'),
             COALESCE(DATA_READ, 'NO'),
             COALESCE(DATA_ADD, 'NO'),
             COALESCE(DATA_UPDATE, 'NO'),
             COALESCE(DATA_DELETE, 'NO'),
             COALESCE(DATA_EXECUTE, 'NO')
        FROM QSYS2.OBJECT_PRIVILEGES
       WHERE SYSTEM_OBJECT_SCHEMA = :pLib
         AND SYSTEM_OBJECT_NAME   = :pObj
         AND OBJECT_TYPE          = :pType;

  exec sql OPEN priv_csr;
  if sqlcode < 0;
    return;
  endif;

  dow 1 = 1;
    exec sql FETCH NEXT FROM priv_csr
              INTO :UsrPrf, :ObjAut, :ObjOper, :ObjMgt, :ObjExist,
                   :ObjAlter, :ObjRef, :DataRead, :DataAdd, :DataUpd,
                   :DataDlt, :DataExec;
    if sqlcode <> 0;
      leave;
    endif;

    if pAuthSnap.PrivCount < %elem(pAuthSnap.Privs);
      pAuthSnap.PrivCount += 1;
      pAuthSnap.Privs(pAuthSnap.PrivCount).UserName = UsrPrf;
      pAuthSnap.Privs(pAuthSnap.PrivCount).ObjAut   = ObjAut;
      pAuthSnap.Privs(pAuthSnap.PrivCount).ObjOper  = ObjOper;
      pAuthSnap.Privs(pAuthSnap.PrivCount).ObjMgt   = ObjMgt;
      pAuthSnap.Privs(pAuthSnap.PrivCount).ObjExist = ObjExist;
      pAuthSnap.Privs(pAuthSnap.PrivCount).ObjAlter = ObjAlter;
      pAuthSnap.Privs(pAuthSnap.PrivCount).ObjRef   = ObjRef;
      pAuthSnap.Privs(pAuthSnap.PrivCount).DataRead = DataRead;
      pAuthSnap.Privs(pAuthSnap.PrivCount).DataAdd  = DataAdd;
      pAuthSnap.Privs(pAuthSnap.PrivCount).DataUpd  = DataUpd;
      pAuthSnap.Privs(pAuthSnap.PrivCount).DataDlt  = DataDlt;
      pAuthSnap.Privs(pAuthSnap.PrivCount).DataExec = DataExec;
    endif;
  enddo;

  exec sql CLOSE priv_csr;
end-proc;

// ============================================================================
// Procedure: ApplyCapturedAuthorities
// Description: Re-applies Owner, Primary Group, Authorization List, and all
//              per-user authorities captured in pAuthSnap onto the newly
//              unpacked object.
// ============================================================================
dcl-proc ApplyCapturedAuthorities;
  dcl-pi *n;
    pLib      char(10) const;
    pObj      char(10) const;
    pType     char(10) const;
    pAuthSnap likeds(AuthSnapshot_t) const;
  end-pi;

  dcl-s idx     int(10);
  dcl-s AutList varchar(256);
  dcl-s CmdStr  varchar(2048);

  // 1. Restore Owner
  if %trim(pAuthSnap.Owner) <> '';
    CmdStr = 'CHGOBJOWN OBJ(' + %trim(pLib) + '/' + %trim(pObj) + ') '
           + 'OBJTYPE(' + %trim(pType) + ') '
           + 'NEWOWN(' + %trim(pAuthSnap.Owner) + ') '
           + 'CUROWNAUT(*REVOKE)';
    RunClCommand(CmdStr);
  endif;

  // 2. Restore Primary Group
  if %trim(pAuthSnap.Pgp) <> '' and %trim(pAuthSnap.Pgp) <> '*NONE';
    CmdStr = 'CHGPGP OBJ(' + %trim(pLib) + '/' + %trim(pObj) + ') '
           + 'OBJTYPE(' + %trim(pType) + ') '
           + 'NEWPGP(' + %trim(pAuthSnap.Pgp) + ')';
    RunClCommand(CmdStr);
  endif;

  // 3. Restore Authorization List
  if %trim(pAuthSnap.Autl) <> '' and %trim(pAuthSnap.Autl) <> '*NONE';
    CmdStr = 'GRTOBJAUT OBJ(' + %trim(pLib) + '/' + %trim(pObj) + ') '
           + 'OBJTYPE(' + %trim(pType) + ') '
           + 'AUTL(' + %trim(pAuthSnap.Autl) + ')';
    RunClCommand(CmdStr);
  endif;

  // 4. Restore each user's (and *PUBLIC's) explicit authorities
  for idx = 1 to pAuthSnap.PrivCount;
    if %trim(pAuthSnap.Privs(idx).UserName) = '';
      iter;
    endif;

    AutList = BuildGrtobjautList(pAuthSnap.Privs(idx));
    if AutList <> '';
      CmdStr = 'GRTOBJAUT OBJ(' + %trim(pLib) + '/' + %trim(pObj) + ') '
             + 'OBJTYPE(' + %trim(pType) + ') '
             + 'USER(' + %trim(pAuthSnap.Privs(idx).UserName) + ') '
             + 'AUT(' + AutList + ') REPLACE(*YES)';
      RunClCommand(CmdStr);
    endif;
  endfor;
end-proc;

// ============================================================================
// Procedure: BuildGrtobjautList
// Description: Formats the AUT(...) token list for GRTOBJAUT from a captured
//              QSYS2.OBJECT_PRIVILEGES row.
// ============================================================================
dcl-proc BuildGrtobjautList;
  dcl-pi *n varchar(256);
    pPriv likeds(PrivEntry_t) const;
  end-pi;

  dcl-s AutStr varchar(256) inz('');

  if %trim(pPriv.ObjAut) = '*ALL' or %trim(pPriv.ObjAut) = '*CHANGE'
     or %trim(pPriv.ObjAut) = '*USE' or %trim(pPriv.ObjAut) = '*EXCLUDE';
    return %trim(pPriv.ObjAut);
  endif;

  if %trim(pPriv.ObjOper) = 'YES';
    AutStr += ' *OBJOPR';
  endif;
  if %trim(pPriv.ObjMgt) = 'YES';
    AutStr += ' *OBJMGT';
  endif;
  if %trim(pPriv.ObjExist) = 'YES';
    AutStr += ' *OBJEXIST';
  endif;
  if %trim(pPriv.ObjAlter) = 'YES';
    AutStr += ' *OBJALTER';
  endif;
  if %trim(pPriv.ObjRef) = 'YES';
    AutStr += ' *OBJREF';
  endif;
  if %trim(pPriv.DataRead) = 'YES';
    AutStr += ' *READ';
  endif;
  if %trim(pPriv.DataAdd) = 'YES';
    AutStr += ' *ADD';
  endif;
  if %trim(pPriv.DataUpd) = 'YES';
    AutStr += ' *UPD';
  endif;
  if %trim(pPriv.DataDlt) = 'YES';
    AutStr += ' *DLT';
  endif;
  if %trim(pPriv.DataExec) = 'YES';
    AutStr += ' *EXECUTE';
  endif;

  if AutStr = '';
    return '*EXCLUDE';
  endif;

  return %trim(AutStr);
end-proc;

// ============================================================================
// Procedure: SuspendDependentLfs
// Description: Finds any Logical Files / Views / Indexes in pTgtLib that
//              depend on Physical File pPfName using DSPDBR Outfile.
//              - If a dependent LF is NOT in the current package, saves it to
//                QTEMP/DEPLFSAVF so it can be restored after the PF is updated.
//              - Deletes the dependent LF from pTgtLib so the PF can be
//                cleanly renamed, replaced, and data-copied.
// ============================================================================
dcl-proc SuspendDependentLfs;
  dcl-pi *n ind;
    pTgtLib char(10) const;
    pPfName char(10) const;
  end-pi;

  dcl-s DepFile   char(10);
  dcl-s DepLib    char(10);
  dcl-s SavedObjs varchar(4000) inz('');
  dcl-s SavedCnt  int(10) inz(0);
  dcl-s CmdStr    varchar(4096);

  RunClCommand('ALCOBJ OBJ((QTEMP/DBROUT *FILE *EXCL)) WAIT(0) CONFLICT(*RQSRLS)');
  RunClCommand('DLCOBJ OBJ((QTEMP/DBROUT *FILE *EXCL))');
  CmdStr = 'DSPDBR FILE(' + %trim(pTgtLib) + '/' + %trim(pPfName) + ') '
         + 'OUTPUT(*OUTFILE) OUTFILE(QTEMP/DBROUT) OUTMBR(*FIRST *REPLACE)';
  if not RunClCommand(CmdStr);
    return *off;
  endif;

  exec sql
    DECLARE dbr_csr CURSOR FOR
      SELECT WHREFI, WHRELI
        FROM QTEMP.DBROUT
       WHERE WHREFI <> ''
         AND WHRELI = :pTgtLib;

  exec sql OPEN dbr_csr;
  if sqlcode < 0;
    return *off;
  endif;

  dow 1 = 1;
    exec sql FETCH NEXT FROM dbr_csr INTO :DepFile, :DepLib;
    if sqlcode <> 0;
      leave;
    endif;

    if not CheckObjectExists(DepLib: DepFile: '*FILE');
      iter;
    endif;

    // If this dependent LF is NOT part of the package (which will unpack in
    // Tier 30), add it to the list to save into QTEMP/DEPLFSAVF
    if not IsObjectInPackage(DepLib: DepFile: '*FILE');
      SavedObjs += ' ' + %trim(DepFile);
      SavedCnt += 1;
    endif;
  enddo;

  exec sql CLOSE dbr_csr;

  if SavedCnt > 0;
    RunClCommand('DLTF FILE(QTEMP/DEPLFSAVF)');
    RunClCommand('CRTSAVF FILE(QTEMP/DEPLFSAVF) TEXT(''Suspended LFs'')');
    CmdStr = 'SAVOBJ OBJ(' + %trim(SavedObjs) + ') '
           + 'LIB(' + %trim(pTgtLib) + ') DEV(*SAVF) OBJTYPE(*FILE) '
           + 'SAVF(QTEMP/DEPLFSAVF) ACCPTH(*YES)';
    RunClCommand(CmdStr);
  endif;

  // Delete all dependent LFs in pTgtLib so the PF can be replaced cleanly
  exec sql OPEN dbr_csr;
  dow 1 = 1;
    exec sql FETCH NEXT FROM dbr_csr INTO :DepFile, :DepLib;
    if sqlcode <> 0;
      leave;
    endif;
    RunClCommand('DLTF FILE(' + %trim(DepLib) + '/' + %trim(DepFile) + ')');
  enddo;
  exec sql CLOSE dbr_csr;

  return (SavedCnt > 0);
end-proc;

// ============================================================================
// Procedure: RestoreSuspendedLfs
// Description: Restores any un-packaged dependent Logical Files that were
//              saved into QTEMP/DEPLFSAVF before the PF was replaced.
// ============================================================================
dcl-proc RestoreSuspendedLfs;
  dcl-pi *n;
    pTgtLib char(10) const;
  end-pi;

  dcl-s CmdStr varchar(1024);

  CmdStr = 'RSTOBJ OBJ(*ALL) SAVLIB(' + %trim(pTgtLib) + ') '
         + 'DEV(*SAVF) OBJTYPE(*FILE) SAVF(QTEMP/DEPLFSAVF) '
         + 'RSTLIB(' + %trim(pTgtLib) + ') MBROPT(*ALL) ALWOBJDIF(*ALL)';
  RunClCommand(CmdStr);
  RunClCommand('DLTF FILE(QTEMP/DEPLFSAVF)');
end-proc;

// ============================================================================
// Procedure: IsObjectInPackage
// Description: Checks whether (pTgtLib, pObjName, pObjType) is included in
//              the current package's unpack list.
// ============================================================================
dcl-proc IsObjectInPackage;
  dcl-pi *n ind;
    pTgtLib  char(10) const;
    pObjName char(10) const;
    pObjType char(10) const;
  end-pi;

  dcl-s idx int(10);

  for idx = 1 to PkgItemCnt;
    if PkgItems(idx).TgtLib = pTgtLib
       and PkgItems(idx).ObjName = pObjName
       and PkgItems(idx).ObjType = pObjType;
      return *on;
    endif;
  endfor;

  return *off;
end-proc;

// ============================================================================
// Procedure: CheckObjectExists
// Description: Returns *ON if pLib/pObj (pType) exists on the system
// ============================================================================
dcl-proc CheckObjectExists;
  dcl-pi *n ind;
    pLib  char(10) const;
    pObj  char(10) const;
    pType char(10) const;
  end-pi;

  dcl-s CmdStr varchar(256);

  CmdStr = 'CHKOBJ OBJ(' + %trim(pLib) + '/' + %trim(pObj)
         + ') OBJTYPE(' + %trim(pType) + ')';
  return RunClCommand(CmdStr);
end-proc;

// ============================================================================
// Procedure: RunClCommand
// Description: Executes a CL command via QCMDEXC with error monitoring
// ============================================================================
dcl-proc RunClCommand;
  dcl-pi *n ind;
    pCmd varchar(32000) const;
  end-pi;

  monitor;
    QCMDEXC(pCmd: %len(pCmd));
    return *on;
  on-error;
    return *off;
  endmon;
end-proc;

// ============================================================================
// Procedure: SendJobLogMsg
// Description: Writes an informational/diagnostic message to the job log
// ============================================================================
dcl-proc SendJobLogMsg;
  dcl-pi *n;
    pText varchar(512) const;
  end-pi;

  dcl-s  MsgKey  char(4) inz(*blanks);
  dcl-ds ApiErr  likeds(ApiError_t) inz(*likeds);
  dcl-s  MsgBuf  char(512);

  MsgBuf = pText;
  QMHSNDPM('CPF9897': 'QCPFMSG   *LIBL     ': MsgBuf: %len(pText):
           '*DIAG     ': '*         ': 1: MsgKey: ApiErr);
end-proc;

// ============================================================================
// Procedure: ResolveUnpackManifestPath
// Description: Resolves the IFS path for the #UNPACK HTML manifest report.
// ============================================================================
dcl-proc ResolveUnpackManifestPath;
  dcl-pi *n char(256);
    pManifest char(256) const;
    pInpType  char(6)   const;
    pStmf     char(256) const;
    pSavfLib  char(10)  const;
    pSavf     char(10)  const;
  end-pi;

  dcl-s MnftStr varchar(256);
  dcl-s StmfStr varchar(256);
  dcl-s DotPos  int(10);

  MnftStr = %trim(pManifest);

  if MnftStr = '*AUTO' or MnftStr = '';
    if %trim(pInpType) = '*STMF' and %trim(pStmf) <> ''
       and %trim(pStmf) <> '*NONE';
      StmfStr = %trim(pStmf);
      DotPos = %scanr('.': StmfStr);
      if DotPos > 1;
        return %subst(StmfStr: 1: DotPos - 1) + '_unpack_manifest.html';
      else;
        return StmfStr + '_unpack_manifest.html';
      endif;
    else;
      return '/tmp/unpack_' + %trim(pSavfLib) + '_' + %trim(pSavf)
           + '_manifest.html';
    endif;
  endif;

  if %subst(MnftStr: %len(MnftStr): 1) = '/';
    return MnftStr + 'unpack_' + %trim(pSavfLib) + '_' + %trim(pSavf)
         + '_manifest.html';
  endif;

  return MnftStr;
end-proc;

// ============================================================================
// Procedure: WriteUnpackHtmlManifest
// Description: Generates a styled, downloadable HTML5 Unpack Manifest Report
//              in the IFS detailing the Package Version, source package,
//              target libraries, precedence order, replacement actions,
//              authority preservation, and PF/Table data migration policy.
// ============================================================================
dcl-proc WriteUnpackHtmlManifest;
  dcl-pi *n;
    pMnftPath char(256) const;
  end-pi;

  dcl-s PathStr     varchar(256);
  dcl-s HtmlChunk   varchar(16384);
  dcl-s PkgVer      varchar(10) inz('N/A');
  dcl-s SrcLabel    varchar(256);
  dcl-s MapLabel    varchar(256);
  dcl-s BkpLabel    varchar(64);
  dcl-s GenTime     varchar(32);
  dcl-s ReplacedCnt int(10) inz(0);
  dcl-s CreatedCnt  int(10) inz(0);
  dcl-s idx         int(10);
  dcl-s ActionBadge varchar(128);
  dcl-s AuthBadge   varchar(128);
  dcl-s DataBadge   varchar(128);
  dcl-s TierBadge   varchar(64);

  PathStr = %trim(pMnftPath);
  GenTime = %char(%timestamp());

  if %trim(inInpType) = '*STMF';
    SrcLabel = 'IFS Stream File: ' + %trim(inStmf);
  else;
    SrcLabel = 'QSYS Save File: ' + %trim(inWrkLib) + '/' + %trim(inWrkSavf);
  endif;

  if %trim(inMapFile) <> '*NONE' and %trim(inMapFile) <> '';
    MapLabel = %trim(inMapFile);
  else;
    MapLabel = 'Inline LIBMAP / DFTLIB(' + %trim(inDftLib) + ')';
  endif;

  if %trim(inBkpSavf) <> '*NONE' and %trim(inBkpSavf) <> '';
    BkpLabel = %trim(inBkpLib) + '/' + %trim(inBkpSavf);
  else;
    BkpLabel = '*NONE';
  endif;

  // Determine Package Version (from first stamped object or save file)
  PkgVer = %trim(GetObjectUsrDfnAtr(inWrkLib: inWrkSavf: '*FILE'));
  for idx = 1 to PkgItemCnt;
    if PkgVer = '' or PkgVer = 'N/A';
      if %trim(PkgItems(idx).Version) <> '';
        PkgVer = %trim(PkgItems(idx).Version);
      endif;
    endif;
    if PkgItems(idx).ExistsNow;
      ReplacedCnt += 1;
    else;
      CreatedCnt += 1;
    endif;
  endfor;
  if PkgVer = '';
    PkgVer = 'N/A';
  endif;

  // 1. Write HTML5 Document Header, Stylesheet, and Top Version Hero Banner
  HtmlChunk =
    '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">'
  + '<meta name="viewport" content="width=device-width,initial-scale=1.0">'
  + '<title>IBM i Unpack Deployment Report - Version ' + HtmlEscape(PkgVer)
  + '</title><style>'
  + ':root{--bg:#0f172a;--card:#1e293b;--border:#334155;--text:#f8fafc;'
  + '--muted:#94a3b8;--accent:#38bdf8;--ok:#22c55e;--warn:#f59e0b;}'
  + '*{box-sizing:border-box;margin:0;padding:0;}'
  + 'body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,'
  + 'sans-serif;background:var(--bg);color:var(--text);padding:2rem;line-height:1.5;}'
  + '.container{max-width:1380px;margin:0 auto;}'
  + '.hero{background:linear-gradient(135deg,#0f766e 0%,#1e3a8a 100%);'
  + 'border-radius:12px;padding:1.75rem 2rem;margin-bottom:1.5rem;'
  + 'display:flex;justify-content:space-between;align-items:center;'
  + 'flex-wrap:wrap;gap:1rem;box-shadow:0 10px 25px rgba(0,0,0,0.3);}'
  + '.hero h1{font-size:1.6rem;font-weight:700;letter-spacing:-0.02em;}'
  + '.hero .subtitle{color:#ccfbf1;font-size:0.95rem;margin-top:0.25rem;}'
  + '.ver-pill{background:rgba(15,23,42,0.75);border:2px solid #5eead4;'
  + 'padding:0.75rem 1.25rem;border-radius:10px;text-align:right;}'
  + '.ver-pill .lbl{font-size:0.75rem;text-transform:uppercase;'
  + 'letter-spacing:0.08em;color:#99f6e4;display:block;}'
  + '.ver-pill .val{font-size:1.5rem;font-weight:800;font-family:monospace;'
  + 'color:#ffffff;}'
  + '.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));'
  + 'gap:1rem;margin-bottom:1.5rem;}'
  + '.card{background:var(--card);border:1px solid var(--border);'
  + 'border-radius:10px;padding:1rem 1.25rem;}'
  + '.card .k{font-size:0.75rem;text-transform:uppercase;color:var(--muted);'
  + 'letter-spacing:0.05em;}'
  + '.card .v{font-size:1.05rem;font-weight:600;margin-top:0.25rem;'
  + 'word-break:break-all;}'
  + '.toolbar{display:flex;justify-content:space-between;align-items:center;'
  + 'margin-bottom:1rem;gap:1rem;flex-wrap:wrap;}'
  + '.search{background:var(--card);border:1px solid var(--border);'
  + 'color:var(--text);padding:0.6rem 1rem;border-radius:8px;width:340px;'
  + 'font-size:0.9rem;}'
  + '.table-wrap{background:var(--card);border:1px solid var(--border);'
  + 'border-radius:12px;overflow:x-auto;}'
  + 'table{width:100%;border-collapse:collapse;text-align:left;}'
  + 'th{background:#0f172a;color:var(--muted);font-size:0.75rem;'
  + 'text-transform:uppercase;letter-spacing:0.06em;padding:0.85rem 0.9rem;'
  + 'border-bottom:1px solid var(--border);}'
  + 'td{padding:0.7rem 0.9rem;border-bottom:1px solid rgba(51,65,85,0.6);'
  + 'font-size:0.86rem;}'
  + 'tr:hover td{background:rgba(56,189,248,0.06);}'
  + '.mono{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;'
  + 'font-weight:600;}'
  + '.badge{display:inline-block;padding:0.18rem 0.5rem;border-radius:6px;'
  + 'font-size:0.75rem;font-weight:600;font-family:monospace;'
  + 'background:rgba(56,189,248,0.15);color:#38bdf8;'
  + 'border:1px solid rgba(56,189,248,0.3);}'
  + '.b-ok{background:rgba(34,197,94,0.15);color:#4ade80;'
  + 'border:1px solid rgba(34,197,94,0.3);}'
  + '.b-warn{background:rgba(245,158,11,0.15);color:#fbbf24;'
  + 'border:1px solid rgba(245,158,11,0.3);}'
  + '.b-tier{background:rgba(168,85,247,0.15);color:#c084fc;'
  + 'border:1px solid rgba(168,85,247,0.3);}'
  + '</style></head><body><div class="container">'
  + '<div class="hero"><div><h1>IBM i CI/CD Unpack Deployment Report (#UNPACK)</h1>'
  + '<div class="subtitle">' + HtmlEscape(SrcLabel) + '</div></div>'
  + '<div class="ver-pill"><span class="lbl">Package Version (USRDFNATR)</span>'
  + '<span class="val">' + HtmlEscape(PkgVer) + '</span></div></div>'
  + '<div class="cards">'
  + '<div class="card"><div class="k">Package Version</div>'
  + '<div class="v mono">' + HtmlEscape(PkgVer) + '</div></div>'
  + '<div class="card"><div class="k">Total Unpacked</div>'
  + '<div class="v">' + %char(PkgItemCnt) + ' (' + %char(ReplacedCnt)
  + ' replaced, ' + %char(CreatedCnt) + ' new)</div></div>'
  + '<div class="card"><div class="k">Library Mapping</div>'
  + '<div class="v">' + HtmlEscape(MapLabel) + '</div></div>'
  + '<div class="card"><div class="k">Rollback Save File</div>'
  + '<div class="v mono">' + HtmlEscape(BkpLabel) + '</div></div>'
  + '<div class="card"><div class="k">Completed Timestamp</div>'
  + '<div class="v">' + HtmlEscape(GenTime) + '</div></div>'
  + '</div>'
  + '<div class="toolbar"><h2>Unpacked Objects (Precedence Order)</h2>'
  + '<input type="text" id="q" class="search" '
  + 'placeholder="Filter by library, object, type, or tier..." '
  + 'onkeyup="filterRows()"></div>'
  + '<div class="table-wrap"><table id="tbl"><thead><tr>'
  + '<th>Order</th><th>Precedence Tier</th><th>Saved Lib</th>'
  + '<th>Target Lib</th><th>Object Name</th><th>Type</th><th>Attr</th>'
  + '<th>Version</th><th>Action</th><th>Authorities</th>'
  + '<th>Data Policy</th><th>Description</th>'
  + '</tr></thead><tbody>';

  exec sql
    CALL QSYS2.IFS_WRITE_UTF8(
           PATH_NAME   => :PathStr,
           LINE        => :HtmlChunk,
           OVERWRITE   => 'REPLACE',
           END_OF_LINE => 'LF');

  // 2. Write Precedence-Ordered Rows
  HtmlChunk = '';
  for idx = 1 to PkgItemCnt;
    TierBadge = GetTierLabel(PkgItems(idx).PrecTier);

    if PkgItems(idx).ExistsNow;
      ActionBadge = '<span class="badge b-warn">Replaced Existing</span>';
      AuthBadge   = 'Preserved Existing Auths';
    else;
      ActionBadge = '<span class="badge b-ok">Created New</span>';
      AuthBadge   = 'From Package';
    endif;

    if PkgItems(idx).PrecTier = TIER_PHYSICAL_DATA
       and %trim(PkgItems(idx).ObjType) = '*FILE'
       and %trim(PkgItems(idx).ExtAttr) <> 'PF-SRC';
      if not PkgItems(idx).ExistsNow;
        DataBadge = 'New Table / File';
      elseif PkgItems(idx).PreserveData;
        DataBadge = '<span class="badge b-ok">Preserved Data (*MAP *DROP)</span>';
      else;
        DataBadge = '<span class="badge b-warn">Overridden (Seed Data)</span>';
      endif;
    else;
      DataBadge = '-';
    endif;

    HtmlChunk +=
      '<tr>'
    + '<td>' + %char(idx) + '</td>'
    + '<td><span class="badge b-tier">' + HtmlEscape(TierBadge) + '</span></td>'
    + '<td class="mono">' + HtmlEscape(%trim(PkgItems(idx).SavedLib)) + '</td>'
    + '<td class="mono">' + HtmlEscape(%trim(PkgItems(idx).TgtLib)) + '</td>'
    + '<td class="mono">' + HtmlEscape(%trim(PkgItems(idx).ObjName)) + '</td>'
    + '<td><span class="badge">' + HtmlEscape(%trim(PkgItems(idx).ObjType))
    + '</span></td>'
    + '<td class="mono">' + HtmlEscape(%trim(PkgItems(idx).ExtAttr)) + '</td>'
    + '<td><span class="badge b-ok">'
    + HtmlEscape(%trim(PkgItems(idx).Version)) + '</span></td>'
    + '<td>' + ActionBadge + '</td>'
    + '<td>' + AuthBadge + '</td>'
    + '<td>' + DataBadge + '</td>'
    + '<td>' + HtmlEscape(%trim(PkgItems(idx).TextDesc)) + '</td>'
    + '</tr>';

    if %len(HtmlChunk) > 12000 or idx = PkgItemCnt;
      exec sql
        CALL QSYS2.IFS_WRITE_UTF8(
               PATH_NAME   => :PathStr,
               LINE        => :HtmlChunk,
               OVERWRITE   => 'APPEND',
               END_OF_LINE => 'LF');
      HtmlChunk = '';
    endif;
  endfor;

  // 3. Write HTML Footer & Filter Script
  HtmlChunk =
    '</tbody></table></div>'
  + '<script>function filterRows(){var q=document.getElementById("q")'
  + '.value.toUpperCase(),tr=document.getElementById("tbl")'
  + '.getElementsByTagName("tr");for(var i=1;i<tr.length;i++){'
  + 'tr[i].style.display=tr[i].innerText.toUpperCase().indexOf(q)>-1?'
  + '"":"none";}}</script></div></body></html>';

  exec sql
    CALL QSYS2.IFS_WRITE_UTF8(
           PATH_NAME   => :PathStr,
           LINE        => :HtmlChunk,
           OVERWRITE   => 'APPEND',
           END_OF_LINE => 'LF');
end-proc;

// ============================================================================
// Procedure: GetTierLabel
// Description: Formats a human-readable label for each Precedence Tier
// ============================================================================
dcl-proc GetTierLabel;
  dcl-pi *n varchar(64);
    pTier int(10) const;
  end-pi;

  select;
    when pTier = TIER_ENV_FOUNDATION;
      return 'Tier 10: System Foundation';
    when pTier = TIER_DATA_CONTAINERS;
      return 'Tier 15: Msgf/DtaAra/DtaQ';
    when pTier = TIER_PHYSICAL_DATA;
      return 'Tier 20: Physical PF/Table';
    when pTier = TIER_LOGICAL_DATA;
      return 'Tier 30: Logical LF/View/Idx';
    when pTier = TIER_DEVICE_UI;
      return 'Tier 40: Device/UI';
    when pTier = TIER_MODULES_BND;
      return 'Tier 50: Module/BndDir';
    when pTier = TIER_SRVPGM;
      return 'Tier 60: Service Program';
    when pTier = TIER_PROGRAMS;
      return 'Tier 70: Program/SQLPkg';
    other;
      return 'Tier 80: Command/Other';
  endsl;
end-proc;

// ============================================================================
// Procedure: GetObjectUsrDfnAtr
// Description: Retrieves the 10-character USER_DEFINED_ATTRIBUTE of an object
// ============================================================================
dcl-proc GetObjectUsrDfnAtr;
  dcl-pi *n char(10);
    pLib  char(10) const;
    pObj  char(10) const;
    pType char(10) const;
  end-pi;

  dcl-s UsrAtr char(10) inz(*blanks);

  exec sql
    SELECT COALESCE(USER_DEFINED_ATTRIBUTE, '')
      INTO :UsrAtr
      FROM TABLE(QSYS2.OBJECT_STATISTICS(
                   OBJECT_SCHEMA => :pLib,
                   OBJTYPELIST   => :pType,
                   OBJECT_NAME   => :pObj)) AS X
     FETCH FIRST 1 ROW ONLY;

  if sqlcode <> 0;
    return *blanks;
  endif;

  return UsrAtr;
end-proc;

// ============================================================================
// Procedure: HtmlEscape
// Description: Escapes special HTML characters (&, <, >, ")
// ============================================================================
dcl-proc HtmlEscape;
  dcl-pi *n varchar(512);
    pIn varchar(512) const;
  end-pi;

  dcl-s OutStr varchar(512);

  OutStr = pIn;
  OutStr = %scanrpl('&': '&amp;': OutStr);
  OutStr = %scanrpl('<': '&lt;':  OutStr);
  OutStr = %scanrpl('>': '&gt;':  OutStr);
  OutStr = %scanrpl('"': '&quot;': OutStr);
  return OutStr;
end-proc;
