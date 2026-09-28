-- =====================================================================
-- MIZNAZI TRADE PLATFORM  |  Phase 1 database schema  |  v1
-- Run ONCE in a fresh Supabase project (SQL Editor -> New query -> Run)
-- Every business table carries workspace_id so white-label is an
-- extension later, not a rewrite.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. ENUMS (fixed lists of allowed values)
-- ---------------------------------------------------------------------
create type member_role as enum ('owner','trade_manager','compliance','logistics','finance');
create type company_role as enum ('buyer','supplier','both');
create type kyc_status   as enum ('not_started','submitted','in_review','approved','rejected');
create type risk_tier    as enum ('standard','enhanced');
create type listing_type as enum ('demand','supply');
create type listing_status as enum ('draft','pending_review','live','matched','closed','rejected');

-- The CRM stages that belong to a DEAL (Lead + KYC live on the company)
create type deal_stage as enum (
  'matched','loi','fco_icpo','spa','payment_instrument',
  'inspection','dispatch','document_released','closed'
);

create type instrument_type   as enum ('lc','sblc','payment_terms');
create type instrument_status as enum ('received','verified','rejected');
create type transport_mode    as enum ('sea','air','road','rail');
create type transport_doc_status as enum ('draft','approved','held','released','closed');
create type doc_status as enum ('draft','sent','signed','superseded');

create sequence deal_seq start 1;

-- ---------------------------------------------------------------------
-- 2. WORKSPACES AND TEAM
-- ---------------------------------------------------------------------
create table workspaces (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  slug        text not null unique,
  is_internal boolean not null default false,   -- true = Miznazi Trade Desk
  plan        text not null default 'internal',
  created_at  timestamptz not null default now()
);

create table workspace_members (
  workspace_id uuid not null references workspaces(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  role         member_role not null,
  created_at   timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

-- Helper: is the logged-in user a team member of this workspace?
create or replace function public.is_staff(ws uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from workspace_members
    where workspace_id = ws and user_id = auth.uid()
  );
$$;

-- ---------------------------------------------------------------------
-- 3. COMPANIES (buyers and suppliers; one account can be both)
-- ---------------------------------------------------------------------
create table companies (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id) on delete cascade,
  legal_name   text not null,
  code         text not null default ('C-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,6))),
  roles        company_role not null default 'both',
  country      text,
  kyc_status   kyc_status not null default 'not_started',
  risk_tier    risk_tier,
  kyc_approved_by uuid references auth.users(id),
  kyc_approved_at timestamptz,
  created_at   timestamptz not null default now(),
  unique (workspace_id, code)
);

-- External portal users (buyer/supplier staff) linked to their company
create table company_users (
  company_id   uuid not null references companies(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  workspace_id uuid not null references workspaces(id) on delete cascade,
  primary key (company_id, user_id)
);

create table kyc_documents (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id) on delete cascade,
  company_id   uuid not null references companies(id) on delete cascade,
  doc_type     text not null,       -- e.g. 'incorporation', 'licence', 'ubo', 'bank_reference'
  file_path    text not null,       -- path in Supabase Storage
  expires_on   date,
  status       text not null default 'uploaded',
  uploaded_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 4. LISTINGS (demand and supply)
-- ---------------------------------------------------------------------
create table listings (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references workspaces(id) on delete cascade,
  company_id    uuid not null references companies(id),
  type          listing_type not null,
  status        listing_status not null default 'pending_review',
  product_name  text not null,
  hs_code       text,
  specs         jsonb not null default '{}'::jsonb,
  quantity      numeric not null check (quantity > 0),
  unit          text not null default 'MT',
  price         numeric,
  currency      text not null default 'USD',
  incoterm      text,
  origin_country      text,
  destination_country text,
  delivery_from date,
  delivery_to   date,
  payment_terms text,
  benchmark_price numeric,          -- filled by the AI price check later
  price_flag    text,               -- 'above_market' | 'at_market' | 'below_market'
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now()
);

-- Gate: no posting before KYC is approved
create or replace function public.enforce_listing_kyc() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from companies where id = new.company_id and kyc_status = 'approved') then
    raise exception 'KYC GATE: company has not passed KYC, listings are not allowed';
  end if;
  return new;
end $$;

create trigger trg_listing_kyc before insert on listings
  for each row execute function public.enforce_listing_kyc();

-- ---------------------------------------------------------------------
-- 5. DEALS
-- ---------------------------------------------------------------------
create table deals (
  id                  uuid primary key default gen_random_uuid(),
  workspace_id        uuid not null references workspaces(id) on delete cascade,
  deal_ref            text not null default ('D-' || to_char(now(),'YYMM') || '-' || lpad(nextval('deal_seq')::text,4,'0')),
  demand_listing_id   uuid references listings(id),
  supply_listing_id   uuid references listings(id),
  buyer_company_id    uuid not null references companies(id),
  supplier_company_id uuid not null references companies(id),
  stage               deal_stage not null default 'matched',
  product_name        text not null,
  quantity            numeric not null default 0,
  unit                text not null default 'MT',
  incoterm            text,
  destination         text,
  -- margin lines, per unit (blueprint section 9)
  sell_price   numeric not null default 0,
  buy_price    numeric not null default 0,
  freight      numeric not null default 0,
  insurance    numeric not null default 0,
  duties       numeric not null default 0,
  other_costs  numeric not null default 0,
  net_margin_per_unit numeric generated always as
    (sell_price - buy_price - freight - insurance - duties - other_costs) stored,
  deal_margin numeric generated always as
    ((sell_price - buy_price - freight - insurance - duties - other_costs) * quantity) stored,
  -- two-key release
  finance_confirmed_by uuid references auth.users(id),
  finance_confirmed_at timestamptz,
  md_approved_by       uuid references auth.users(id),
  md_approved_at       timestamptz,
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now(),
  unique (workspace_id, deal_ref)
);

create table deal_stage_history (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id) on delete cascade,
  deal_id      uuid not null references deals(id) on delete cascade,
  from_stage   deal_stage,
  to_stage     deal_stage not null,
  changed_by   uuid,
  changed_at   timestamptz not null default now()
);

create table deal_documents (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id) on delete cascade,
  deal_id      uuid not null references deals(id) on delete cascade,
  doc_type     text not null,        -- 'LOI','FCO','ICPO','SPA_BUYER','SPA_SUPPLIER','PROFORMA', ...
  version      int  not null default 1,
  status       doc_status not null default 'draft',
  file_path    text,
  signed_at    timestamptz,
  created_by   uuid references auth.users(id),
  created_at   timestamptz not null default now()
);

