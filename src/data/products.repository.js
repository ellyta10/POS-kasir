/* Product data access layer. UI code should not need to know table/query details. */
(function attachProductsRepository(global) {
  const PRODUCT_SELECT = 'id, name, category, price, gojek_price, grab_price, emoji, available, recipe';

  function normalizeProduct(product) {
    return {
      id: product.id,
      name: product.name,
      category: product.category,
      price: Number(product.price) || 0,
      gojek_price: Number(product.gojek_price) || Number(product.price) || 0,
      grab_price: Number(product.grab_price) || Number(product.price) || 0,
      emoji: product.emoji || '🍽️',
      available: product.available !== false,
      recipe: product.recipe || []
    };
  }

  function toCloudProduct(product) {
    return normalizeProduct(product);
  }

  function list(client) {
    return client
      .from('products')
      .select(PRODUCT_SELECT)
      .order('name')
      .limit(500);
  }

  function upsert(client, productOrProducts) {
    return client
      .from('products')
      .upsert(productOrProducts, { onConflict: 'id' });
  }

  function updateAvailability(client, id, available, updatedAt) {
    return client
      .from('products')
      .update({ available, updated_at: updatedAt })
      .eq('id', id);
  }

  function remove(client, id) {
    return client
      .from('products')
      .delete()
      .eq('id', id);
  }

  global.POSProductsRepository = Object.freeze({
    PRODUCT_SELECT,
    normalizeProduct,
    toCloudProduct,
    list,
    upsert,
    updateAvailability,
    remove
  });
})(window);
