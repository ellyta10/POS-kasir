/* Cash-session data access layer. Cash calculations and UI rules remain in the app layer. */
(function attachCashSessionsRepository(global) {
  const CURRENT_SELECT = 'id,status,opening_cash,opened_at,closed_at,closing_cash,expected_cash,difference';
  const REPORT_SELECT = 'id,user_id,opened_at,closed_at,opening_cash,closing_cash,expected_cash,difference,status';

  function current(client, userId) {
    return client
      .from('cash_sessions')
      .select(CURRENT_SELECT)
      .eq('user_id', userId)
      .eq('status', 'open')
      .order('opened_at', { ascending: false })
      .limit(1)
      .maybeSingle();
  }

  function open(client, openingCash) {
    return client.rpc('open_cash_session', { p_opening_cash: openingCash });
  }

  function close(client, sessionId, actualCash) {
    return client.rpc('close_cash_session', {
      p_session_id: sessionId,
      p_actual_cash: actualCash
    });
  }

  function summary(client, sessionId) {
    return client.rpc('get_cash_session_summary', { p_session_id: sessionId });
  }

  function listForReport(client, range) {
    return client
      .from('cash_sessions')
      .select(REPORT_SELECT)
      .lte('opened_at', `${range.to}T23:59:59`)
      .or(`closed_at.gte.${range.from}T00:00:00,closed_at.is.null`)
      .order('opened_at', { ascending: false })
      .limit(500);
  }

  global.POSCashSessionsRepository = Object.freeze({
    CURRENT_SELECT,
    REPORT_SELECT,
    current,
    open,
    close,
    summary,
    listForReport
  });
})(window);
