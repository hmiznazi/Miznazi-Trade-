-- =====================================================================
-- PART A: SEED. Creates the Miznazi Trade Desk workspace and makes you owner.
-- 1) Replace YOUR_EMAIL_HERE with the email of the user you created in
--    Supabase (Authentication -> Users). 2) Run this part on its own.
-- =====================================================================
insert into workspaces (name, slug, is_internal)
values ('Miznazi Trade Desk', 'miznazi-desk', true);

insert into workspace_members (workspace_id, user_id, role)
select w.id, u.id, 'owner'
from workspaces w, auth.users u
where w.slug = 'miznazi-desk' and u.email = 'YOUR_EMAIL_HERE';

-- Check it worked: should return one row with role = owner
select w.name, u.email, m.role
from workspace_members m
join workspaces w on w.id = m.workspace_id
join auth.users u on u.id = m.user_id;


-- =====================================================================
-- PART B: GATE TESTS. Run this as a separate query AFTER Part A.
-- It creates temporary test data, tries to break each gate, reports
-- PASS / FAIL per test, then deletes the test data.
-- =====================================================================
create or replace function public.run_gate_tests() returns setof text
language plpgsql as $$
declare
  ws uuid; b uuid; s uuid; d uuid; owner_id uuid;
begin
  select id into ws from workspaces where slug = 'miznazi-desk';
  select user_id into owner_id from workspace_members where workspace_id = ws and role = 'owner' limit 1;

  insert into companies (workspace_id, legal_name, roles, country)
    values (ws, 'TEST Buyer Ltd', 'buyer', 'EG') returning id into b;
  insert into companies (workspace_id, legal_name, roles, country)
    values (ws, 'TEST Supplier Ltd', 'supplier', 'BR') returning id into s;

  -- Test 1: listing blocked before KYC
  begin
    insert into listings (workspace_id, company_id, type, product_name, quantity)
      values (ws, b, 'demand', 'Sugar ICUMSA 45', 500);
    return next 'FAIL 1: listing allowed without KYC';
  exception when others then return next 'PASS 1 (listing needs KYC): ' || sqlerrm;
  end;

  insert into deals (workspace_id, buyer_company_id, supplier_company_id, product_name,
                     quantity, unit, sell_price, buy_price, freight, other_costs)
    values (ws, b, s, 'Sugar ICUMSA 45', 500, 'MT', 1000, 900, 45, 8) returning id into d;

  -- Test 2: margin math (blueprint example: 47 per MT, 23,500 total)
  if (select net_margin_per_unit from deals where id = d) = 47
     and (select deal_margin from deals where id = d) = 23500 then
    return next 'PASS 2 (margin = 47/MT, 23,500 total)';
  else
    return next 'FAIL 2: margin maths wrong';
  end if;

  -- Test 3: deal cannot advance before KYC
  begin
    update deals set stage = 'loi' where id = d;
    return next 'FAIL 3: deal moved without KYC';
  exception when others then return next 'PASS 3 (deal needs KYC): ' || sqlerrm;
  end;

  update companies set kyc_status = 'approved' where id in (b, s);

  -- Test 4: cannot skip stages
  begin
    update deals set stage = 'spa' where id = d;
    return next 'FAIL 4: stage skipping allowed';
  exception when others then return next 'PASS 4 (no stage skipping): ' || sqlerrm;
  end;

  -- Legit moves: matched -> loi -> fco_icpo -> spa -> payment_instrument
  update deals set stage = 'loi' where id = d;
  update deals set stage = 'fco_icpo' where id = d;
  update deals set stage = 'spa' where id = d;
  update deals set stage = 'payment_instrument' where id = d;

  -- Test 5: no inspection/loading before verified payment instrument
  begin
    update deals set stage = 'inspection' where id = d;
    return next 'FAIL 5: moved on without verified instrument';
  exception when others then return next 'PASS 5 (payment gate): ' || sqlerrm;
  end;

  insert into payment_instruments (workspace_id, deal_id, type, status)
    values (ws, d, 'lc', 'verified');
  update deals set stage = 'inspection' where id = d;
  update deals set stage = 'dispatch' where id = d;

  -- Test 6: no release without a held transport document and two keys
  begin
    update deals set stage = 'document_released', md_approved_by = owner_id,
           finance_confirmed_by = owner_id where id = d;
    return next 'FAIL 6: release allowed without held document';
  exception when others then return next 'PASS 6 (release gate): ' || sqlerrm;
  end;

  insert into shipments (workspace_id, deal_id, transport_doc_status)
    values (ws, d, 'held');

  -- Test 7: two-key rule (same person cannot hold both keys)
  begin
    update deals set stage = 'document_released', md_approved_by = owner_id,
           finance_confirmed_by = owner_id where id = d;
    return next 'FAIL 7: one person held both keys';
  exception when others then return next 'PASS 7 (two-key rule): ' || sqlerrm;
  end;

  -- Test 8: history was logged
  if (select count(*) from deal_stage_history where deal_id = d) = 6 then
    return next 'PASS 8 (6 stage changes logged)';
  else
    return next 'FAIL 8: history count is ' || (select count(*) from deal_stage_history where deal_id = d);
  end if;

  -- Clean up test data
  delete from deals where id = d;
  delete from companies where id in (b, s);
  return next 'Test data removed.';
end $$;

select * from public.run_gate_tests();

-- Tidy up the test helper
drop function public.run_gate_tests();
