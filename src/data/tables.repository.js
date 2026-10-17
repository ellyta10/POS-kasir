/* Restaurant table data access layer. Active-bill behavior remains in the app layer. */
(function attachTablesRepository(global) {
  const TABLE_SELECT = 'id,name';

  function normalizeTable(table) {
    return {
      id: table.id,
      name: table.name
    };
  }

  function list(client) {
    return client
      .from('restaurant_tables')
      .select(TABLE_SELECT)
      .order('name')
      .limit(500);
  }

  function create(client, table) {
    return client
      .from('restaurant_tables')
      .insert(table);
  }

  function update(client, id, name) {
    return client
      .from('restaurant_tables')
      .update({ name })
      .eq('id', id);
  }

  function remove(client, id) {
    return client
      .from('restaurant_tables')
      .delete()
      .eq('id', id);
  }

  global.POSTablesRepository = Object.freeze({
    TABLE_SELECT,
    normalizeTable,
    list,
    create,
    update,
    remove
  });
})(window);
