/* Transaction data access layer. Retry, payment calculations, and UI state remain in the app layer. */
(function attachTransactionsRepository(global) {
  const HISTORY_SELECT = 'trx_id,date,time,table_name,order_type,cashier,subtotal,tax,service_charge,discount,member_discount,grand_total,payment_method,items,status,voided_at,void_reason';
  const REPORT_SELECT = 'id,trx_id,date,time,table_name,order_type,cashier,subtotal,tax,service_charge,discount,member_discount,grand_total,payment_method,items,status,voided_at,voided_by,void_reason';
  const ORDER_ITEMS_SELECT = 'transaction_id,product_id,product_name,unit_price,quantity,line_total';

  function checkoutAtomic(client, payload) {
    return client.rpc('checkout_atomic', payload);
  }

  function voidTransaction(client, trxId, reason) {
    return client.rpc('void_transaction', {
      p_trx_id: trxId,
      p_reason: reason
    });
  }

  function listHistory(client) {
    return client
      .from('transactions')
      .select(HISTORY_SELECT)
      .order('created_at', { ascending: false })
      .limit(5000);
  }

  function listReportRows(client, { from, to, cashier, orderType }) {
    let query = client
      .from('transactions')
      .select(REPORT_SELECT)
      .gte('date', from)
      .lte('date', to)
      .order('created_at', { ascending: false })
      .limit(5000);
    if (cashier) query = query.eq('cashier', cashier);
    if (orderType) query = query.eq('order_type', orderType);
    return query;
  }

  function listOrderItems(client, transactionIds) {
    return client
      .from('order_items')
      .select(ORDER_ITEMS_SELECT)
      .in('transaction_id', transactionIds)
      .limit(10000);
  }

  global.POSTransactionsRepository = Object.freeze({
    HISTORY_SELECT,
    REPORT_SELECT,
    ORDER_ITEMS_SELECT,
    checkoutAtomic,
    voidTransaction,
    listHistory,
    listReportRows,
    listOrderItems
  });
})(window);
