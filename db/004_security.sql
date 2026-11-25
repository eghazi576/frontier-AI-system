-- AI Fronter: security.
-- Without this, anyone with the Supabase public (anon) key could read every business's data.
-- After this, a logged-in owner sees only their own business. n8n (postgres user) and the
-- Next.js server (service_role) are outside RLS.

-- Functions are for servers only (n8n / Next.js service role), never the browser.
do $$
declare f text;
begin
  foreach f in array array[
    'hours_text(uuid)',
    'persona_prompt(uuid, text)',
    'fronter_open(uuid, text, text, text, text)',
    'fronter_inbound(text, text, text, text)',
    'avatar_inbound(text, text)',
    'fronter_log(uuid, text, text, text)',
    'take_owner_notifications(uuid)',
    'available_slots(uuid, date, int)',
    'conv_context(uuid)',
    'check_availability(uuid, text)',
    'book_appointment(uuid, text, text, text, text)',
    'my_appointments(uuid)',
    'cancel_appointment(uuid, text)',
    'save_lead(uuid, text, text, text)'
  ] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

alter table tenants            enable row level security;
alter table industry_templates enable row level security;

create policy tenants_owner on tenants
  for all to authenticated
  using (owner_user_id = auth.uid()) with check (owner_user_id = auth.uid());

create policy templates_read on industry_templates
  for select to authenticated using (true);

do $$
declare t text;
begin
  foreach t in array array['personas','channels','knowledge_items','business_hours','closures',
                           'contacts','conversations','messages','leads','appointments',
                           'owner_notifications']
  loop
    execute format('alter table %I enable row level security', t);
    execute format($p$
      create policy %I on %I for all to authenticated
      using      (tenant_id in (select id from tenants where owner_user_id = auth.uid()))
      with check (tenant_id in (select id from tenants where owner_user_id = auth.uid()))
    $p$, t || '_owner', t);
  end loop;
end $$;

-- n8n's AI memory: RLS on and no policies, so only n8n and the service role can read it.
alter table n8n_chat_histories enable row level security;