create table payment_instruments (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id) on delete cascade,
  deal_id      uuid not null references deals(id) on delete cascade,
  type         instrument_type not null,
  reference    text,
  amount       numeric,
  currency     text not null default 'USD',
  status       instrument_status not null default 'received',
  verified_by  uuid references auth.users(id),
  verified_at  timestamptz,
  created_at   timestamptz not null default now()
);

create table shipments (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references workspaces(id) on delete cascade,
  deal_id      uuid not null references deals(id) on delete cascade,
  mode         transport_mode not null default 'sea',
  carrier      text,
  booking_ref  text,
  transport_doc_type   text,          -- 'eBL','BL','AWB','CMR','RAIL'
  transport_doc_status transport_doc_status not null default 'draft',
  eta          date,
  created_at   timestamptz not null default now()
);

create table audit_log (
  id           bigint generated always as identity primary key,
  workspace_id uuid references workspaces(id) on delete cascade,
  actor        uuid,
  action       text not null,
  table_name   text,
  record_id    uuid,
  details      jsonb,
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 6. THE DEAL GATES (enforced in the database, not just the screen)
-- ---------------------------------------------------------------------
create or replace function public.enforce_deal_gates() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  o int; n int;
begin
  if new.stage = old.stage then return new; end if;

  o := array_position(enum_range(null::deal_stage), old.stage);
  n := array_position(enum_range(null::deal_stage), new.stage);
  if n <> o + 1 then
    raise exception 'STAGE GATE: deals move one stage at a time (% -> % not allowed)', old.stage, new.stage;
  end if;

  -- Gate 1: no trading before KYC (both sides approved)
  if not exists (select 1 from companies where id = new.buyer_company_id and kyc_status = 'approved')
     or not exists (select 1 from companies where id = new.supplier_company_id and kyc_status = 'approved') then
    raise exception 'KYC GATE: buyer and supplier must both be KYC-approved';
  end if;

  -- Gate 2: no loading/inspection instruction before a verified payment instrument
  if new.stage = 'inspection' and not exists (
       select 1 from payment_instruments where deal_id = new.id and status = 'verified') then
    raise exception 'PAYMENT GATE: no verified payment instrument on this deal';
  end if;

  -- Gate 3: no release of title documents before held doc + two different keys
  if new.stage = 'document_released' then
    if not exists (select 1 from shipments where deal_id = new.id and transport_doc_status = 'held') then
      raise exception 'RELEASE GATE: transport document is not held in custody';
    end if;
    if new.finance_confirmed_by is null or new.md_approved_by is null then
      raise exception 'RELEASE GATE: both finance confirmation and MD approval are required';
    end if;
    if new.finance_confirmed_by = new.md_approved_by then
      raise exception 'RELEASE GATE: two-key rule, finance and MD must be different people';
    end if;
    if not exists (select 1 from workspace_members
                   where workspace_id = new.workspace_id and user_id = new.finance_confirmed_by and role = 'finance') then
      raise exception 'RELEASE GATE: confirming user does not have the finance role';
    end if;
    if not exists (select 1 from workspace_members
                   where workspace_id = new.workspace_id and user_id = new.md_approved_by and role = 'owner') then
      raise exception 'RELEASE GATE: approving user is not the owner / MD';
    end if;
  end if;

  return new;
end $$;

create trigger trg_deal_gates before update of stage on deals
  for each row execute function public.enforce_deal_gates();

-- Every stage change is written to history and the audit log
create or replace function public.log_deal_stage() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into deal_stage_history (workspace_id, deal_id, from_stage, to_stage, changed_by)
  values (new.workspace_id, new.id, old.stage, new.stage, auth.uid());
  insert into audit_log (workspace_id, actor, action, table_name, record_id, details)
  values (new.workspace_id, auth.uid(), 'deal_stage_change', 'deals', new.id,
          jsonb_build_object('from', old.stage, 'to', new.stage));
  return new;
end $$;

create trigger trg_deal_history after update of stage on deals
  for each row when (old.stage is distinct from new.stage)
  execute function public.log_deal_stage();

-- ---------------------------------------------------------------------
-- 7. ROW LEVEL SECURITY (who can see which rows)
-- ---------------------------------------------------------------------
alter table workspaces        enable row level security;
alter table workspace_members enable row level security;

create policy "members_see_workspace" on workspaces for select to authenticated
  using (public.is_staff(id));
create policy "see_own_membership" on workspace_members for select to authenticated
  using (user_id = auth.uid());

-- Team members get full access inside their own workspace only.
-- (Role-specific limits, e.g. compliance-only KYC approval, come later.)
do $$
declare t text;
begin
  foreach t in array array['companies','company_users','kyc_documents','listings',
                           'deals','deal_documents','payment_instruments','shipments'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy "staff_all" on %I for all to authenticated
                    using (public.is_staff(workspace_id))
                    with check (public.is_staff(workspace_id))', t);
  end loop;
end $$;

-- History and audit are read-only for people (only triggers write to them)
alter table deal_stage_history enable row level security;
alter table audit_log          enable row level security;
create policy "staff_read" on deal_stage_history for select to authenticated using (public.is_staff(workspace_id));
create policy "staff_read" on audit_log          for select to authenticated using (public.is_staff(workspace_id));

-- External buyers/suppliers: only their own company's rows
create policy "own_link" on company_users for select to authenticated using (user_id = auth.uid());

create policy "own_company_read" on companies for select to authenticated
  using (id in (select company_id from company_users where user_id = auth.uid()));

create policy "own_kyc_read" on kyc_documents for select to authenticated
  using (company_id in (select company_id from company_users where user_id = auth.uid()));
create policy "own_kyc_insert" on kyc_documents for insert to authenticated
  with check (company_id in (select company_id from company_users where user_id = auth.uid()));

create policy "own_listing_read" on listings for select to authenticated
  using (company_id in (select company_id from company_users where user_id = auth.uid()));
create policy "own_listing_insert" on listings for insert to authenticated
  with check (status in ('draft','pending_review')
              and company_id in (select company_id from company_users where user_id = auth.uid()));

-- Deals, documents, payment and shipments stay staff-only for now.
-- Buyers/suppliers will see masked deal views in a later step.
