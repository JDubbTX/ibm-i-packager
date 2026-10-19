**free
// ============================================================================
// Test Suite:  TPKGTEST (pkgtest.test.sqlrpgle)
// Source File: test/qrpglesrc/pkgtest.test.sqlrpgle
// Framework:   iRPGUnit (RPGUNIT) / Code for IBM i Testing Extension
// Description: Unit and integration test suite for #PACK and #UNPACK commands.
//              Verifies:
//              1. Packaging specific object types (*PGM, *SRVPGM, *FILE,
//                 *DTAARA, *DTAQ, *MSGF, *MODULE, *BNDDIR, *CMD)
//              2. Stamping the 10-char VERSION into USRDFNATR on all packaged
//                 objects and on the Save File itself
//              3. Filtering by generic object name patterns and exporting
//                 packages to IFS stream files
//              4. Unpacking in strict dependency precedence order while
//                 preserving the 10-char version attribute
//              5. Preserving all object authorities and applying JSON
//                 MAPFILE library mappings and per-file preserveData overrides
//
// Compile with iRPGUnit:
//   RUCRTRPG TSTPGM(PACKAGER/TPKGTEST) +
//            SRCSTMF('/path/to/test/qrpglesrc/pkgtest.test.sqlrpgle') +
//            INCDIR('/path/to/src/qrpglesrc') RPGPPOPT(*LVL2)
// Run:
//   RUCALLTST TSTPGM(PACKAGER/TPKGTEST)
// ============================================================================
ctl-opt nomain ccsidcvt(*excp) ccsid(*char : *jobrun)
        option(*srcstmt : *nodebugio) bnddir('RPGUNIT/IRPGUNIT');

// Include iRPGUnit assertion prototypes (aEqual, iEqual, assert, fail, etc.)
/include qinclude,TESTCASE
/include 'src/qrpglesrc/PKGTYPES.rpgleinc'

// Set SQL precompiler options at module leviel
exec sql SET OPTION COMMIT = *NONE, CLOSQLCSR = *ENDMOD, NAMING = *SYS;

// ----------------------------------------------------------------------------
// Test Suite Constants
// ----------------------------------------------------------------------------
dcl-c TEST_SRC_LIB  'PKGTSTSRC';
dcl-c TEST_TGT_LIB  'PKGTSTTGT';
dcl-c TEST_DTA_LIB  'PKGTSTDTA';
dcl-c TEST_PGM_LIB  'PKGTSTPGM';

