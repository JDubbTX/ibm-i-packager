**FREE
// ============================================================================
// Program:     PACKR
// Source File: PACKR.sqlrpgle
// Description: Core SQLRPGLE packaging engine for #PACK command.
//              1. Discovers objects in SRCLIB matching OBJ and OBJTYPE filters
//              2. Stamps each object's 10-char USRDFNATR with VERSION via
//                 the QLICOBJD system API
//              3. Packages all stamped objects into the target Save File
//              4. Resolves IFS directory or file path when OUTTYPE(*STMF)
//              5. Generates a styled, downloadable HTML Manifest Report in IFS
//                 with the Package Version at the top and all packaged objects
// ============================================================================
ctl-opt dftactgrp(*no) actgrp(*caller) option(*srcstmt:*nodebugio);

/include 'PKGTYPES.rpgleinc'

// ----------------------------------------------------------------------------
// Program Entry Parameters (from PACKC.clle)
// ----------------------------------------------------------------------------
dcl-ds ObjListParm_t qualified template;
  Count int(5);
  Item  char(10) dim(50);
end-ds;

dcl-ds TypListParm_t qualified template;
  Count int(5);
  Item  char(10) dim(20);
end-ds;

dcl-pi PACKR;
  inSrcLib    char(10)  const;
  inObjList   likeds(ObjListParm_t) const;
  inTypList   likeds(TypListParm_t) const;
  inVersion   char(10)  const;
  inOutType   char(6)   const;
  inWrkSavf   char(10)  const;
  inWrkLib    char(10)  const;
  inStmf      char(256) const;
  inTgtRls    char(10)  const;
  inClear     char(4)   const;
  inManifest  char(256) const;
  outFullStmf char(256);
  outFullMnft char(256);
  outRtnCde   char(1);
end-pi;

// ----------------------------------------------------------------------------
// Local Variables & Structures
// ----------------------------------------------------------------------------
dcl-s TypeFilterStr varchar(256) inz('');
dcl-s ObjName       char(10);
dcl-s ObjType       char(10);
dcl-s ObjAttr       char(10);
dcl-s SqlObjType    varchar(20);
dcl-s ObjSize       int(20);
dcl-s ObjText       varchar(50);
dcl-s StampedCount  int(10) inz(0);

// Batch arrays for SAVOBJ grouping & HTML Manifest generation
dcl-ds MatchedObj_t qualified template;
  Name    char(10);
  Type    char(10);
  Attr    char(10);
  SqlType varchar(20);
  Size    int(20);
  Text    varchar(50);
end-ds;

dcl-ds MatchedObjs likeds(MatchedObj_t) dim(5000);
dcl-s  MatchedCnt  int(10) inz(0);

// ----------------------------------------------------------------------------
// Main Procedure
// ----------------------------------------------------------------------------
exec sql SET OPTION COMMIT = *NONE, CLOSQLCSR = *ENDMOD, NAMING = *SYS;

outRtnCde   = '0';
outFullStmf = *blanks;
outFullMnft = *blanks;

// 1. If OUTTYPE(*STMF), resolve whether STMF is a directory or file path
if %trim(inOutType) = '*STMF';
  outFullStmf = ResolveIfsTargetPath(inStmf: inSrcLib: inVersion);
endif;

// 2. Build Object Type filter string for QSYS2.OBJECT_STATISTICS
TypeFilterStr = BuildTypeFilter(inTypList);

// 3. Query objects in SRCLIB and filter by OBJ generic patterns
exec sql
  DECLARE obj_csr CURSOR FOR
    SELECT COALESCE(OBJNAME, ''),
           COALESCE(OBJTYPE, ''),
           COALESCE(OBJATTRIBUTE, ''),
           COALESCE(SQL_OBJECT_TYPE, ''),
           COALESCE(OBJSIZE, 0),
           COALESCE(OBJTEXT, '')
      FROM TABLE(QSYS2.OBJECT_STATISTICS(
                   OBJECT_SCHEMA => :inSrcLib,
                   OBJTYPELIST   => :TypeFilterStr)) AS X
     ORDER BY OBJTYPE, OBJNAME;

exec sql OPEN obj_csr;
if sqlcode < 0;
  SendJobLogMsg('SQL error opening OBJECT_STATISTICS cursor for library '
                + %trim(inSrcLib));
  outRtnCde = '1';
  return;
endif;

