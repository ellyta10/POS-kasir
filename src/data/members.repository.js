/* Member data access layer. Business rules stay in the application layer. */
(function attachMembersRepository(global) {
  const MEMBER_SELECT = 'id,name,phone,points';

  function normalizeMember(member) {
    return {
      id: member.id,
      name: member.name,
      phone: member.phone || '',
      points: Number(member.points) || 0
    };
  }

  function list(client) {
    return client
      .from('members')
      .select(MEMBER_SELECT)
      .order('name')
      .limit(1000);
  }

  function create(client, { id, name, phone }) {
    return client.rpc('create_member', {
      p_id: id,
      p_name: name,
      p_phone: phone
    });
  }

  global.POSMembersRepository = Object.freeze({
    MEMBER_SELECT,
    normalizeMember,
    list,
    create
  });
})(window);