// ============================================================================
// Lifecycle: setUpSuite
// Description: Creates test libraries and builds fixture objects across all
//              traditional and SQL IBM i object types in PKGTSTSRC.
// ============================================================================
dcl-proc setUpSuite export;
  dcl-s ToolLib char(10) inz('PACKAGER');

  // Locate library containing PACKC in *LIBL
  exec sql
    SELECT COALESCE(OBJLONGSCHEMA, 'PACKAGER')
      INTO :ToolLib
      FROM TABLE(QSYS2.OBJECT_STATISTICS(
                   OBJECT_SCHEMA => '*LIBL',
                   OBJTYPELIST   => '*PGM',
                   OBJECT_NAME   => 'PACKC')) AS X
     FETCH FIRST 1 ROW ONLY;

  if ToolLib = *blanks;
    ToolLib = 'PACKAGER';
  endif;

  // Ensure both PACK/#PACK and UNPACK/#UNPACK commands exist in ToolLib and
  // invoke their respective CL Command Processing Programs (PACKC / UNPACKC)
  ExecCl('CHGCMD CMD(' + %trim(ToolLib) + '/PACK) PGM('
       + %trim(ToolLib) + '/PACKC)');
  ExecCl('CRTDUPOBJ OBJ(PACK) FROMLIB(' + %trim(ToolLib)
       + ') OBJTYPE(*CMD) TOLIB(' + %trim(ToolLib) + ') NEWOBJ(#PACK)');
  ExecCl('CHGCMD CMD(' + %trim(ToolLib) + '/#PACK) PGM('
       + %trim(ToolLib) + '/PACKC)');

  ExecCl('CHGCMD CMD(' + %trim(ToolLib) + '/UNPACK) PGM('
       + %trim(ToolLib) + '/UNPACKC)');
  ExecCl('CRTDUPOBJ OBJ(UNPACK) FROMLIB(' + %trim(ToolLib)
       + ') OBJTYPE(*CMD) TOLIB(' + %trim(ToolLib) + ') NEWOBJ(#UNPACK)');
  ExecCl('CHGCMD CMD(' + %trim(ToolLib) + '/#UNPACK) PGM('
       + %trim(ToolLib) + '/UNPACKC)');

  // Clean up any leftover test libraries from prior runs
  ExecCl('DLTLIB LIB(' + TEST_SRC_LIB + ')');
  ExecCl('DLTLIB LIB(' + TEST_TGT_LIB + ')');
  ExecCl('DLTLIB LIB(' + TEST_DTA_LIB + ')');
  ExecCl('DLTLIB LIB(' + TEST_PGM_LIB + ')');

  // Create fresh test libraries
  ExecCl('CRTLIB LIB(' + TEST_SRC_LIB + ') TEXT(''Packager Test Source Lib'')');
  ExecCl('CRTLIB LIB(' + TEST_TGT_LIB + ') TEXT(''Packager Test Target Lib'')');
  ExecCl('CRTLIB LIB(' + TEST_DTA_LIB + ') TEXT(''Packager Test Data Lib'')');
  ExecCl('CRTLIB LIB(' + TEST_PGM_LIB + ') TEXT(''Packager Test Pgm Lib'')');

  // 1. Create *DTAARA, *DTAQ, and *MSGF fixtures
  ExecCl('CRTDTAARA DTAARA(' + TEST_SRC_LIB + '/TSTDTAARA) TYPE(*CHAR) '
       + 'LEN(50) VALUE(''INITIAL_DTAARA'')');
  ExecCl('CRTDTAQ DTAQ(' + TEST_SRC_LIB + '/TSTDTAQ) MAXLEN(128)');
  ExecCl('CRTMSGF MSGF(' + TEST_SRC_LIB + '/TSTMSGF)');

  // 2. Create SQL Table / Physical File fixtures (*FILE PF/TB) and seed rows
  exec sql
    CREATE TABLE PKGTSTSRC.TSTCUSTPF (
      CUSTID   INT      NOT NULL PRIMARY KEY,
      CUSTNAME CHAR(30) NOT NULL
    );
  exec sql
    INSERT INTO PKGTSTSRC.TSTCUSTPF VALUES
      (100, 'PACKAGE SEED CUSTOMER 1'),
      (200, 'PACKAGE SEED CUSTOMER 2');

  // Reference configuration table (used to test preserveData: false override)
  exec sql
    CREATE TABLE PKGTSTSRC.TSTSYSCFG (
      CFGKEY CHAR(10) NOT NULL,
      CFGVAL CHAR(30) NOT NULL
    );
  exec sql
    INSERT INTO PKGTSTSRC.TSTSYSCFG VALUES
      ('VER_MODE', 'NEW_PACKAGE_CONFIG_VALUE');

  // 3. Create Dependent SQL View / Logical File fixture (*FILE LF/VW)
  exec sql
    CREATE VIEW PKGTSTSRC.TSTCUSTVW AS
      SELECT CUSTID, CUSTNAME
        FROM PKGTSTSRC.TSTCUSTPF;

  // 4. Create Source Physical File in QTEMP to compile *MODULE, *SRVPGM,
  //    *PGM (RPGLE & CLLE), and *CMD fixtures
  ExecCl('DLTF FILE(QTEMP/QTESTSRC)');
  ExecCl('CRTSRCPF FILE(QTEMP/QTESTSRC) RCDLEN(112)');

  // 4a. RPGLE Module & Service Program (TSTMOD1 -> TSTSRVPGM)
  WriteSrcMbr('TSTMOD1': 'RPGLE':
              '**FREE' + x'25'
            + 'ctl-opt nomain;' + x'25'
            + 'dcl-proc CalcTax export;' + x'25'
            + '  dcl-pi *n packed(11:2);' + x'25'
            + '    pAmt packed(11:2) const;' + x'25'
            + '  end-pi;' + x'25'
            + '  return pAmt * 0.05;' + x'25'
            + 'end-proc;');
  ExecCl('CRTRPGMOD MODULE(' + TEST_SRC_LIB + '/TSTMOD1) '
       + 'SRCFILE(QTEMP/QTESTSRC) SRCMBR(TSTMOD1)');
  ExecCl('CRTSRVPGM SRVPGM(' + TEST_SRC_LIB + '/TSTSRVPGM) '
       + 'MODULE(' + TEST_SRC_LIB + '/TSTMOD1) EXPORT(*ALL)');

  // 4b. Binding Directory (TSTBNDDIR)
  ExecCl('CRTBNDDIR BNDDIR(' + TEST_SRC_LIB + '/TSTBNDDIR)');
  ExecCl('ADDBNDDIRE BNDDIR(' + TEST_SRC_LIB + '/TSTBNDDIR) '
       + 'OBJ((' + TEST_SRC_LIB + '/TSTSRVPGM *SRVPGM))');

  // 4c. ILE RPG Program (TSTPGM1)
  WriteSrcMbr('TSTPGM1': 'RPGLE':
              '**FREE' + x'25'
            + 'ctl-opt dftactgrp(*no) actgrp(*new);' + x'25'
            + '*inlr = *on;' + x'25'
            + 'return;');
  ExecCl('CRTBNDRPG PGM(' + TEST_SRC_LIB + '/TSTPGM1) '
       + 'SRCFILE(QTEMP/QTESTSRC) SRCMBR(TSTPGM1)');

  // 4d. ILE CL Program (TSTCLPGM) & CL Command (TSTCMD1)
  WriteSrcMbr('TSTCLPGM': 'CLLE':
              'PGM' + x'25'
            + 'ENDPGM');
  ExecCl('CRTBNDCL PGM(' + TEST_SRC_LIB + '/TSTCLPGM) '
       + 'SRCFILE(QTEMP/QTESTSRC) SRCMBR(TSTCLPGM)');

  WriteSrcMbr('TSTCMD1': 'CMD':
              'CMD PROMPT(''Test Packaged Command'')');
  ExecCl('CRTCMD CMD(' + TEST_SRC_LIB + '/TSTCMD1) '
       + 'PGM(' + TEST_SRC_LIB + '/TSTCLPGM) '
       + 'SRCFILE(QTEMP/QTESTSRC) SRCMBR(TSTCMD1)');
