/* Pure payment and cart rules. No DOM, Supabase, or application state access. */
(function attachPOSPaymentRules(global) {
  function calculateSubtotal(items = []) {
    return items.reduce((acc, item) => acc + (item.price * item.qty), 0);
  }

  function calculateBreakdown({ items = [], useTax = false, serviceRate = 0, discountRate = 0, memberSelected = false } = {}) {
    const subtotal = calculateSubtotal(items);
    const tax = useTax ? subtotal * 0.10 : 0;
    const serviceCharge = subtotal * serviceRate;
    const discount = (subtotal + tax + serviceCharge) * discountRate;
    const memberDiscount = memberSelected ? 5000 : 0;
    const grandTotal = Math.max(0, subtotal + tax + serviceCharge - discount - memberDiscount);
    return { subtotal, tax, serviceRate, serviceCharge, discountRate, discount, memberDiscount, grandTotal };
  }

  function isPaymentMethodAllowed(method, orderType) {
    if (method === 'Gojek App') return orderType === 'Gojek';
    if (method === 'Grab App') return orderType === 'Grab';
    return ['Cash', 'QRIS', 'Debit'].includes(method);
  }

  function getAvailablePaymentMethods(orderType) {
    return ['Cash', 'QRIS', 'Debit', 'Gojek App', 'Grab App']
      .filter(method => isPaymentMethodAllowed(method, orderType));
  }

  global.POSPaymentRules = Object.freeze({
    calculateSubtotal,
    calculateBreakdown,
    isPaymentMethodAllowed,
    getAvailablePaymentMethods
  });
})(window);
