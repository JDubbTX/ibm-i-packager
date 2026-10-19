/* ========================================================================== */
/* Sample CL Command: ORDENT.CMD (Process Customer Order)                     */
/* Built with IBM i TOBi (makei) -> *CMD - Precedence Tier 80                 */
/* ========================================================================== */
             CMD        PROMPT('Process Customer Order')

             PARM       KWD(ORDID) TYPE(*DEC) LEN(10 0) MIN(1) +
                          PROMPT('Order ID')

             PARM       KWD(CUSTID) TYPE(*DEC) LEN(8 0) MIN(1) +
                          PROMPT('Customer ID')

             PARM       KWD(AMOUNT) TYPE(*DEC) LEN(11 2) MIN(1) +
                          PROMPT('Order Subtotal Amount')
