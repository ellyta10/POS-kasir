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
      .eq('order_type', 'Dine In')
      .limit(500);
  }

  function save(client, bill) {
    return client.rpc('save_active_bill', {
      p_table_name: bill.table_name,
      p_order_type: bill.order_type,
      p_items: bill.items,
      p_order_time: bill.order_time || null
    });
  }

  function remove(client, tableName) {
    return client.rpc('remove_active_bill', { p_table_name: tableName });
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
