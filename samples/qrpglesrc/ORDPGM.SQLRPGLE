**FREE
// ============================================================================
// Sample SQLRPGLE Program: ORDPGM.SQLRPGLE
// Built with IBM i TOBi (makei) -> *PGM (SQLRPGLE) - Precedence Tier 70
// Uses: CUSTPF (*FILE PF), ORDHDR (*FILE SQL TABLE), TAXSRV (*SRVPGM)
// ============================================================================
ctl-opt dftactgrp(*no) actgrp(*caller) bnddir('APPBND')
        option(*srcstmt : *nodebugio);

/include TAXPROTO.RPGLEINC

dcl-pi ORDPGM;
  inOrderId    packed(10:0) const;
  inCustId     packed(8:0)  const;
  inSubtotal   packed(11:2) const;
end-pi;

dcl-s custState  char(2)      inz('MN');
dcl-s taxAmt     packed(11:2) inz(0);
dcl-s totalAmt   packed(11:2) inz(0);

exec sql
  SET OPTION COMMIT = *NONE, CLOSQLCSR = *ENDMOD;

exec sql
  SELECT CUSTSTATE
    INTO :custState
    FROM CUSTPF
   WHERE CUSTID = :inCustId;

if sqlcode <> 0;
  custState = 'MN';
endif;

taxAmt   = CalcOrderTax(inSubtotal : custState);
totalAmt = inSubtotal + taxAmt;

exec sql
  INSERT INTO ORDHDR (ORDID, ORDCUST, ORDSUB, ORDTAX, ORDTOT, ORDSTS)
  VALUES (:inOrderId, :inCustId, :inSubtotal, :taxAmt, :totalAmt, 'O');

exec sql
  UPDATE CUSTPF
     SET CUSTBAL = CUSTBAL + :totalAmt
   WHERE CUSTID = :inCustId;

*inlr = *on;
return;