dow 1 = 1;
  exec sql FETCH NEXT FROM obj_csr
            INTO :ObjName, :ObjType, :ObjAttr, :SqlObjType, :ObjSize, :ObjText;
  if sqlcode <> 0;
    leave;
  endif;

  // Exclude the target save file itself if it resides in SRCLIB
  if %trim(inSrcLib) = %trim(inWrkLib)
     and %trim(ObjName) = %trim(inWrkSavf)
     and %trim(ObjType) = '*FILE';
    iter;
  endif;

  // Check if object name matches the OBJ parameter list (supports *ALL & ABC*)
  if not MatchesObjFilter(ObjName: inObjList);
    iter;
  endif;

  // 4. Stamp the 10-character VERSION into USRDFNATR via QLICOBJD
  if not StampObjectVersion(inSrcLib: ObjName: ObjType: inVersion);
    outRtnCde = '1';
    exec sql CLOSE obj_csr;
    return;
  endif;

  StampedCount += 1;

  if MatchedCnt < %elem(MatchedObjs);
    MatchedCnt += 1;
    MatchedObjs(MatchedCnt).Name    = ObjName;
    MatchedObjs(MatchedCnt).Type    = ObjType;
    MatchedObjs(MatchedCnt).Attr    = ObjAttr;
    MatchedObjs(MatchedCnt).SqlType = SqlObjType;
    MatchedObjs(MatchedCnt).Size    = ObjSize;
    MatchedObjs(MatchedCnt).Text    = ObjText;
  endif;
enddo;

exec sql CLOSE obj_csr;

if MatchedCnt = 0;
  SendJobLogMsg('No matching objects found in library ' + %trim(inSrcLib)
                + ' to package.');
  outRtnCde = '1';
  return;
endif;

// 5. Save all matched & stamped objects into the working Save File
if not SaveStampedObjects(inSrcLib: inWrkLib: inWrkSavf: inTgtRls:
                          MatchedObjs: MatchedCnt);
  outRtnCde = '1';
  return;
endif;

// 6. Also stamp the Save File itself with the 10-char version in USRDFNATR
StampObjectVersion(inWrkLib: inWrkSavf: '*FILE': inVersion);

// 7. Generate HTML Manifest Report in IFS (unless MANIFEST(*NONE))
if %trim(inManifest) <> '*NONE' and %trim(inManifest) <> '';
  outFullMnft = ResolvePackManifestPath(inManifest: inOutType: outFullStmf:
                                        inSrcLib: inVersion);
  WritePackHtmlManifest(outFullMnft: inSrcLib: inVersion: inOutType:
                        inWrkLib: inWrkSavf: outFullStmf: inTgtRls:
                        MatchedObjs: MatchedCnt);
endif;

SendJobLogMsg('Successfully stamped and packaged ' + %char(StampedCount)
              + ' objects with version "' + %trim(inVersion)
              + '". Manifest: ' + %trim(outFullMnft));

return;

