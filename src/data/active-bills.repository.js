/* Active-bill data access layer. Checkout and table UI rules remain in the app layer. */
(function attachActiveBillsRepository(global) {
  const BILL_SELECT = 'table_name,order_type,items,order_time';

  function normalizeBill(bill) {
    return {
      table: bill.table_name,
      orderType: bill.order_type,
      items: bill.items || [],
      time: bill.order_time || ''
    };
  }

  function list(client) {
    return client
      .from('active_bills')
      .select(BILL_SELECT)
      .limit(500);
  }

  function save(client, bill) {
    return client
      .from('active_bills')
      .upsert(bill, { onConflict: 'table_name' });
  }

  function remove(client, tableName) {
    return client
      .from('active_bills')
      .delete()
      .eq('table_name', tableName);
  }

  function move(client, fromTable, toTable) {
    return client.rpc('move_active_bill', {
      p_from_table: fromTable,
      p_to_table: toTable
    });
  }

  global.POSActiveBillsRepository = Object.freeze({
    BILL_SELECT,
    normalizeBill,
    list,
    save,
    remove,
    move
  });
})(window);