end-proc;

// ============================================================================
// Lifecycle: setUp / tearDown / tearDownSuite
// ============================================================================
dcl-proc setUp export;
  ExecCl('DLTF FILE(QTEMP/SAVFPGM)');
  ExecCl('DLTF FILE(QTEMP/SAVFDB)');
  ExecCl('DLTF FILE(QTEMP/SAVFALL)');
  ExecCl('DLTF FILE(QTEMP/BKPSAVF)');
  ExecCl('RMVLNK OBJLNK(''/tmp/pkgtest_ifs.savf'')');
  ExecCl('RMVLNK OBJLNK(''/tmp/pkgtest_map.json'')');
  ExecCl('RMVLNK OBJLNK(''/tmp/pkgtest_pack_manifest.html'')');
  ExecCl('RMVLNK OBJLNK(''/tmp/pkgtest_unpack_manifest.html'')');

  // Reset version stamps on source fixtures so each test is independent
  ResetObjVersionStamp(TEST_SRC_LIB: 'TSTDTAARA': '*DTAARA');
  ResetObjVersionStamp(TEST_SRC_LIB: 'TSTDTAQ':   '*DTAQ');
  ResetObjVersionStamp(TEST_SRC_LIB: 'TSTMSGF':   '*MSGF');
  ResetObjVersionStamp(TEST_SRC_LIB: 'TSTCUSTPF': '*FILE');
  ResetObjVersionStamp(TEST_SRC_LIB: 'TSTSYSCFG': '*FILE');
  ResetObjVersionStamp(TEST_SRC_LIB: 'TSTCUSTVW': '*FILE');
  ResetObjVersionStamp(TEST_SRC_LIB: 'TSTMOD1':   '*MODULE');
  ResetObjVersionStamp(TEST_SRC_LIB: 'TSTBNDDIR': '*BNDDIR');
  ResetObjVersionStamp(TEST_SRC_LIB: 'TSTSRVPGM': '*SRVPGM');
  ResetObjVersionStamp(TEST_SRC_LIB: 'TSTPGM1':   '*PGM');
  ResetObjVersionStamp(TEST_SRC_LIB: 'TSTCLPGM':  '*PGM');
  ResetObjVersionStamp(TEST_SRC_LIB: 'TSTCMD1':   '*CMD');
end-proc;

dcl-proc tearDown export;
end-proc;

dcl-proc tearDownSuite export;
  ExecCl('DLTLIB LIB(' + TEST_SRC_LIB + ')');
  ExecCl('DLTLIB LIB(' + TEST_TGT_LIB + ')');
  ExecCl('DLTLIB LIB(' + TEST_DTA_LIB + ')');
  ExecCl('DLTLIB LIB(' + TEST_PGM_LIB + ')');
  ExecCl('RMVLNK OBJLNK(''/tmp/pkgtest_ifs.savf'')');
  ExecCl('RMVLNK OBJLNK(''/tmp/pkgtest_map.json'')');
  ExecCl('RMVLNK OBJLNK(''/tmp/pkgtest_pack_manifest.html'')');
  ExecCl('RMVLNK OBJLNK(''/tmp/pkgtest_unpack_manifest.html'')');
end-proc;