// ============================================================================
// Procedure: ResolvePackManifestPath
// Description: Resolves the IFS path for the #PACK HTML manifest report.
// ============================================================================
dcl-proc ResolvePackManifestPath;
  dcl-pi *n char(256);
    pManifest char(256) const;
    pOutType  char(6)   const;
    pFullStmf char(256) const;
    pSrcLib   char(10)  const;
    pVersion  char(10)  const;
  end-pi;

  dcl-s MnftStr  varchar(256);
  dcl-s StmfStr  varchar(256);
  dcl-s CleanVer varchar(10);
  dcl-s DotPos   int(10);

  MnftStr  = %trim(pManifest);
  CleanVer = %xlate(' /:\': '____': %trim(pVersion));

  if MnftStr = '*AUTO' or MnftStr = '';
    if %trim(pOutType) = '*STMF' and %trim(pFullStmf) <> '';
      StmfStr = %trim(pFullStmf);
      DotPos = %scanr('.': StmfStr);
      if DotPos > 1;
        return %subst(StmfStr: 1: DotPos - 1) + '_manifest.html';
      else;
        return StmfStr + '_manifest.html';
      endif;
    else;
      return '/tmp/pack_' + %trim(pSrcLib) + '_' + CleanVer + '_manifest.html';
    endif;
  endif;

  if %subst(MnftStr: %len(MnftStr): 1) = '/';
    return MnftStr + 'pack_' + %trim(pSrcLib) + '_' + CleanVer
         + '_manifest.html';
  endif;

  return MnftStr;
end-proc;

// ============================================================================
// Procedure: WritePackHtmlManifest
// Description: Writes a styled, self-contained HTML5 package manifest report
//              to the IFS with the 10-char Version prominently displayed at
//              the top, summary cards, client-side search filter, and table
//              of all packaged objects.
// ============================================================================
dcl-proc WritePackHtmlManifest;
  dcl-pi *n;
    pMnftPath char(256) const;
    pSrcLib   char(10)  const;
    pVersion  char(10)  const;
    pOutType  char(6)   const;
    pSavfLib  char(10)  const;
    pSavf     char(10)  const;
    pFullStmf char(256) const;
    pTgtRls   char(10)  const;
    pObjs     likeds(MatchedObj_t) dim(5000) const;
    pObjCnt   int(10)   const;
  end-pi;

  dcl-s PathStr    varchar(256);
  dcl-s HtmlChunk  varchar(16384);
  dcl-s DestLabel  varchar(256);
  dcl-s GenTime    varchar(32);
  dcl-s TotalBytes int(20) inz(0);
  dcl-s idx        int(10);
  dcl-s AttrBadge  varchar(64);

  PathStr = %trim(pMnftPath);
  GenTime = %char(%timestamp());

  if %trim(pOutType) = '*STMF';
    DestLabel = 'IFS Stream File: ' + %trim(pFullStmf);
  else;
    DestLabel = 'QSYS Save File: ' + %trim(pSavfLib) + '/' + %trim(pSavf);
  endif;

  for idx = 1 to pObjCnt;
    TotalBytes += pObjs(idx).Size;
  endfor;

  // 1. Write HTML5 Document Header, Stylesheet, and Top Version Hero Banner
  HtmlChunk =
    '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">'
  + '<meta name="viewport" content="width=device-width,initial-scale=1.0">'
  + '<title>IBM i Package Manifest - Version ' + HtmlEscape(%trim(pVersion))
  + '</title><style>'
  + ':root{--bg:#0f172a;--card:#1e293b;--border:#334155;--text:#f8fafc;'
  + '--muted:#94a3b8;--accent:#38bdf8;--badge:#0284c7;--ok:#22c55e;}'
  + '*{box-sizing:border-box;margin:0;padding:0;}'
  + 'body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,'
  + 'sans-serif;background:var(--bg);color:var(--text);padding:2rem;line-height:1.5;}'
  + '.container{max-width:1280px;margin:0 auto;}'
  + '.hero{background:linear-gradient(135deg,#0284c7 0%,#1e3a8a 100%);'
  + 'border-radius:12px;padding:1.75rem 2rem;margin-bottom:1.5rem;'
  + 'display:flex;justify-content:space-between;align-items:center;'
  + 'flex-wrap:wrap;gap:1rem;box-shadow:0 10px 25px rgba(0,0,0,0.3);}'
  + '.hero h1{font-size:1.6rem;font-weight:700;letter-spacing:-0.02em;}'
  + '.hero .subtitle{color:#e0f2fe;font-size:0.95rem;margin-top:0.25rem;}'
  + '.ver-pill{background:rgba(15,23,42,0.75);border:2px solid #7dd3fc;'
  + 'padding:0.75rem 1.25rem;border-radius:10px;text-align:right;}'
  + '.ver-pill .lbl{font-size:0.75rem;text-transform:uppercase;'
  + 'letter-spacing:0.08em;color:#bae6fd;display:block;}'
  + '.ver-pill .val{font-size:1.5rem;font-weight:800;font-family:monospace;'
  + 'color:#ffffff;}'
  + '.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));'
  + 'gap:1rem;margin-bottom:1.5rem;}'
  + '.card{background:var(--card);border:1px solid var(--border);'
  + 'border-radius:10px;padding:1rem 1.25rem;}'
  + '.card .k{font-size:0.75rem;text-transform:uppercase;color:var(--muted);'
  + 'letter-spacing:0.05em;}'
  + '.card .v{font-size:1.1rem;font-weight:600;margin-top:0.25rem;'
  + 'word-break:break-all;}'
  + '.toolbar{display:flex;justify-content:space-between;align-items:center;'
  + 'margin-bottom:1rem;gap:1rem;flex-wrap:wrap;}'
  + '.search{background:var(--card);border:1px solid var(--border);'
  + 'color:var(--text);padding:0.6rem 1rem;border-radius:8px;width:320px;'
  + 'font-size:0.9rem;}'
  + '.table-wrap{background:var(--card);border:1px solid var(--border);'
  + 'border-radius:12px;overflow:hidden;}'
  + 'table{width:100%;border-collapse:collapse;text-align:left;}'
  + 'th{background:#0f172a;color:var(--muted);font-size:0.78rem;'
  + 'text-transform:uppercase;letter-spacing:0.06em;padding:0.85rem 1rem;'
  + 'border-bottom:1px solid var(--border);}'
  + 'td{padding:0.75rem 1rem;border-bottom:1px solid rgba(51,65,85,0.6);'
  + 'font-size:0.9rem;}'
  + 'tr:hover td{background:rgba(56,189,248,0.06);}'
  + '.mono{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;'
  + 'font-weight:600;}'
  + '.badge{display:inline-block;padding:0.2rem 0.55rem;border-radius:6px;'
  + 'font-size:0.78rem;font-weight:600;font-family:monospace;'
  + 'background:rgba(56,189,248,0.15);color:#38bdf8;'
  + 'border:1px solid rgba(56,189,248,0.3);}'
  + '.stamp{background:rgba(34,197,94,0.15);color:#4ade80;'
  + 'border:1px solid rgba(34,197,94,0.3);padding:0.2rem 0.55rem;'
  + 'border-radius:6px;font-family:monospace;font-size:0.8rem;}'
  + '</style></head><body><div class="container">'
  + '<div class="hero"><div><h1>IBM i CI/CD Package Manifest (#PACK)</h1>'
  + '<div class="subtitle">' + HtmlEscape(DestLabel) + '</div></div>'
  + '<div class="ver-pill"><span class="lbl">Package Version (USRDFNATR)</span>'
  + '<span class="val">' + HtmlEscape(%trim(pVersion)) + '</span></div></div>'
  + '<div class="cards">'
  + '<div class="card"><div class="k">Package Version</div>'
  + '<div class="v mono">' + HtmlEscape(%trim(pVersion)) + '</div></div>'
  + '<div class="card"><div class="k">Source Library</div>'
  + '<div class="v mono">' + HtmlEscape(%trim(pSrcLib)) + '</div></div>'
  + '<div class="card"><div class="k">Objects Packaged</div>'
  + '<div class="v">' + %char(pObjCnt) + '</div></div>'
  + '<div class="card"><div class="k">Target Release</div>'
  + '<div class="v mono">' + HtmlEscape(%trim(pTgtRls)) + '</div></div>'
  + '<div class="card"><div class="k">Total Size (Bytes)</div>'
  + '<div class="v mono">' + %char(TotalBytes) + '</div></div>'
  + '<div class="card"><div class="k">Generated Timestamp</div>'
  + '<div class="v">' + HtmlEscape(GenTime) + '</div></div>'
  + '</div>'
  + '<div class="toolbar"><h2>Packaged Objects Inventory</h2>'
  + '<input type="text" id="q" class="search" '
  + 'placeholder="Filter by object name, type, or attribute..." '
  + 'onkeyup="filterRows()"></div>'
  + '<div class="table-wrap"><table id="tbl"><thead><tr>'
  + '<th>#</th><th>Object Name</th><th>Object Type</th>'
  + '<th>Attribute / SQL Type</th><th>Source Library</th>'
  + '<th>Version (USRDFNATR)</th><th>Size (Bytes)</th><th>Description</th>'
  + '</tr></thead><tbody>';

  exec sql
    CALL QSYS2.IFS_WRITE_UTF8(
           PATH_NAME   => :PathStr,
           LINE        => :HtmlChunk,
           OVERWRITE   => 'REPLACE',
           END_OF_LINE => 'LF');

  // 2. Write Table Rows for all Packaged Objects
  HtmlChunk = '';
  for idx = 1 to pObjCnt;
    AttrBadge = %trim(pObjs(idx).Attr);
    if %trim(pObjs(idx).SqlType) <> '';
      AttrBadge += ' (' + %trim(pObjs(idx).SqlType) + ')';
    endif;

    HtmlChunk +=
      '<tr>'
    + '<td>' + %char(idx) + '</td>'
    + '<td class="mono">' + HtmlEscape(%trim(pObjs(idx).Name)) + '</td>'
    + '<td><span class="badge">' + HtmlEscape(%trim(pObjs(idx).Type))
    + '</span></td>'
    + '<td class="mono">' + HtmlEscape(AttrBadge) + '</td>'
    + '<td class="mono">' + HtmlEscape(%trim(pSrcLib)) + '</td>'
    + '<td><span class="stamp">' + HtmlEscape(%trim(pVersion))
    + '</span></td>'
    + '<td class="mono">' + %char(pObjs(idx).Size) + '</td>'
    + '<td>' + HtmlEscape(%trim(pObjs(idx).Text)) + '</td>'
    + '</tr>';

    if %len(HtmlChunk) > 12000 or idx = pObjCnt;
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
// Procedure: HtmlEscape
// Description: Escapes special HTML characters (&, <, >, ", ')
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

// ============================================================================
// Procedure: BuildTypeFilter
// Description: Formats space-separated object type list for OBJECT_STATISTICS
// ============================================================================
dcl-proc BuildTypeFilter;
  dcl-pi *n varchar(256);
    pTypList likeds(TypListParm_t) const;
  end-pi;

  dcl-s Filter varchar(256) inz('');
  dcl-s idx    int(10);
  dcl-s CurTyp varchar(10);

  if pTypList.Count <= 0;
    return '*ALL';
  endif;

  for idx = 1 to pTypList.Count;
    CurTyp = %trim(pTypList.Item(idx));
    if CurTyp = '*ALL';
      return '*ALL';
    endif;
    if Filter <> '';
      Filter += ' ';
    endif;
    Filter += CurTyp;
  endfor;

  return Filter;
end-proc;

// ============================================================================
// Procedure: MatchesObjFilter
// Description: Evaluates whether pObjName matches any entry in pObjList
//              (*ALL, exact match, or generic prefix match 'ABC*')
// ============================================================================
dcl-proc MatchesObjFilter;
  dcl-pi *n ind;
    pObjName char(10) const;
    pObjList likeds(ObjListParm_t) const;
  end-pi;

  dcl-s idx     int(10);
  dcl-s Pattern varchar(10);
  dcl-s StarPos int(10);
  dcl-s Prefix  varchar(10);
  dcl-s Trimmed varchar(10);

  if pObjList.Count <= 0;
    return *on;
  endif;

  Trimmed = %trim(pObjName);

  for idx = 1 to pObjList.Count;
    Pattern = %trim(pObjList.Item(idx));
    if Pattern = '*ALL';
      return *on;
    endif;

    StarPos = %scan('*': Pattern);
    if StarPos > 0;
      if StarPos = 1;
        return *on;
      endif;
      Prefix = %subst(Pattern: 1: StarPos - 1);
      if %len(Trimmed) >= %len(Prefix)
         and %subst(Trimmed: 1: %len(Prefix)) = Prefix;
        return *on;
      endif;
    else;
      if Trimmed = Pattern;
        return *on;
      endif;
    endif;
  endfor;

  return *off;
end-proc;

// ============================================================================
// Procedure: StampObjectVersion
// Description: Uses QLICOBJD API (Key 9 = USRDFNATR) to stamp the 10-character
//              version string onto an IBM i object's description.
// ============================================================================
dcl-proc StampObjectVersion;
  dcl-pi *n ind;
    pLib     char(10) const;
    pObj     char(10) const;
    pType    char(10) const;
    pVersion char(10) const;
  end-pi;

  dcl-s  RtnLib      char(10) inz(*blanks);
  dcl-ds QualObj     likeds(QualName_t);
  dcl-ds ChgInfo     likeds(ChgObjUsrDfnAtr_t) inz(*likeds);
  dcl-ds ApiErr      likeds(ApiError_t) inz(*likeds);

  QualObj.Name = pObj;
  QualObj.Lib  = pLib;

  ChgInfo.NumRcds   = 1;
  ChgInfo.Key       = 9;          // Key 9: User-Defined Attribute (USRDFNATR)
  ChgInfo.DataLen   = 10;         // 10 characters
  ChgInfo.UsrDfnAtr = pVersion;

  QLICOBJD(RtnLib: QualObj: pType: ChgInfo: ApiErr);

  if ApiErr.BytesAvailable > 0;
    SendJobLogMsg('QLICOBJD failed to stamp version on '
                  + %trim(pLib) + '/' + %trim(pObj)
                  + ' (' + %trim(pType) + '): ' + ApiErr.ExceptionId);
    return *off;
  endif;

  return *on;
end-proc;

// ============================================================================
// Procedure: SaveStampedObjects
// Description: Saves the matched objects into the target Save File in batches
//              (up to 250 objects per SAVOBJ invocation).
// ============================================================================
dcl-proc SaveStampedObjects;
  dcl-pi *n ind;
    pSrcLib  char(10) const;
    pSavfLib char(10) const;
    pSavf    char(10) const;
    pTgtRls  char(10) const;
    pObjs    likeds(MatchedObj_t) dim(5000) const;
    pObjCnt  int(10) const;
  end-pi;

  dcl-s CmdStr     varchar(32000);
  dcl-s ObjNames   varchar(20000);
  dcl-s BatchCount int(10) inz(0);
  dcl-s idx        int(10);
  dcl-s j          int(10);
  dcl-s AlreadyIn  ind;
  dcl-s UniqueObjs char(10) dim(250);

  ObjNames = '';
  BatchCount = 0;

  for idx = 1 to pObjCnt;
    // Avoid duplicate object names in the same SAVOBJ OBJ(...) list
    AlreadyIn = *off;
    for j = 1 to BatchCount;
      if UniqueObjs(j) = pObjs(idx).Name;
        AlreadyIn = *on;
        leave;
      endif;
    endfor;

    if not AlreadyIn;
      BatchCount += 1;
      UniqueObjs(BatchCount) = pObjs(idx).Name;
      ObjNames += ' ' + %trim(pObjs(idx).Name);
    endif;

    if BatchCount = 250 or idx = pObjCnt;
      CmdStr = 'SAVOBJ OBJ(' + %trim(ObjNames) + ') '
             + 'LIB(' + %trim(pSrcLib) + ') '
             + 'DEV(*SAVF) '
             + 'OBJTYPE(*ALL) '
             + 'SAVF(' + %trim(pSavfLib) + '/' + %trim(pSavf) + ') '
             + 'TGTRLS(' + %trim(pTgtRls) + ') '
             + 'SAVACT(*LIB) '
             + 'ACCPTH(*YES) '
             + 'DTACPR(*MEDIUM)';

      if not RunClCommand(CmdStr);
        SendJobLogMsg('SAVOBJ failed while packaging library '
                      + %trim(pSrcLib));
        return *off;
      endif;

      ObjNames = '';
      BatchCount = 0;
    endif;
  endfor;

  return *on;
end-proc;

// ============================================================================
// Procedure: ResolveIfsTargetPath
// Description: Determines if inStmf is an existing IFS directory or ends with
//              '/'. If so, appends <SRCLIB>_<VERSION>.savf; otherwise returns
//              the stream file path directly.
// ============================================================================
dcl-proc ResolveIfsTargetPath;
  dcl-pi *n char(256);
    pStmf    char(256) const;
    pSrcLib  char(10)  const;
    pVersion char(10)  const;
  end-pi;

  dcl-s PathStr   varchar(256);
  dcl-s IfsType   varchar(20) inz('');
  dcl-s CleanVer  varchar(10);
  dcl-s FileName  varchar(64);

  PathStr = %trim(pStmf);
  if PathStr = '';
    return '/tmp/' + %trim(pSrcLib) + '.savf';
  endif;

  // Check if path exists as a *DIR in IFS via QSYS2.IFS_OBJECT_STATISTICS
  exec sql
    SELECT COALESCE(OBJECT_TYPE, '')
      INTO :IfsType
      FROM TABLE(QSYS2.IFS_OBJECT_STATISTICS(
                   START_PATH_NAME => :PathStr,
                   SUBTREE_DIRECTORIES => 'NO')) AS X
     FETCH FIRST 1 ROW ONLY;

  if %subst(PathStr: %len(PathStr): 1) = '/' or %trim(IfsType) = '*DIR';
    CleanVer = %xlate(' /:\': '____': %trim(pVersion));
    FileName = %trim(pSrcLib) + '_' + CleanVer + '.savf';
    if %subst(PathStr: %len(PathStr): 1) = '/';
      return PathStr + FileName;
    else;
      return PathStr + '/' + FileName;
    endif;
  endif;

  return PathStr;
end-proc;

// ============================================================================
// Procedure: RunClCommand
// Description: Executes a CL command via QCMDEXC with error trapping
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
