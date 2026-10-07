/* Report data access layer. Keeps report queries and response contracts outside index.html. */
(function attachReportsRepository(global) {
  const DASHBOARD_RPC = 'get_report_dashboard';
  const TRANSACTION_SELECT = 'id,trx_id,date,time,table_name,order_type,cashier,subtotal,tax,service_charge,discount,member_discount,grand_total,payment_method,items,status,voided_at,voided_by,void_reason';
  const ORDER_ITEMS_SELECT = 'transaction_id,product_id,product_name,unit_price,quantity,line_total';
  const MATERIAL_SELECT = 'id,name,stock,unit,cost,reorder_level';
  const MOVEMENT_SELECT = 'raw_material_id,quantity,movement_type,created_at,notes';
  const SHIFT_SELECT = 'id,user_id,opened_at,closed_at,opening_cash,closing_cash,expected_cash,difference,status';

  function dashboard(client, params) {
    return client.rpc(DASHBOARD_RPC, {
      p_from: params.from,
      p_to: params.to,
      p_compare_from: params.compareFrom,
      p_compare_to: params.compareTo,
      p_cashier: params.cashier || null,
      p_order_type: params.orderType || null
    });
  }
  function transactions(client, { from, to, cashier, orderType }) {
    let query = client.from('transactions').select(TRANSACTION_SELECT)
      .gte('date', from).lte('date', to).order('created_at', { ascending: false }).limit(5000);
    if (cashier) query = query.eq('cashier', cashier);
    if (orderType) query = query.eq('order_type', orderType);
    return query;
  }
  function orderItems(client, transactionIds) {
    if (!transactionIds.length) return Promise.resolve({ data: [], error: null });
    return client.from('order_items').select(ORDER_ITEMS_SELECT).in('transaction_id', transactionIds).limit(10000);
  }
  function operational(client, range, cashSessionsRepository) {
    return Promise.all([
      client.from('raw_materials').select(MATERIAL_SELECT).order('name').limit(500),
      client.from('inventory_movements').select(MOVEMENT_SELECT)
        .gte('created_at', `${range.from}T00:00:00`).lte('created_at', `${range.to}T23:59:59`)
        .order('created_at', { ascending: false }).limit(5000),
      cashSessionsRepository.listForReport(client, range)
    ]);
  }
  global.POSReportsRepository = Object.freeze({
    DASHBOARD_RPC, TRANSACTION_SELECT, ORDER_ITEMS_SELECT, MATERIAL_SELECT, MOVEMENT_SELECT, SHIFT_SELECT,
    dashboard, transactions, orderItems, operational
  });
})(window);