// ============================================================================
// Test 1: testPackSingleObjTypePgmAndVersionStamp
// Description: Packages ONLY *PGM objects using #PACK with version 'V1.0.0-PGM'
//              and asserts:
//              - TSTPGM1 and TSTCLPGM have USRDFNATR = 'V1.0.0-PGM'
//              - Save file QTEMP/SAVFPGM has USRDFNATR = 'V1.0.0-PGM'
//              - Save file contains exactly 2 objects and both are *PGM
//              - Non-*PGM objects (e.g. TSTDTAARA) were NOT stamped
// ============================================================================
dcl-proc testPackSingleObjTypePgmAndVersionStamp export;
  dcl-c EXP_VER 'V1.0.0-PGM';
  dcl-s CmdOk    ind;
  dcl-s SavfCnt  int(10);

  CmdOk = ExecCl('#PACK SRCLIB(' + TEST_SRC_LIB + ') '
               + 'OBJ(*ALL) OBJTYPE(*PGM) '
               + 'VERSION(''' + EXP_VER + ''') '
               + 'OUTTYPE(*SAVF) SAVF(QTEMP/SAVFPGM) CLEAR(*YES)');
  assert(CmdOk: '#PACK command for OBJTYPE(*PGM) should succeed');

  // Assert both *PGM objects are stamped with the 10-char version in USRDFNATR
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTPGM1': '*PGM'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTCLPGM': '*PGM'));

  // Assert the Save File itself was also stamped with the version
  aEqual(EXP_VER: GetObjVersionStamp('QTEMP': 'SAVFPGM': '*FILE'));

  // Assert non-*PGM objects were untouched
  aEqual(*blanks: GetObjVersionStamp(TEST_SRC_LIB: 'TSTDTAARA': '*DTAARA'));

  // Assert the Save File contains only the 2 *PGM objects
  SavfCnt = CountSavfObjects('QTEMP': 'SAVFPGM': '*ALL');
  iEqual(2: SavfCnt);
  iEqual(2: CountSavfObjects('QTEMP': 'SAVFPGM': '*PGM'));
end-proc;

// ============================================================================
// Test 2: testPackSpecificObjTypesFileAndSrvpgm
// Description: Packages *FILE and *SRVPGM objects with version 'V1.2.3-DB '
//              and verifies every *FILE and *SRVPGM is stamped and packaged,
//              while other object types are excluded.
// ============================================================================
dcl-proc testPackSpecificObjTypesFileAndSrvpgm export;
  dcl-c EXP_VER 'V1.2.3-DB ';
  dcl-s CmdOk   ind;

  CmdOk = ExecCl('#PACK SRCLIB(' + TEST_SRC_LIB + ') '
               + 'OBJ(*ALL) OBJTYPE(*FILE *SRVPGM) '
               + 'VERSION(''' + EXP_VER + ''') '
               + 'OUTTYPE(*SAVF) SAVF(QTEMP/SAVFDB) CLEAR(*YES)');
  assert(CmdOk: '#PACK command for OBJTYPE(*FILE *SRVPGM) should succeed');

  // Verify *FILE (PF/TB and LF/VW) and *SRVPGM objects have the new version
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTCUSTPF': '*FILE'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTSYSCFG': '*FILE'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTCUSTVW': '*FILE'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTSRVPGM': '*SRVPGM'));

  // Verify *DTAQ was not stamped with V1.2.3-DB
  aEqual(*blanks: GetObjVersionStamp(TEST_SRC_LIB: 'TSTDTAQ': '*DTAQ'));

  // Verify save file inventory has 3 *FILE objects and 1 *SRVPGM object
  iEqual(3: CountSavfObjects('QTEMP': 'SAVFDB': '*FILE'));
  iEqual(1: CountSavfObjects('QTEMP': 'SAVFDB': '*SRVPGM'));
  iEqual(4: CountSavfObjects('QTEMP': 'SAVFDB': '*ALL'));
end-proc;

// ============================================================================
// Test 3: testPackGenericObjPatternAndIfsOutput
// Description: Packages generic object pattern OBJ(TSTCUST*) to an IFS stream
//              file ('/tmp/pkgtest_ifs.savf') with version 'V2.0.0-IFS' and
//              verifies both the object version stamps and IFS file creation.
// ============================================================================
dcl-proc testPackGenericObjPatternAndIfsOutput export;
  dcl-c EXP_VER  'V2.0.0-IFS';
  dcl-c IFS_PATH '/tmp/pkgtest_ifs.savf';
  dcl-s CmdOk    ind;
  dcl-s IfsCnt   int(10) inz(0);

  CmdOk = ExecCl('#PACK SRCLIB(' + TEST_SRC_LIB + ') '
               + 'OBJ(TSTCUST*) OBJTYPE(*ALL) '
               + 'VERSION(''' + EXP_VER + ''') '
               + 'OUTTYPE(*STMF) STMF(''' + IFS_PATH + ''') CLEAR(*YES)');
  assert(CmdOk: '#PACK command with OBJ(TSTCUST*) and OUTTYPE(*STMF) should succeed');

  // Verify TSTCUSTPF and TSTCUSTVW were stamped with 'V2.0.0-IFS'
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTCUSTPF': '*FILE'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTCUSTVW': '*FILE'));

  // Verify TSTSYSCFG (does not match TSTCUST*) was not stamped
  aEqual(*blanks: GetObjVersionStamp(TEST_SRC_LIB: 'TSTSYSCFG': '*FILE'));

  // Verify the IFS stream file exists and is non-empty
  exec sql
    SELECT COUNT(*)
      INTO :IfsCnt
      FROM TABLE(QSYS2.IFS_OBJECT_STATISTICS(
                   START_PATH_NAME => '/tmp/pkgtest_ifs.savf',
                   SUBTREE_DIRECTORIES => 'NO')) AS X
     WHERE DATA_SIZE > 0;
  iEqual(1: IfsCnt);
end-proc;

// ============================================================================
// Test 4: testPackAllTraditionalTypesVersionStamp
// Description: Packages ALL object types in PKGTSTSRC with version 'REL-26.10A'
//              and asserts that:
//              - Every object type (*DTAARA, *DTAQ, *MSGF, *FILE PF/TB/VW,
//                *MODULE, *BNDDIR, *SRVPGM, *PGM, *CMD) is stamped with
//                'REL-26.10A' in USRDFNATR
//              - The HTML Manifest report is generated in the IFS with the
//                version at the top and all packaged object names & types
// ============================================================================
dcl-proc testPackAllTraditionalTypesVersionStamp export;
  dcl-c EXP_VER   'REL-26.10A';
  dcl-c MNFT_PATH '/tmp/pkgtest_pack_manifest.html';
  dcl-s CmdOk     ind;
  dcl-s HtmlHit   int(10) inz(0);

  CmdOk = ExecCl('#PACK SRCLIB(' + TEST_SRC_LIB + ') '
               + 'OBJ(*ALL) OBJTYPE(*ALL) '
               + 'VERSION(''' + EXP_VER + ''') '
               + 'OUTTYPE(*SAVF) SAVF(QTEMP/SAVFALL) CLEAR(*YES) '
               + 'MANIFEST(''' + MNFT_PATH + ''')');
  assert(CmdOk: '#PACK command for OBJ(*ALL) OBJTYPE(*ALL) should succeed');

  // Check every single object type's 10-char USRDFNATR version stamp
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTDTAARA': '*DTAARA'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTDTAQ':   '*DTAQ'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTMSGF':   '*MSGF'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTCUSTPF': '*FILE'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTSYSCFG': '*FILE'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTCUSTVW': '*FILE'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTMOD1':   '*MODULE'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTBNDDIR': '*BNDDIR'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTSRVPGM': '*SRVPGM'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTPGM1':   '*PGM'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTCLPGM':  '*PGM'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_SRC_LIB: 'TSTCMD1':   '*CMD'));
  aEqual(EXP_VER: GetObjVersionStamp('QTEMP':      'SAVFALL':   '*FILE'));

  // Verify the HTML Pack Manifest exists in IFS and contains the version,
  // object names, and object types
  exec sql
    SELECT COUNT(*)
      INTO :HtmlHit
      FROM TABLE(QSYS2.IFS_READ_UTF8(PATH_NAME => '/tmp/pkgtest_pack_manifest.html'))
     WHERE LINE LIKE '%REL-26.10A%'
       AND LINE LIKE '%TSTCUSTPF%'
       AND LINE LIKE '%TSTSRVPGM%';
  assert(HtmlHit > 0: 'HTML Pack Manifest should contain version and object rows');
end-proc;

// ============================================================================
// Test 5: testUnpackPrecedenceAndVersionPreserved
// Description: Unpacks all objects into PKGTSTTGT using #UNPACK and verifies:
//              - Dependent objects (TSTCUSTVW over TSTCUSTPF, TSTSRVPGM over
//                TSTMOD1, TSTCMD1 over TSTCLPGM) unpacked cleanly in order
//              - All unpacked objects in PKGTSTTGT retain their 10-character
//                version attribute ('REL-26.10A')
//              - The HTML Unpack Manifest report is generated in the IFS
// ============================================================================
dcl-proc testUnpackPrecedenceAndVersionPreserved export;
  dcl-c EXP_VER   'REL-26.10A';
  dcl-c MNFT_PATH '/tmp/pkgtest_unpack_manifest.html';
  dcl-s CmdOk     ind;
  dcl-s HtmlHit   int(10) inz(0);

  // Package all objects into QTEMP/SAVFALL
  CmdOk = ExecCl('#PACK SRCLIB(' + TEST_SRC_LIB + ') '
               + 'OBJ(*ALL) OBJTYPE(*ALL) '
               + 'VERSION(''' + EXP_VER + ''') '
               + 'OUTTYPE(*SAVF) SAVF(QTEMP/SAVFALL) CLEAR(*YES)');
  assert(CmdOk: '#PACK should succeed before #UNPACK test');

  // Unpack into TEST_TGT_LIB and generate HTML Unpack Manifest
  CmdOk = ExecCl('#UNPACK INPTYPE(*SAVF) SAVF(QTEMP/SAVFALL) '
               + 'DFTLIB(' + TEST_TGT_LIB + ') CPYDTA(*YES) '
               + 'MANIFEST(''' + MNFT_PATH + ''')');
  assert(CmdOk: '#UNPACK into ' + TEST_TGT_LIB + ' should succeed');

  // Assert every unpacked object exists in TEST_TGT_LIB and carries EXP_VER
  aEqual(EXP_VER: GetObjVersionStamp(TEST_TGT_LIB: 'TSTDTAARA': '*DTAARA'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_TGT_LIB: 'TSTDTAQ':   '*DTAQ'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_TGT_LIB: 'TSTMSGF':   '*MSGF'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_TGT_LIB: 'TSTCUSTPF': '*FILE'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_TGT_LIB: 'TSTSYSCFG': '*FILE'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_TGT_LIB: 'TSTCUSTVW': '*FILE'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_TGT_LIB: 'TSTMOD1':   '*MODULE'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_TGT_LIB: 'TSTBNDDIR': '*BNDDIR'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_TGT_LIB: 'TSTSRVPGM': '*SRVPGM'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_TGT_LIB: 'TSTPGM1':   '*PGM'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_TGT_LIB: 'TSTCLPGM':  '*PGM'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_TGT_LIB: 'TSTCMD1':   '*CMD'));

  // Verify the HTML Unpack Manifest exists in IFS and lists target library,
  // version, object names, types, and precedence tiers
  exec sql
    SELECT COUNT(*)
      INTO :HtmlHit
      FROM TABLE(QSYS2.IFS_READ_UTF8(PATH_NAME => '/tmp/pkgtest_unpack_manifest.html'))
     WHERE LINE LIKE '%PKGTSTTGT%'
       AND LINE LIKE '%TSTCUSTPF%'
       AND LINE LIKE '%Tier 20%';
  assert(HtmlHit > 0: 'HTML Unpack Manifest should list target libraries, objects, and tiers');
end-proc;

// ============================================================================
// Test 6: testUnpackReplaceAuthoritiesAndJsonOverrides
// Description: Verifies that #UNPACK with a JSON MAPFILE:
//              1. Routes *FILE (PF/LF) to PKGTSTDTA and *PGM/*SRVPGM to
//                 PKGTSTPGM
//              2. Preserves private authorities granted on existing objects
//              3. Preserves existing customer rows in TSTCUSTPF
//                 (preserveData: true)
//              4. Overwrites reference data in TSTSYSCFG with package seed
//                 rows (preserveData: false override)
// ============================================================================
dcl-proc testUnpackReplaceAuthoritiesAndJsonOverrides export;
  dcl-c EXP_VER   'REL-26.10B';
  dcl-c JSON_PATH '/tmp/pkgtest_map.json';
  dcl-s JsonText  varchar(2048);
  dcl-s CmdOk     ind;
  dcl-s RowCnt    int(10) inz(0);
  dcl-s CfgVal    char(30) inz(*blanks);
  dcl-s PubAut    varchar(20) inz('');

  // 1. Package PKGTSTSRC with version 'REL-26.10B'
  CmdOk = ExecCl('#PACK SRCLIB(' + TEST_SRC_LIB + ') '
               + 'OBJ(*ALL) OBJTYPE(*ALL) '
               + 'VERSION(''' + EXP_VER + ''') '
               + 'OUTTYPE(*SAVF) SAVF(QTEMP/SAVFALL) CLEAR(*YES)');
  assert(CmdOk: '#PACK should succeed');

  // 2. Write JSON MAPFILE to IFS
  JsonText = '{'
           + '"defaultLibrary": "' + TEST_PGM_LIB + '",'
           + '"defaultPreserveData": true,'
           + '"libraryMap": ['
           + '  {"objectType": "*FILE", "objectAttribute": "PF", '
           + '   "targetLibrary": "' + TEST_DTA_LIB + '"},'
           + '  {"objectType": "*FILE", "objectAttribute": "LF", '
           + '   "targetLibrary": "' + TEST_DTA_LIB + '"},'
           + '  {"objectType": "*PGM",  "objectAttribute": "*ALL", '
           + '   "targetLibrary": "' + TEST_PGM_LIB + '"}'
           + '],'
           + '"fileOverrides": ['
           + '  {"fileName": "TSTSYSCFG", "targetLibrary": "'
           +     TEST_DTA_LIB + '", "preserveData": false},'
           + '  {"fileName": "TSTCUSTPF", "targetLibrary": "'
           +     TEST_DTA_LIB + '", "preserveData": true}'
           + ']'
           + '}';

  exec sql
    CALL QSYS2.IFS_WRITE_UTF8(
           PATH_NAME => '/tmp/pkgtest_map.json',
           LINE      => :JsonText,
           OVERWRITE => 'REPLACE',
           END_OF_LINE => 'NONE');

  // 3. First unpack to establish baseline objects in PKGTSTDTA and PKGTSTPGM
  CmdOk = ExecCl('#UNPACK INPTYPE(*SAVF) SAVF(QTEMP/SAVFALL) '
               + 'MAPFILE(''' + JSON_PATH + ''')');
  assert(CmdOk: 'Initial #UNPACK with MAPFILE should succeed');

  // 4. Modify target data & authorities on existing objects in PKGTSTDTA:
  //    - Set *PUBLIC authority on TSTCUSTPF to *USE
  //    - Insert a production customer row (999) into PKGTSTDTA.TSTCUSTPF
  //    - Update PKGTSTDTA.TSTSYSCFG to 'OLD_LOCAL_VALUE'
  ExecCl('GRTOBJAUT OBJ(' + TEST_DTA_LIB + '/TSTCUSTPF) OBJTYPE(*FILE) '
       + 'USER(*PUBLIC) AUT(*USE) REPLACE(*YES)');

  exec sql
    INSERT INTO PKGTSTDTA.TSTCUSTPF VALUES (999, 'EXISTING PROD CUSTOMER');
  exec sql
    UPDATE PKGTSTDTA.TSTSYSCFG SET CFGVAL = 'OLD_LOCAL_VALUE';

  // 5. Re-unpack over the existing objects with Rollback Save File enabled
  CmdOk = ExecCl('#UNPACK INPTYPE(*SAVF) SAVF(QTEMP/SAVFALL) '
               + 'MAPFILE(''' + JSON_PATH + ''') '
               + 'BKPSAVF(QTEMP/BKPSAVF)');
  assert(CmdOk: 'Replacement #UNPACK with MAPFILE should succeed');

  // 6a. Assert library mapping worked and version stamp is present
  aEqual(EXP_VER: GetObjVersionStamp(TEST_DTA_LIB: 'TSTCUSTPF': '*FILE'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_DTA_LIB: 'TSTCUSTVW': '*FILE'));
  aEqual(EXP_VER: GetObjVersionStamp(TEST_PGM_LIB: 'TSTPGM1':   '*PGM'));

  // 6b. Assert *PUBLIC authority (*USE) on PKGTSTDTA/TSTCUSTPF was preserved
  exec sql
    SELECT COALESCE(OBJECT_AUTHORITY, '')
      INTO :PubAut
      FROM QSYS2.OBJECT_PRIVILEGES
     WHERE SYSTEM_OBJECT_SCHEMA = 'PKGTSTDTA'
       AND SYSTEM_OBJECT_NAME   = 'TSTCUSTPF'
       AND OBJECT_TYPE          = '*FILE'
       AND AUTHORIZATION_NAME   = '*PUBLIC'
     FETCH FIRST 1 ROW ONLY;
  aEqual('*USE': %trim(PubAut));

  // 6c. Assert TSTCUSTPF preserved its existing production row (999)
  exec sql
    SELECT COUNT(*)
      INTO :RowCnt
      FROM PKGTSTDTA.TSTCUSTPF
     WHERE CUSTID = 999;
  iEqual(1: RowCnt);

  // 6d. Assert TSTSYSCFG was overwritten with package seed data
  //     because of "preserveData": false in fileOverrides
  exec sql
    SELECT CFGVAL
      INTO :CfgVal
      FROM PKGTSTDTA.TSTSYSCFG
     WHERE CFGKEY = 'VER_MODE'
     FETCH FIRST 1 ROW ONLY;
  aEqual('NEW_PACKAGE_CONFIG_VALUE': %trim(CfgVal));
end-proc;

// ============================================================================
// Helper: GetObjVersionStamp
// Description: Queries QSYS2.OBJECT_STATISTICS to retrieve the 10-character
//              USER_DEFINED_ATTRIBUTE (USRDFNATR) of an object.
// ============================================================================
dcl-proc GetObjVersionStamp;
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
// Helper: ResetObjVersionStamp
// Description: Clears the 10-character USER_DEFINED_ATTRIBUTE (USRDFNATR)
//              on an object via QLICOBJD so tests remain order-independent.
// ============================================================================
dcl-proc ResetObjVersionStamp;
  dcl-pi *n;
    pLib  char(10) const;
    pObj  char(10) const;
    pType char(10) const;
  end-pi;

  dcl-ds QualObj likeds(QualName_t);
  dcl-ds ChgReq  likeds(ChgObjUsrDfnAtr_t) inz(*likeds);
  dcl-ds ApiErr  likeds(ApiError_t) inz(*likeds);
  dcl-s  RtnLib  char(10);

  QualObj.Name     = pObj;
  QualObj.Lib      = pLib;
  ChgReq.NumRcds   = 1;
  ChgReq.Key       = 9;
  ChgReq.DataLen   = 10;
  ChgReq.UsrDfnAtr = *blanks;

  QLICOBJD(RtnLib: QualObj: pType: ChgReq: ApiErr);
end-proc;

// ============================================================================
// Helper: CountSavfObjects
// Description: Uses QSRLSAVF (SAVF0200) to count how many objects (optionally
//              filtered by pObjType) are stored inside a Save File.
// ============================================================================
dcl-proc CountSavfObjects;
  dcl-pi *n int(10);
    pSavfLib char(10) const;
    pSavf    char(10) const;
    pObjType char(10) const;
  end-pi;

  dcl-c USRSPC_NAME 'TSTSPC    QTEMP     ';
  dcl-ds ApiErr     likeds(ApiError_t) inz(*likeds);
  dcl-ds QualSavf   likeds(QualName_t);
  dcl-s  SpcPtr     pointer;
  dcl-ds SpcHdr     likeds(UsrSpcHeader_t) based(SpcPtr);
  dcl-s  EntryPtr   pointer;
  dcl-ds Entry      likeds(SAVI0200_t) based(EntryPtr);
  dcl-s  idx        int(10);
  dcl-s  MatchCount int(10) inz(0);

  QUSCRTUS(USRSPC_NAME: 'TEST      ': 65536: x'00': '*ALL      ':
           'Test Save File Check': '*YES      ': ApiErr);
  if ApiErr.BytesAvailable > 0;
    return -1;
  endif;

  QualSavf.Name = pSavf;
  QualSavf.Lib  = pSavfLib;

  QSRLSAVF(USRSPC_NAME: 'SAVF0200': QualSavf: '*ALL      ': '*ALL      ':
           *blanks: ApiErr);
  if ApiErr.BytesAvailable > 0;
    QUSDLTUS(USRSPC_NAME: ApiErr);
    return -1;
  endif;

  QUSPTRUS(USRSPC_NAME: SpcPtr: ApiErr);
  for idx = 1 to SpcHdr.NumEntries;
    EntryPtr = SpcPtr + SpcHdr.ListOffset + ((idx - 1) * SpcHdr.EntrySize);
    if %trim(pObjType) = '*ALL' or %trim(Entry.ObjType) = %trim(pObjType);
      MatchCount += 1;
    endif;
  endfor;

  QUSDLTUS(USRSPC_NAME: ApiErr);
  return MatchCount;
end-proc;

// ============================================================================
// Helper: WriteSrcMbr
// Description: Adds a source member in QTEMP/QTESTSRC and populates it with
//              lines separated by LF (x'25') so fixture objects can be compiled
// ============================================================================
dcl-proc WriteSrcMbr;
  dcl-pi *n;
    pMbrName char(10)      const;
    pSrcType char(10)      const;
    pSource  varchar(4096) const;
  end-pi;

  dcl-s AliasSql varchar(512);
  dcl-s LineStr  varchar(100);
  dcl-s Pos      int(10);
  dcl-s Start    int(10) inz(1);
  dcl-s SeqNum   packed(6:2) inz(1.00);

  ExecCl('RMVM FILE(QTEMP/QTESTSRC) MBR(' + %trim(pMbrName) + ')');
  ExecCl('ADDPFM FILE(QTEMP/QTESTSRC) MBR(' + %trim(pMbrName)
       + ') SRCTYPE(' + %trim(pSrcType) + ')');

  AliasSql = 'CREATE OR REPLACE ALIAS QTEMP.SRCMBR FOR QTEMP.QTESTSRC ('
           + %trim(pMbrName) + ')';
  exec sql EXECUTE IMMEDIATE :AliasSql;

  dow Start <= %len(pSource);
    Pos = %scan(x'25': pSource: Start);
    if Pos = 0;
      LineStr = %subst(pSource: Start);
      Start = %len(pSource) + 1;
    else;
      LineStr = %subst(pSource: Start: Pos - Start);
      Start = Pos + 1;
    endif;

    exec sql
      INSERT INTO QTEMP.SRCMBR (SRCSEQ, SRCDAT, SRCDTA)
      VALUES (:SeqNum, 0, :LineStr);
    SeqNum += 1.00;
  enddo;
end-proc;

// ============================================================================
// Helper: ExecCl
// Description: Executes a CL command and returns *ON if successful
// ============================================================================
dcl-proc ExecCl;
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

