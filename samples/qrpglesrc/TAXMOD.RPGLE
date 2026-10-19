**FREE
// ============================================================================
// Sample ILE RPG Module: TAXMOD.RPGLE
// Built with IBM i TOBi (makei) -> *MODULE (RPGLE) - Precedence Tier 50
// Bound into Service Program TAXSRV (*SRVPGM) - Precedence Tier 60
// ============================================================================
ctl-opt nomain option(*srcstmt : *nodebugio);

/include TAXPROTO.RPGLEINC

dcl-proc CalcOrderTax export;
  dcl-pi *n packed(11:2);
    subtotal   packed(11:2) value;
    stateCode  char(2)      const;
  end-pi;

  dcl-s rate packed(5:4) inz(0.0600);

  select;
    when stateCode = 'MN' or stateCode = 'TX';
      rate = 0.0825;
    when stateCode = 'NY' or stateCode = 'CA';
      rate = 0.0875;
    when stateCode = 'OR' or stateCode = 'NH';
      rate = 0.0000;
    other;
      rate = 0.0650;
  endsl;

  return %dech(subtotal * rate : 11 : 2);
end-proc;
