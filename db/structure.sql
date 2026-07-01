\restrict 9dhfWf7YRuBXEDAKE0g31EKQsqVoCpUZwQFYveXhGzem0oF3FRbwfj8JAVKE0CY

-- Dumped from database version 16.13 (Debian 16.13-1.pgdg12+1)
-- Dumped by pg_dump version 16.14

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pg_stat_statements; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;


--
-- Name: EXTENSION pg_stat_statements; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_stat_statements IS 'track planning and execution statistics of all SQL statements executed';


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: accounts_after_insert_row_tr(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.accounts_after_insert_row_tr() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    execute format('create sequence IF NOT EXISTS conv_dpid_seq_%s', NEW.id);
    RETURN NULL;
END;
$$;


--
-- Name: camp_dpid_before_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.camp_dpid_before_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    execute format('create sequence IF NOT EXISTS camp_dpid_seq_%s', NEW.id);
    RETURN NULL;
END;
$$;


--
-- Name: campaigns_before_insert_row_tr(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.campaigns_before_insert_row_tr() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.display_id := nextval('camp_dpid_seq_' || NEW.account_id);
    RETURN NEW;
END;
$$;


--
-- Name: conversations_before_insert_row_tr(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.conversations_before_insert_row_tr() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.display_id := nextval('conv_dpid_seq_' || NEW.account_id);
    RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: access_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.access_tokens (
    id bigint NOT NULL,
    owner_type character varying,
    owner_id bigint,
    token character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: access_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.access_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: access_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.access_tokens_id_seq OWNED BY public.access_tokens.id;


--
-- Name: account_saml_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_saml_settings (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    sso_url character varying,
    certificate text,
    sp_entity_id character varying,
    idp_entity_id character varying,
    role_mappings json DEFAULT '{}'::json,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: account_saml_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.account_saml_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: account_saml_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.account_saml_settings_id_seq OWNED BY public.account_saml_settings.id;


--
-- Name: account_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_users (
    id bigint NOT NULL,
    account_id bigint,
    user_id bigint,
    role integer DEFAULT 0,
    inviter_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    active_at timestamp without time zone,
    availability integer DEFAULT 0 NOT NULL,
    auto_offline boolean DEFAULT true NOT NULL,
    custom_role_id bigint,
    agent_capacity_policy_id bigint,
    active boolean DEFAULT true NOT NULL,
    receives_assignments boolean DEFAULT true NOT NULL
);


--
-- Name: account_users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.account_users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: account_users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.account_users_id_seq OWNED BY public.account_users.id;


--
-- Name: accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accounts (
    id integer NOT NULL,
    name character varying NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    locale integer DEFAULT 0,
    domain character varying(100),
    support_email character varying(100),
    feature_flags bigint DEFAULT 0 NOT NULL,
    auto_resolve_duration integer,
    limits jsonb DEFAULT '{}'::jsonb,
    custom_attributes jsonb DEFAULT '{}'::jsonb,
    status integer DEFAULT 0,
    internal_attributes jsonb DEFAULT '{}'::jsonb NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb
);


--
-- Name: accounts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.accounts_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: accounts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.accounts_id_seq OWNED BY public.accounts.id;


--
-- Name: action_mailbox_inbound_emails; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.action_mailbox_inbound_emails (
    id bigint NOT NULL,
    status integer DEFAULT 0 NOT NULL,
    message_id character varying NOT NULL,
    message_checksum character varying NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: action_mailbox_inbound_emails_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.action_mailbox_inbound_emails_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: action_mailbox_inbound_emails_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.action_mailbox_inbound_emails_id_seq OWNED BY public.action_mailbox_inbound_emails.id;


--
-- Name: active_storage_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_attachments (
    id bigint NOT NULL,
    name character varying NOT NULL,
    record_type character varying NOT NULL,
    record_id bigint NOT NULL,
    blob_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL
);


--
-- Name: active_storage_attachments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_attachments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_attachments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_attachments_id_seq OWNED BY public.active_storage_attachments.id;


--
-- Name: active_storage_blobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_blobs (
    id bigint NOT NULL,
    key character varying NOT NULL,
    filename character varying NOT NULL,
    content_type character varying,
    metadata text,
    byte_size bigint NOT NULL,
    checksum character varying,
    created_at timestamp without time zone NOT NULL,
    service_name character varying NOT NULL
);


--
-- Name: active_storage_blobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_blobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_blobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_blobs_id_seq OWNED BY public.active_storage_blobs.id;


--
-- Name: active_storage_variant_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.active_storage_variant_records (
    id bigint NOT NULL,
    blob_id bigint NOT NULL,
    variation_digest character varying NOT NULL
);


--
-- Name: active_storage_variant_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.active_storage_variant_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: active_storage_variant_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.active_storage_variant_records_id_seq OWNED BY public.active_storage_variant_records.id;


--
-- Name: agent_bot_inboxes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_bot_inboxes (
    id bigint NOT NULL,
    inbox_id integer,
    agent_bot_id integer,
    status integer DEFAULT 0,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    account_id integer
);


--
-- Name: agent_bot_inboxes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_bot_inboxes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_bot_inboxes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_bot_inboxes_id_seq OWNED BY public.agent_bot_inboxes.id;


--
-- Name: agent_bots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_bots (
    id bigint NOT NULL,
    name character varying,
    description character varying,
    outgoing_url character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    account_id bigint,
    bot_type integer DEFAULT 0,
    bot_config jsonb DEFAULT '{}'::jsonb,
    secret character varying
);


--
-- Name: agent_bots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_bots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_bots_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_bots_id_seq OWNED BY public.agent_bots.id;


--
-- Name: agent_capacity_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_capacity_policies (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    exclusion_rules jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: agent_capacity_policies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_capacity_policies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_capacity_policies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_capacity_policies_id_seq OWNED BY public.agent_capacity_policies.id;


--
-- Name: agent_schedules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agent_schedules (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    account_id bigint NOT NULL,
    day_of_week integer NOT NULL,
    closed_all_day boolean DEFAULT false NOT NULL,
    open_all_day boolean DEFAULT false NOT NULL,
    open_hour integer,
    open_minutes integer,
    close_hour integer,
    close_minutes integer,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: agent_schedules_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.agent_schedules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: agent_schedules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.agent_schedules_id_seq OWNED BY public.agent_schedules.id;


--
-- Name: ai_agent_inboxes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_agent_inboxes (
    id bigint NOT NULL,
    ai_agent_id bigint NOT NULL,
    inbox_id bigint NOT NULL,
    mode character varying DEFAULT 'shadow'::character varying NOT NULL,
    active boolean DEFAULT true NOT NULL,
    priority integer DEFAULT 1 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_agent_inboxes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_agent_inboxes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_agent_inboxes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_agent_inboxes_id_seq OWNED BY public.ai_agent_inboxes.id;


--
-- Name: ai_agent_memory; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_agent_memory (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    ai_agent_id bigint NOT NULL,
    state jsonb DEFAULT '{}'::jsonb NOT NULL,
    summary text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_agent_memory_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_agent_memory_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_agent_memory_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_agent_memory_id_seq OWNED BY public.ai_agent_memory.id;


--
-- Name: ai_agent_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_agent_versions (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    ai_agent_id bigint NOT NULL,
    version_number integer DEFAULT 1 NOT NULL,
    snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    note character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_agent_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_agent_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_agent_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_agent_versions_id_seq OWNED BY public.ai_agent_versions.id;


--
-- Name: ai_agents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_agents (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    ai_operation_profile_id bigint,
    name character varying NOT NULL,
    stage character varying DEFAULT 'sandbox'::character varying NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    assistant_name character varying,
    assistant_avatar text,
    assistant_description text,
    assistant_personality text,
    assistant_language character varying DEFAULT 'pt-BR'::character varying,
    assistant_voice character varying,
    base_prompt text,
    guardrails text,
    identity jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    company_name character varying,
    site character varying,
    version character varying,
    identify_as character varying DEFAULT 'ai'::character varying,
    category character varying,
    team_id bigint,
    handoff_team_ids jsonb DEFAULT '[]'::jsonb NOT NULL,
    handoff_agent_ids jsonb DEFAULT '[]'::jsonb NOT NULL
);


--
-- Name: ai_agents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_agents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_agents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_agents_id_seq OWNED BY public.ai_agents.id;


--
-- Name: ai_capability_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_capability_executions (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    conversation_id bigint,
    ai_tool_id bigint,
    ai_run_id bigint,
    capability_key character varying NOT NULL,
    input jsonb DEFAULT '{}'::jsonb NOT NULL,
    output jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying DEFAULT 'pending'::character varying NOT NULL,
    governance character varying DEFAULT 'allowed'::character varying NOT NULL,
    approval_status character varying DEFAULT 'not_required'::character varying NOT NULL,
    requested_by character varying DEFAULT 'ai'::character varying NOT NULL,
    approved_by_user_id bigint,
    rollback_data jsonb DEFAULT '{}'::jsonb NOT NULL,
    error text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_capability_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_capability_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_capability_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_capability_executions_id_seq OWNED BY public.ai_capability_executions.id;


--
-- Name: ai_department_inboxes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_department_inboxes (
    id bigint NOT NULL,
    ai_department_id bigint NOT NULL,
    inbox_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_department_inboxes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_department_inboxes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_department_inboxes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_department_inboxes_id_seq OWNED BY public.ai_department_inboxes.id;


--
-- Name: ai_department_integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_department_integrations (
    id bigint NOT NULL,
    ai_department_id bigint NOT NULL,
    ai_integration_link_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_department_integrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_department_integrations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_department_integrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_department_integrations_id_seq OWNED BY public.ai_department_integrations.id;


--
-- Name: ai_departments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_departments (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    ai_agent_id bigint NOT NULL,
    name character varying NOT NULL,
    objetivo text,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    sla jsonb DEFAULT '{}'::jsonb NOT NULL,
    transfer_rules jsonb DEFAULT '{}'::jsonb NOT NULL,
    close_rules jsonb DEFAULT '{}'::jsonb NOT NULL,
    copilot_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    auto_attendance_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    behavior jsonb DEFAULT '{}'::jsonb NOT NULL,
    follow_up jsonb DEFAULT '{}'::jsonb NOT NULL,
    instructions text,
    is_default boolean DEFAULT false NOT NULL,
    "position" integer DEFAULT 0 NOT NULL
);


--
-- Name: ai_departments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_departments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_departments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_departments_id_seq OWNED BY public.ai_departments.id;


--
-- Name: ai_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_events (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    conversation_id bigint,
    ai_run_id bigint,
    parent_event_id bigint,
    event_type character varying NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying DEFAULT 'ok'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_events_id_seq OWNED BY public.ai_events.id;


--
-- Name: ai_integration_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_integration_links (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    name character varying NOT NULL,
    kind character varying DEFAULT 'webhook'::character varying NOT NULL,
    endpoint character varying,
    http_method character varying DEFAULT 'POST'::character varying NOT NULL,
    auth jsonb DEFAULT '{}'::jsonb NOT NULL,
    headers jsonb DEFAULT '{}'::jsonb NOT NULL,
    payload_template jsonb DEFAULT '{}'::jsonb NOT NULL,
    retry_count integer DEFAULT 0 NOT NULL,
    timeout_seconds integer DEFAULT 10 NOT NULL,
    cost numeric(12,6) DEFAULT 0.0 NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_integration_links_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_integration_links_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_integration_links_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_integration_links_id_seq OWNED BY public.ai_integration_links.id;


--
-- Name: ai_knowledge_chunks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_knowledge_chunks (
    id bigint NOT NULL,
    ai_knowledge_source_id bigint NOT NULL,
    content text NOT NULL,
    embedding public.vector(1536),
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_knowledge_chunks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_knowledge_chunks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_knowledge_chunks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_knowledge_chunks_id_seq OWNED BY public.ai_knowledge_chunks.id;


--
-- Name: ai_knowledge_sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_knowledge_sources (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    ai_department_id bigint,
    kind character varying DEFAULT 'faq'::character varying NOT NULL,
    title character varying,
    raw text,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    price character varying
);


--
-- Name: ai_knowledge_sources_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_knowledge_sources_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_knowledge_sources_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_knowledge_sources_id_seq OWNED BY public.ai_knowledge_sources.id;


--
-- Name: ai_lead_variables; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_lead_variables (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    ai_department_id bigint NOT NULL,
    name character varying NOT NULL,
    description text,
    var_type character varying DEFAULT 'texto'::character varying NOT NULL,
    "values" jsonb DEFAULT '[]'::jsonb NOT NULL,
    visible_in_first_chat boolean DEFAULT false NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_lead_variables_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_lead_variables_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_lead_variables_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_lead_variables_id_seq OWNED BY public.ai_lead_variables.id;


--
-- Name: ai_operation_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_operation_profiles (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    name character varying NOT NULL,
    supervisor_provider character varying NOT NULL,
    supervisor_model character varying NOT NULL,
    worker_overrides jsonb DEFAULT '{}'::jsonb NOT NULL,
    budget jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    routing_strategy jsonb DEFAULT '{}'::jsonb NOT NULL,
    tier character varying DEFAULT 'customizado'::character varying NOT NULL
);


--
-- Name: ai_operation_profiles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_operation_profiles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_operation_profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_operation_profiles_id_seq OWNED BY public.ai_operation_profiles.id;


--
-- Name: ai_playbook_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_playbook_versions (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    ai_department_id bigint NOT NULL,
    ai_playbook_id bigint,
    version_number integer DEFAULT 1 NOT NULL,
    snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    note character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_playbook_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_playbook_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_playbook_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_playbook_versions_id_seq OWNED BY public.ai_playbook_versions.id;


--
-- Name: ai_playbooks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_playbooks (
    id bigint NOT NULL,
    ai_department_id bigint NOT NULL,
    objetivo text,
    steps jsonb DEFAULT '[]'::jsonb NOT NULL,
    transfer_when jsonb DEFAULT '[]'::jsonb NOT NULL,
    close_when jsonb DEFAULT '[]'::jsonb NOT NULL,
    default_messages jsonb DEFAULT '{}'::jsonb NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_playbooks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_playbooks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_playbooks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_playbooks_id_seq OWNED BY public.ai_playbooks.id;


--
-- Name: ai_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_runs (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    conversation_id bigint,
    ai_agent_id bigint,
    run_type character varying DEFAULT 'decision'::character varying NOT NULL,
    mode character varying DEFAULT 'shadow'::character varying NOT NULL,
    provider character varying,
    model character varying,
    tokens_in integer DEFAULT 0 NOT NULL,
    tokens_out integer DEFAULT 0 NOT NULL,
    cost numeric(12,6) DEFAULT 0.0 NOT NULL,
    latency_ms integer,
    decision jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying DEFAULT 'recorded'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    ai_department_id bigint,
    inbox_id bigint,
    routing_band character varying,
    worker character varying,
    error_type character varying,
    knowledge_count integer DEFAULT 0 NOT NULL
);


--
-- Name: ai_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_runs_id_seq OWNED BY public.ai_runs.id;


--
-- Name: ai_shadow_inboxes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_shadow_inboxes (
    id bigint NOT NULL,
    ai_shadow_id bigint NOT NULL,
    inbox_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_shadow_inboxes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_shadow_inboxes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_shadow_inboxes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_shadow_inboxes_id_seq OWNED BY public.ai_shadow_inboxes.id;


--
-- Name: ai_shadows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_shadows (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    name character varying NOT NULL,
    instructions text,
    scope jsonb DEFAULT '{}'::jsonb NOT NULL,
    data_signals jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ai_shadows_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_shadows_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_shadows_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_shadows_id_seq OWNED BY public.ai_shadows.id;


--
-- Name: ai_tools; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_tools (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    ai_department_id bigint,
    name character varying NOT NULL,
    description text,
    implementation_type character varying DEFAULT 'capability'::character varying NOT NULL,
    capability_key character varying,
    integration_link_id bigint,
    input_schema jsonb DEFAULT '{}'::jsonb NOT NULL,
    output_schema jsonb DEFAULT '{}'::jsonb NOT NULL,
    status character varying DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    webhook_config jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: ai_tools_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.ai_tools_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: ai_tools_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.ai_tools_id_seq OWNED BY public.ai_tools.id;


--
-- Name: applied_slas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.applied_slas (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    sla_policy_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    sla_status integer DEFAULT 0
);


--
-- Name: applied_slas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.applied_slas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: applied_slas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.applied_slas_id_seq OWNED BY public.applied_slas.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: article_embeddings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.article_embeddings (
    id bigint NOT NULL,
    article_id bigint NOT NULL,
    term text NOT NULL,
    embedding public.vector(1536),
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: article_embeddings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.article_embeddings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: article_embeddings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.article_embeddings_id_seq OWNED BY public.article_embeddings.id;


--
-- Name: articles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.articles (
    id bigint NOT NULL,
    account_id integer NOT NULL,
    portal_id integer NOT NULL,
    category_id integer,
    folder_id integer,
    title character varying,
    description text,
    content text,
    status integer,
    views integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    author_id bigint,
    associated_article_id bigint,
    meta jsonb DEFAULT '{}'::jsonb,
    slug character varying NOT NULL,
    "position" integer,
    locale character varying DEFAULT 'en'::character varying NOT NULL
);


--
-- Name: articles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.articles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: articles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.articles_id_seq OWNED BY public.articles.id;


--
-- Name: assignment_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.assignment_policies (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    assignment_order integer DEFAULT 0 NOT NULL,
    conversation_priority integer DEFAULT 0 NOT NULL,
    fair_distribution_limit integer DEFAULT 100 NOT NULL,
    fair_distribution_window integer DEFAULT 3600 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: assignment_policies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.assignment_policies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: assignment_policies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.assignment_policies_id_seq OWNED BY public.assignment_policies.id;


--
-- Name: attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attachments (
    id integer NOT NULL,
    file_type integer DEFAULT 0,
    external_url character varying,
    coordinates_lat double precision DEFAULT 0.0,
    coordinates_long double precision DEFAULT 0.0,
    message_id integer NOT NULL,
    account_id integer NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    fallback_title character varying,
    extension character varying,
    meta jsonb DEFAULT '{}'::jsonb
);


--
-- Name: attachments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.attachments_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: attachments_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.attachments_id_seq OWNED BY public.attachments.id;


--
-- Name: audits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audits (
    id bigint NOT NULL,
    auditable_id bigint,
    auditable_type character varying,
    associated_id bigint,
    associated_type character varying,
    user_id bigint,
    user_type character varying,
    username character varying,
    action character varying,
    audited_changes jsonb,
    version integer DEFAULT 0,
    comment character varying,
    remote_address character varying,
    request_uuid character varying,
    created_at timestamp without time zone
);


--
-- Name: audits_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audits_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audits_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audits_id_seq OWNED BY public.audits.id;


--
-- Name: automation_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.automation_rules (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    name character varying NOT NULL,
    description text,
    event_name character varying NOT NULL,
    conditions jsonb DEFAULT '"{}"'::jsonb NOT NULL,
    actions jsonb DEFAULT '"{}"'::jsonb NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    active boolean DEFAULT true NOT NULL
);


--
-- Name: automation_rules_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.automation_rules_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: automation_rules_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.automation_rules_id_seq OWNED BY public.automation_rules.id;


--
-- Name: calls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.calls (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    inbox_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    contact_id bigint NOT NULL,
    message_id bigint,
    accepted_by_agent_id bigint,
    provider_call_id character varying NOT NULL,
    provider integer DEFAULT 0 NOT NULL,
    direction integer NOT NULL,
    status character varying DEFAULT 'ringing'::character varying NOT NULL,
    started_at timestamp(6) without time zone,
    duration_seconds integer,
    end_reason character varying,
    meta jsonb DEFAULT '{}'::jsonb,
    transcript text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: calls_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.calls_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: calls_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.calls_id_seq OWNED BY public.calls.id;


--
-- Name: campaigns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.campaigns (
    id bigint NOT NULL,
    display_id integer NOT NULL,
    title character varying NOT NULL,
    description text,
    message text NOT NULL,
    sender_id integer,
    enabled boolean DEFAULT true,
    account_id bigint NOT NULL,
    inbox_id bigint NOT NULL,
    trigger_rules jsonb DEFAULT '{}'::jsonb,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    campaign_type integer DEFAULT 0 NOT NULL,
    campaign_status integer DEFAULT 0 NOT NULL,
    audience jsonb DEFAULT '[]'::jsonb,
    scheduled_at timestamp without time zone,
    trigger_only_during_business_hours boolean DEFAULT false,
    template_params jsonb
);


--
-- Name: campaigns_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.campaigns_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: campaigns_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.campaigns_id_seq OWNED BY public.campaigns.id;


--
-- Name: canned_responses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.canned_responses (
    id integer NOT NULL,
    account_id integer NOT NULL,
    short_code character varying,
    content text,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: canned_responses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.canned_responses_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: canned_responses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.canned_responses_id_seq OWNED BY public.canned_responses.id;


--
-- Name: captain_assistant_responses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.captain_assistant_responses (
    id bigint NOT NULL,
    question character varying NOT NULL,
    answer text NOT NULL,
    embedding public.vector(1536),
    assistant_id bigint NOT NULL,
    documentable_id bigint,
    account_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    status integer DEFAULT 1 NOT NULL,
    documentable_type character varying,
    edited boolean DEFAULT false NOT NULL
);


--
-- Name: captain_assistant_responses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.captain_assistant_responses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: captain_assistant_responses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.captain_assistant_responses_id_seq OWNED BY public.captain_assistant_responses.id;


--
-- Name: captain_assistants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.captain_assistants (
    id bigint NOT NULL,
    name character varying NOT NULL,
    account_id bigint NOT NULL,
    description character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    response_guidelines jsonb DEFAULT '[]'::jsonb,
    guardrails jsonb DEFAULT '[]'::jsonb
);


--
-- Name: captain_assistants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.captain_assistants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: captain_assistants_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.captain_assistants_id_seq OWNED BY public.captain_assistants.id;


--
-- Name: captain_custom_tools; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.captain_custom_tools (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    slug character varying NOT NULL,
    title character varying NOT NULL,
    description text,
    http_method character varying DEFAULT 'GET'::character varying NOT NULL,
    endpoint_url text NOT NULL,
    request_template text,
    response_template text,
    auth_type character varying DEFAULT 'none'::character varying,
    auth_config jsonb DEFAULT '{}'::jsonb,
    param_schema jsonb DEFAULT '[]'::jsonb,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: captain_custom_tools_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.captain_custom_tools_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: captain_custom_tools_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.captain_custom_tools_id_seq OWNED BY public.captain_custom_tools.id;


--
-- Name: captain_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.captain_documents (
    id bigint NOT NULL,
    name character varying,
    external_link character varying NOT NULL,
    content text,
    assistant_id bigint NOT NULL,
    account_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    status integer DEFAULT 0 NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb,
    sync_status integer,
    last_synced_at timestamp(6) without time zone,
    last_sync_attempted_at timestamp(6) without time zone
);


--
-- Name: captain_documents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.captain_documents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: captain_documents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.captain_documents_id_seq OWNED BY public.captain_documents.id;


--
-- Name: captain_inboxes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.captain_inboxes (
    id bigint NOT NULL,
    captain_assistant_id bigint NOT NULL,
    inbox_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: captain_inboxes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.captain_inboxes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: captain_inboxes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.captain_inboxes_id_seq OWNED BY public.captain_inboxes.id;


--
-- Name: captain_scenarios; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.captain_scenarios (
    id bigint NOT NULL,
    title character varying,
    description text,
    instruction text,
    tools jsonb DEFAULT '[]'::jsonb,
    enabled boolean DEFAULT true NOT NULL,
    assistant_id bigint NOT NULL,
    account_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: captain_scenarios_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.captain_scenarios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: captain_scenarios_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.captain_scenarios_id_seq OWNED BY public.captain_scenarios.id;


--
-- Name: categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.categories (
    id bigint NOT NULL,
    account_id integer NOT NULL,
    portal_id integer NOT NULL,
    name character varying,
    description text,
    "position" integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    locale character varying DEFAULT 'en'::character varying,
    slug character varying NOT NULL,
    parent_category_id bigint,
    associated_category_id bigint,
    icon character varying DEFAULT ''::character varying
);


--
-- Name: categories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: categories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.categories_id_seq OWNED BY public.categories.id;


--
-- Name: channel_api; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_api (
    id bigint NOT NULL,
    account_id integer NOT NULL,
    webhook_url character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    identifier character varying,
    hmac_token character varying,
    hmac_mandatory boolean DEFAULT false,
    additional_attributes jsonb DEFAULT '{}'::jsonb,
    secret character varying
);


--
-- Name: channel_api_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.channel_api_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: channel_api_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.channel_api_id_seq OWNED BY public.channel_api.id;


--
-- Name: channel_email; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_email (
    id bigint NOT NULL,
    account_id integer NOT NULL,
    email character varying NOT NULL,
    forward_to_email character varying NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    imap_enabled boolean DEFAULT false,
    imap_address character varying DEFAULT ''::character varying,
    imap_port integer DEFAULT 0,
    imap_login character varying DEFAULT ''::character varying,
    imap_password character varying DEFAULT ''::character varying,
    imap_enable_ssl boolean DEFAULT true,
    smtp_enabled boolean DEFAULT false,
    smtp_address character varying DEFAULT ''::character varying,
    smtp_port integer DEFAULT 0,
    smtp_login character varying DEFAULT ''::character varying,
    smtp_password character varying DEFAULT ''::character varying,
    smtp_domain character varying DEFAULT ''::character varying,
    smtp_enable_starttls_auto boolean DEFAULT true,
    smtp_authentication character varying DEFAULT 'login'::character varying,
    smtp_openssl_verify_mode character varying DEFAULT 'none'::character varying,
    smtp_enable_ssl_tls boolean DEFAULT false,
    provider_config jsonb DEFAULT '{}'::jsonb,
    provider character varying,
    verified_for_sending boolean DEFAULT false NOT NULL
);


--
-- Name: channel_email_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.channel_email_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: channel_email_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.channel_email_id_seq OWNED BY public.channel_email.id;


--
-- Name: channel_facebook_pages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_facebook_pages (
    id integer NOT NULL,
    page_id character varying NOT NULL,
    user_access_token character varying NOT NULL,
    page_access_token character varying NOT NULL,
    account_id integer NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    instagram_id character varying
);


--
-- Name: channel_facebook_pages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.channel_facebook_pages_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: channel_facebook_pages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.channel_facebook_pages_id_seq OWNED BY public.channel_facebook_pages.id;


--
-- Name: channel_instagram; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_instagram (
    id bigint NOT NULL,
    access_token character varying NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    account_id integer NOT NULL,
    instagram_id character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: channel_instagram_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.channel_instagram_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: channel_instagram_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.channel_instagram_id_seq OWNED BY public.channel_instagram.id;


--
-- Name: channel_line; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_line (
    id bigint NOT NULL,
    account_id integer NOT NULL,
    line_channel_id character varying NOT NULL,
    line_channel_secret character varying NOT NULL,
    line_channel_token character varying NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: channel_line_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.channel_line_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: channel_line_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.channel_line_id_seq OWNED BY public.channel_line.id;


--
-- Name: channel_sms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_sms (
    id bigint NOT NULL,
    account_id integer NOT NULL,
    phone_number character varying NOT NULL,
    provider character varying DEFAULT 'default'::character varying,
    provider_config jsonb DEFAULT '{}'::jsonb,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: channel_sms_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.channel_sms_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: channel_sms_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.channel_sms_id_seq OWNED BY public.channel_sms.id;


--
-- Name: channel_telegram; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_telegram (
    id bigint NOT NULL,
    bot_name character varying,
    account_id integer NOT NULL,
    bot_token character varying NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: channel_telegram_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.channel_telegram_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: channel_telegram_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.channel_telegram_id_seq OWNED BY public.channel_telegram.id;


--
-- Name: channel_tiktok; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_tiktok (
    id bigint NOT NULL,
    account_id integer NOT NULL,
    business_id character varying NOT NULL,
    access_token character varying NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    refresh_token character varying NOT NULL,
    refresh_token_expires_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: channel_tiktok_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.channel_tiktok_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: channel_tiktok_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.channel_tiktok_id_seq OWNED BY public.channel_tiktok.id;


--
-- Name: channel_twilio_sms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_twilio_sms (
    id bigint NOT NULL,
    phone_number character varying,
    auth_token character varying NOT NULL,
    account_sid character varying NOT NULL,
    account_id integer NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    medium integer DEFAULT 0,
    messaging_service_sid character varying,
    api_key_sid character varying,
    content_templates jsonb DEFAULT '{}'::jsonb,
    content_templates_last_updated timestamp(6) without time zone
);


--
-- Name: channel_twilio_sms_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.channel_twilio_sms_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: channel_twilio_sms_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.channel_twilio_sms_id_seq OWNED BY public.channel_twilio_sms.id;


--
-- Name: channel_twitter_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_twitter_profiles (
    id bigint NOT NULL,
    profile_id character varying NOT NULL,
    twitter_access_token character varying NOT NULL,
    twitter_access_token_secret character varying NOT NULL,
    account_id integer NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    tweets_enabled boolean DEFAULT true
);


--
-- Name: channel_twitter_profiles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.channel_twitter_profiles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: channel_twitter_profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.channel_twitter_profiles_id_seq OWNED BY public.channel_twitter_profiles.id;


--
-- Name: channel_voice; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_voice (
    id bigint NOT NULL,
    phone_number character varying NOT NULL,
    provider character varying DEFAULT 'twilio'::character varying NOT NULL,
    provider_config jsonb NOT NULL,
    account_id integer NOT NULL,
    additional_attributes jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: channel_voice_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.channel_voice_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: channel_voice_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.channel_voice_id_seq OWNED BY public.channel_voice.id;


--
-- Name: channel_web_widgets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_web_widgets (
    id integer NOT NULL,
    website_url character varying,
    account_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    website_token character varying,
    widget_color character varying DEFAULT '#1f93ff'::character varying,
    welcome_title character varying,
    welcome_tagline character varying,
    feature_flags integer DEFAULT 7 NOT NULL,
    reply_time integer DEFAULT 0,
    hmac_token character varying,
    pre_chat_form_enabled boolean DEFAULT false,
    pre_chat_form_options jsonb DEFAULT '{}'::jsonb,
    hmac_mandatory boolean DEFAULT false,
    continuity_via_email boolean DEFAULT true NOT NULL,
    allowed_domains text DEFAULT ''::text
);


--
-- Name: channel_web_widgets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.channel_web_widgets_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: channel_web_widgets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.channel_web_widgets_id_seq OWNED BY public.channel_web_widgets.id;


--
-- Name: channel_whatsapp; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_whatsapp (
    id bigint NOT NULL,
    account_id integer NOT NULL,
    phone_number character varying NOT NULL,
    provider character varying DEFAULT 'default'::character varying,
    provider_config jsonb DEFAULT '{}'::jsonb,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    message_templates jsonb DEFAULT '{}'::jsonb,
    message_templates_last_updated timestamp without time zone
);


--
-- Name: channel_whatsapp_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.channel_whatsapp_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: channel_whatsapp_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.channel_whatsapp_id_seq OWNED BY public.channel_whatsapp.id;


--
-- Name: closing_requirements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.closing_requirements (
    id bigint NOT NULL,
    operational_flow_id bigint NOT NULL,
    attribute_key character varying NOT NULL,
    condition jsonb DEFAULT '{}'::jsonb NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: closing_requirements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.closing_requirements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: closing_requirements_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.closing_requirements_id_seq OWNED BY public.closing_requirements.id;


--
-- Name: companies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.companies (
    id bigint NOT NULL,
    name character varying NOT NULL,
    domain character varying,
    description text,
    account_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    contacts_count integer DEFAULT 0 NOT NULL
);


--
-- Name: companies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.companies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: companies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.companies_id_seq OWNED BY public.companies.id;


--
-- Name: contact_inboxes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contact_inboxes (
    id bigint NOT NULL,
    contact_id bigint,
    inbox_id bigint,
    source_id text NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    hmac_verified boolean DEFAULT false,
    pubsub_token character varying
);


--
-- Name: contact_inboxes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contact_inboxes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contact_inboxes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contact_inboxes_id_seq OWNED BY public.contact_inboxes.id;


--
-- Name: contacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contacts (
    id integer NOT NULL,
    name character varying DEFAULT ''::character varying,
    email character varying,
    phone_number character varying,
    account_id integer NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    additional_attributes jsonb DEFAULT '{}'::jsonb,
    identifier character varying,
    custom_attributes jsonb DEFAULT '{}'::jsonb,
    last_activity_at timestamp without time zone,
    contact_type integer DEFAULT 0,
    middle_name character varying DEFAULT ''::character varying,
    last_name character varying DEFAULT ''::character varying,
    location character varying DEFAULT ''::character varying,
    country_code character varying DEFAULT ''::character varying,
    blocked boolean DEFAULT false NOT NULL,
    company_id bigint
);


--
-- Name: contacts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.contacts_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: contacts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.contacts_id_seq OWNED BY public.contacts.id;


--
-- Name: conversation_participants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversation_participants (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    user_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: conversation_participants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.conversation_participants_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: conversation_participants_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.conversation_participants_id_seq OWNED BY public.conversation_participants.id;


--
-- Name: conversation_result_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversation_result_events (
    id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    account_id bigint NOT NULL,
    inbox_id bigint,
    team_id bigint,
    user_id bigint,
    result integer DEFAULT 0 NOT NULL,
    previous_result integer,
    result_reason character varying,
    event_type character varying DEFAULT 'set'::character varying NOT NULL,
    ip_address character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    result_category character varying,
    result_canonical_key character varying
);


--
-- Name: conversation_result_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.conversation_result_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: conversation_result_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.conversation_result_events_id_seq OWNED BY public.conversation_result_events.id;


--
-- Name: conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversations (
    id integer NOT NULL,
    account_id integer NOT NULL,
    inbox_id integer NOT NULL,
    status integer DEFAULT 0 NOT NULL,
    assignee_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    contact_id bigint,
    display_id integer NOT NULL,
    contact_last_seen_at timestamp without time zone,
    agent_last_seen_at timestamp without time zone,
    additional_attributes jsonb DEFAULT '{}'::jsonb,
    contact_inbox_id bigint,
    uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    identifier character varying,
    last_activity_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    team_id bigint,
    campaign_id bigint,
    snoozed_until timestamp without time zone,
    custom_attributes jsonb DEFAULT '{}'::jsonb,
    assignee_last_seen_at timestamp without time zone,
    first_reply_created_at timestamp without time zone,
    priority integer,
    sla_policy_id bigint,
    waiting_since timestamp(6) without time zone,
    cached_label_list text,
    assignee_agent_bot_id bigint,
    result integer DEFAULT 0 NOT NULL,
    result_reason character varying,
    result_set_at timestamp(6) without time zone,
    result_set_by_id bigint,
    closed_by_ai boolean DEFAULT false NOT NULL,
    result_category character varying,
    result_canonical_key character varying
);


--
-- Name: conversations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.conversations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: conversations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.conversations_id_seq OWNED BY public.conversations.id;


--
-- Name: copilot_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.copilot_messages (
    id bigint NOT NULL,
    copilot_thread_id bigint NOT NULL,
    account_id bigint NOT NULL,
    message jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    message_type integer DEFAULT 0
);


--
-- Name: copilot_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.copilot_messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: copilot_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.copilot_messages_id_seq OWNED BY public.copilot_messages.id;


--
-- Name: copilot_threads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.copilot_threads (
    id bigint NOT NULL,
    title character varying NOT NULL,
    user_id bigint NOT NULL,
    account_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    assistant_id integer
);


--
-- Name: copilot_threads_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.copilot_threads_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: copilot_threads_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.copilot_threads_id_seq OWNED BY public.copilot_threads.id;


--
-- Name: csat_survey_responses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.csat_survey_responses (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    message_id bigint NOT NULL,
    rating integer NOT NULL,
    feedback_message text,
    contact_id bigint NOT NULL,
    assigned_agent_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    csat_review_notes text,
    review_notes_updated_at timestamp(6) without time zone,
    review_notes_updated_by_id bigint
);


--
-- Name: csat_survey_responses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.csat_survey_responses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: csat_survey_responses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.csat_survey_responses_id_seq OWNED BY public.csat_survey_responses.id;


--
-- Name: custom_attribute_definitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.custom_attribute_definitions (
    id bigint NOT NULL,
    attribute_display_name character varying,
    attribute_key character varying,
    attribute_display_type integer DEFAULT 0,
    default_value integer,
    attribute_model integer DEFAULT 0,
    account_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    attribute_description text,
    attribute_values jsonb DEFAULT '[]'::jsonb,
    regex_pattern character varying,
    regex_cue character varying
);


--
-- Name: custom_attribute_definitions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.custom_attribute_definitions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: custom_attribute_definitions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.custom_attribute_definitions_id_seq OWNED BY public.custom_attribute_definitions.id;


--
-- Name: custom_filters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.custom_filters (
    id bigint NOT NULL,
    name character varying NOT NULL,
    filter_type integer DEFAULT 0 NOT NULL,
    query jsonb DEFAULT '"{}"'::jsonb NOT NULL,
    account_id bigint NOT NULL,
    user_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: custom_filters_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.custom_filters_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: custom_filters_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.custom_filters_id_seq OWNED BY public.custom_filters.id;


--
-- Name: custom_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.custom_roles (
    id bigint NOT NULL,
    name character varying,
    description character varying,
    account_id bigint NOT NULL,
    permissions text[] DEFAULT '{}'::text[],
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    scope_type character varying DEFAULT 'all'::character varying NOT NULL,
    scope_ids integer[] DEFAULT '{}'::integer[],
    visibility_scope character varying,
    can_view_unassigned_queue boolean DEFAULT true NOT NULL
);


--
-- Name: custom_roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.custom_roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: custom_roles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.custom_roles_id_seq OWNED BY public.custom_roles.id;


--
-- Name: dashboard_apps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dashboard_apps (
    id bigint NOT NULL,
    title character varying NOT NULL,
    content jsonb DEFAULT '[]'::jsonb,
    account_id bigint NOT NULL,
    user_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: dashboard_apps_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.dashboard_apps_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: dashboard_apps_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.dashboard_apps_id_seq OWNED BY public.dashboard_apps.id;


--
-- Name: data_imports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.data_imports (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    data_type character varying NOT NULL,
    status integer DEFAULT 0 NOT NULL,
    processing_errors text,
    total_records integer,
    processed_records integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: data_imports_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.data_imports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: data_imports_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.data_imports_id_seq OWNED BY public.data_imports.id;


--
-- Name: email_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_templates (
    id bigint NOT NULL,
    name character varying NOT NULL,
    body text NOT NULL,
    account_id integer,
    template_type integer DEFAULT 1,
    locale integer DEFAULT 0 NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: email_templates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_templates_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_templates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_templates_id_seq OWNED BY public.email_templates.id;


--
-- Name: folders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.folders (
    id bigint NOT NULL,
    account_id integer NOT NULL,
    category_id integer NOT NULL,
    name character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: folders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.folders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: folders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.folders_id_seq OWNED BY public.folders.id;


--
-- Name: inbox_assignment_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inbox_assignment_policies (
    id bigint NOT NULL,
    inbox_id bigint NOT NULL,
    assignment_policy_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: inbox_assignment_policies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.inbox_assignment_policies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: inbox_assignment_policies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.inbox_assignment_policies_id_seq OWNED BY public.inbox_assignment_policies.id;


--
-- Name: inbox_capacity_limits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inbox_capacity_limits (
    id bigint NOT NULL,
    agent_capacity_policy_id bigint NOT NULL,
    inbox_id bigint NOT NULL,
    conversation_limit integer NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: inbox_capacity_limits_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.inbox_capacity_limits_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: inbox_capacity_limits_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.inbox_capacity_limits_id_seq OWNED BY public.inbox_capacity_limits.id;


--
-- Name: inbox_exceptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inbox_exceptions (
    id bigint NOT NULL,
    inbox_id bigint NOT NULL,
    account_id bigint,
    name character varying,
    exception_date date NOT NULL,
    closed boolean DEFAULT false NOT NULL,
    periods jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: inbox_exceptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.inbox_exceptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: inbox_exceptions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.inbox_exceptions_id_seq OWNED BY public.inbox_exceptions.id;


--
-- Name: inbox_holidays; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inbox_holidays (
    id bigint NOT NULL,
    inbox_id bigint NOT NULL,
    account_id bigint,
    name character varying NOT NULL,
    holiday_month integer NOT NULL,
    holiday_day integer NOT NULL,
    holiday_year integer,
    recurring boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: inbox_holidays_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.inbox_holidays_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: inbox_holidays_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.inbox_holidays_id_seq OWNED BY public.inbox_holidays.id;


--
-- Name: inbox_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inbox_members (
    id integer NOT NULL,
    user_id integer NOT NULL,
    inbox_id integer NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    eligible_for_assignment boolean DEFAULT true NOT NULL
);


--
-- Name: inbox_members_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.inbox_members_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: inbox_members_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.inbox_members_id_seq OWNED BY public.inbox_members.id;


--
-- Name: inboxes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inboxes (
    id integer NOT NULL,
    channel_id integer NOT NULL,
    account_id integer NOT NULL,
    name character varying NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    channel_type character varying,
    enable_auto_assignment boolean DEFAULT true,
    greeting_enabled boolean DEFAULT false,
    greeting_message character varying,
    email_address character varying,
    working_hours_enabled boolean DEFAULT false,
    out_of_office_message character varying,
    timezone character varying DEFAULT 'UTC'::character varying,
    enable_email_collect boolean DEFAULT true,
    csat_survey_enabled boolean DEFAULT false,
    allow_messages_after_resolved boolean DEFAULT true,
    auto_assignment_config jsonb DEFAULT '{}'::jsonb,
    lock_to_single_conversation boolean DEFAULT false NOT NULL,
    portal_id bigint,
    sender_name_type integer DEFAULT 0 NOT NULL,
    business_name character varying,
    csat_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    interval_message character varying,
    holiday_message character varying,
    operational_flow_id bigint,
    reopen_window_hours integer DEFAULT 0 NOT NULL
);


--
-- Name: inboxes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.inboxes_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: inboxes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.inboxes_id_seq OWNED BY public.inboxes.id;


--
-- Name: installation_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.installation_configs (
    id bigint NOT NULL,
    name character varying NOT NULL,
    serialized_value jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    locked boolean DEFAULT true NOT NULL
);


--
-- Name: installation_configs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.installation_configs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: installation_configs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.installation_configs_id_seq OWNED BY public.installation_configs.id;


--
-- Name: integration_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integration_settings (
    id bigint NOT NULL,
    account_id bigint,
    provider character varying NOT NULL,
    config text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    enabled boolean DEFAULT true NOT NULL
);


--
-- Name: integration_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.integration_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: integration_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.integration_settings_id_seq OWNED BY public.integration_settings.id;


--
-- Name: integrations_hooks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integrations_hooks (
    id bigint NOT NULL,
    status integer DEFAULT 1,
    inbox_id integer,
    account_id integer,
    app_id character varying,
    hook_type integer DEFAULT 0,
    reference_id character varying,
    access_token character varying,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb
);


--
-- Name: integrations_hooks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.integrations_hooks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: integrations_hooks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.integrations_hooks_id_seq OWNED BY public.integrations_hooks.id;


--
-- Name: labels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.labels (
    id bigint NOT NULL,
    title character varying,
    description text,
    color character varying DEFAULT '#1f93ff'::character varying NOT NULL,
    show_on_sidebar boolean,
    account_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: labels_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.labels_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: labels_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.labels_id_seq OWNED BY public.labels.id;


--
-- Name: leaves; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.leaves (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    user_id bigint NOT NULL,
    start_date date NOT NULL,
    end_date date NOT NULL,
    leave_type integer DEFAULT 0 NOT NULL,
    status integer DEFAULT 0 NOT NULL,
    reason text,
    approved_by_id bigint,
    approved_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: leaves_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.leaves_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: leaves_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.leaves_id_seq OWNED BY public.leaves.id;


--
-- Name: macros; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.macros (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    name character varying NOT NULL,
    visibility integer DEFAULT 0,
    created_by_id bigint,
    updated_by_id bigint,
    actions jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: macros_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.macros_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: macros_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.macros_id_seq OWNED BY public.macros.id;


--
-- Name: mentions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mentions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    account_id bigint NOT NULL,
    mentioned_at timestamp without time zone NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: mentions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.mentions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: mentions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.mentions_id_seq OWNED BY public.mentions.id;


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messages (
    id integer NOT NULL,
    content text,
    account_id integer NOT NULL,
    inbox_id integer NOT NULL,
    conversation_id integer NOT NULL,
    message_type integer NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    private boolean DEFAULT false NOT NULL,
    status integer DEFAULT 0,
    source_id text,
    content_type integer DEFAULT 0 NOT NULL,
    content_attributes json DEFAULT '{}'::json,
    sender_type character varying,
    sender_id bigint,
    external_source_ids jsonb DEFAULT '{}'::jsonb,
    additional_attributes jsonb DEFAULT '{}'::jsonb,
    processed_message_content text,
    sentiment jsonb DEFAULT '{}'::jsonb
);


--
-- Name: messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.messages_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.messages_id_seq OWNED BY public.messages.id;


--
-- Name: meta_conversion_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meta_conversion_events (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    event_name character varying NOT NULL,
    event_id character varying,
    status character varying NOT NULL,
    payload jsonb,
    response text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: meta_conversion_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.meta_conversion_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: meta_conversion_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.meta_conversion_events_id_seq OWNED BY public.meta_conversion_events.id;


--
-- Name: notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notes (
    id bigint NOT NULL,
    content text NOT NULL,
    account_id bigint NOT NULL,
    contact_id bigint NOT NULL,
    user_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: notes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notes_id_seq OWNED BY public.notes.id;


--
-- Name: notification_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_settings (
    id bigint NOT NULL,
    account_id integer,
    user_id integer,
    email_flags integer DEFAULT 0 NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    push_flags integer DEFAULT 0 NOT NULL
);


--
-- Name: notification_settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notification_settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notification_settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notification_settings_id_seq OWNED BY public.notification_settings.id;


--
-- Name: notification_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_subscriptions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    subscription_type integer NOT NULL,
    subscription_attributes jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    identifier text
);


--
-- Name: notification_subscriptions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notification_subscriptions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notification_subscriptions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notification_subscriptions_id_seq OWNED BY public.notification_subscriptions.id;


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    user_id bigint NOT NULL,
    notification_type integer NOT NULL,
    primary_actor_type character varying NOT NULL,
    primary_actor_id bigint NOT NULL,
    secondary_actor_type character varying,
    secondary_actor_id bigint,
    read_at timestamp without time zone,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    snoozed_until timestamp(6) without time zone,
    last_activity_at timestamp(6) without time zone DEFAULT CURRENT_TIMESTAMP,
    meta jsonb DEFAULT '{}'::jsonb
);


--
-- Name: notifications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.notifications_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: notifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.notifications_id_seq OWNED BY public.notifications.id;


--
-- Name: operational_flow_reasons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operational_flow_reasons (
    id bigint NOT NULL,
    operational_flow_id bigint NOT NULL,
    result integer NOT NULL,
    label character varying NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    resolution_state_id bigint
);


--
-- Name: operational_flow_reasons_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.operational_flow_reasons_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: operational_flow_reasons_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.operational_flow_reasons_id_seq OWNED BY public.operational_flow_reasons.id;


--
-- Name: operational_flows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operational_flows (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    name character varying NOT NULL,
    require_reason boolean DEFAULT false NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    category character varying DEFAULT 'sales'::character varying NOT NULL,
    meta_enabled boolean DEFAULT false NOT NULL
);


--
-- Name: operational_flows_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.operational_flows_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: operational_flows_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.operational_flows_id_seq OWNED BY public.operational_flows.id;


--
-- Name: platform_app_permissibles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_app_permissibles (
    id bigint NOT NULL,
    platform_app_id bigint NOT NULL,
    permissible_type character varying NOT NULL,
    permissible_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: platform_app_permissibles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.platform_app_permissibles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: platform_app_permissibles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.platform_app_permissibles_id_seq OWNED BY public.platform_app_permissibles.id;


--
-- Name: platform_apps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_apps (
    id bigint NOT NULL,
    name character varying NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: platform_apps_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.platform_apps_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: platform_apps_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.platform_apps_id_seq OWNED BY public.platform_apps.id;


--
-- Name: portals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.portals (
    id bigint NOT NULL,
    account_id integer NOT NULL,
    name character varying NOT NULL,
    slug character varying NOT NULL,
    custom_domain character varying,
    color character varying,
    homepage_link character varying,
    page_title character varying,
    header_text text,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    config jsonb DEFAULT '{"allowed_locales": ["en"]}'::jsonb,
    archived boolean DEFAULT false,
    channel_web_widget_id bigint,
    ssl_settings jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: portals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.portals_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: portals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.portals_id_seq OWNED BY public.portals.id;


--
-- Name: portals_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.portals_members (
    portal_id bigint NOT NULL,
    user_id bigint NOT NULL
);


--
-- Name: provider_instances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_instances (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    provider character varying NOT NULL,
    instance_id character varying,
    instance_name character varying NOT NULL,
    phone_number character varying,
    status character varying DEFAULT 'unknown'::character varying,
    raw_data jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: provider_instances_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.provider_instances_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: provider_instances_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.provider_instances_id_seq OWNED BY public.provider_instances.id;


--
-- Name: related_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.related_categories (
    id bigint NOT NULL,
    category_id bigint,
    related_category_id bigint,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: related_categories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.related_categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: related_categories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.related_categories_id_seq OWNED BY public.related_categories.id;


--
-- Name: reporting_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reporting_events (
    id bigint NOT NULL,
    name character varying,
    value double precision,
    account_id integer,
    inbox_id integer,
    user_id integer,
    conversation_id integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    value_in_business_hours double precision,
    event_start_time timestamp without time zone,
    event_end_time timestamp without time zone,
    team_id integer
);


--
-- Name: reporting_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.reporting_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reporting_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.reporting_events_id_seq OWNED BY public.reporting_events.id;


--
-- Name: reporting_events_rollups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reporting_events_rollups (
    id bigint NOT NULL,
    account_id integer NOT NULL,
    date date NOT NULL,
    dimension_type character varying NOT NULL,
    dimension_id bigint NOT NULL,
    metric character varying NOT NULL,
    count bigint DEFAULT 0 NOT NULL,
    sum_value double precision DEFAULT 0.0 NOT NULL,
    sum_value_business_hours double precision DEFAULT 0.0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: reporting_events_rollups_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.reporting_events_rollups_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reporting_events_rollups_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.reporting_events_rollups_id_seq OWNED BY public.reporting_events_rollups.id;


--
-- Name: resolution_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.resolution_states (
    id bigint NOT NULL,
    operational_flow_id bigint NOT NULL,
    canonical_key character varying NOT NULL,
    display_label character varying NOT NULL,
    polarity character varying DEFAULT 'neutral'::character varying NOT NULL,
    requires_reason boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    meta_event_type character varying,
    meta_value_attr character varying
);


--
-- Name: resolution_states_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.resolution_states_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: resolution_states_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.resolution_states_id_seq OWNED BY public.resolution_states.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: sla_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sla_events (
    id bigint NOT NULL,
    applied_sla_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    account_id bigint NOT NULL,
    sla_policy_id bigint NOT NULL,
    inbox_id bigint NOT NULL,
    event_type integer,
    meta jsonb DEFAULT '{}'::jsonb,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: sla_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sla_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sla_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sla_events_id_seq OWNED BY public.sla_events.id;


--
-- Name: sla_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sla_policies (
    id bigint NOT NULL,
    name character varying NOT NULL,
    first_response_time_threshold double precision,
    next_response_time_threshold double precision,
    only_during_business_hours boolean DEFAULT false,
    account_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    description character varying,
    resolution_time_threshold double precision
);


--
-- Name: sla_policies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sla_policies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sla_policies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sla_policies_id_seq OWNED BY public.sla_policies.id;


--
-- Name: stickers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stickers (
    id bigint NOT NULL,
    account_id bigint NOT NULL,
    name character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: stickers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.stickers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: stickers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.stickers_id_seq OWNED BY public.stickers.id;


--
-- Name: taggings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.taggings (
    id integer NOT NULL,
    tag_id integer,
    taggable_type character varying,
    taggable_id integer,
    tagger_type character varying,
    tagger_id integer,
    context character varying(128),
    created_at timestamp without time zone
);


--
-- Name: taggings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.taggings_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: taggings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.taggings_id_seq OWNED BY public.taggings.id;


--
-- Name: tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tags (
    id integer NOT NULL,
    name character varying,
    taggings_count integer DEFAULT 0
);


--
-- Name: tags_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tags_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tags_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tags_id_seq OWNED BY public.tags.id;


--
-- Name: team_inboxes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.team_inboxes (
    id bigint NOT NULL,
    team_id bigint NOT NULL,
    inbox_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: team_inboxes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.team_inboxes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: team_inboxes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.team_inboxes_id_seq OWNED BY public.team_inboxes.id;


--
-- Name: team_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.team_members (
    id bigint NOT NULL,
    team_id bigint NOT NULL,
    user_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    role integer DEFAULT 0 NOT NULL
);


--
-- Name: team_members_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.team_members_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: team_members_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.team_members_id_seq OWNED BY public.team_members.id;


--
-- Name: teams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.teams (
    id bigint NOT NULL,
    name character varying NOT NULL,
    description text,
    allow_auto_assign boolean DEFAULT true,
    account_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    operational_flow_id bigint
);


--
-- Name: teams_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.teams_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: teams_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.teams_id_seq OWNED BY public.teams.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id integer NOT NULL,
    provider character varying DEFAULT 'email'::character varying NOT NULL,
    uid character varying DEFAULT ''::character varying NOT NULL,
    encrypted_password character varying DEFAULT ''::character varying NOT NULL,
    reset_password_token character varying,
    reset_password_sent_at timestamp without time zone,
    remember_created_at timestamp without time zone,
    sign_in_count integer DEFAULT 0 NOT NULL,
    current_sign_in_at timestamp without time zone,
    last_sign_in_at timestamp without time zone,
    current_sign_in_ip character varying,
    last_sign_in_ip character varying,
    confirmation_token character varying,
    confirmed_at timestamp without time zone,
    confirmation_sent_at timestamp without time zone,
    unconfirmed_email character varying,
    name character varying NOT NULL,
    display_name character varying,
    email character varying,
    tokens json,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    pubsub_token character varying,
    availability integer DEFAULT 0,
    ui_settings jsonb DEFAULT '{}'::jsonb,
    custom_attributes jsonb DEFAULT '{}'::jsonb,
    type character varying,
    message_signature text,
    otp_secret character varying,
    consumed_timestep integer,
    otp_required_for_login boolean DEFAULT false NOT NULL,
    otp_backup_codes text
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: webhooks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhooks (
    id bigint NOT NULL,
    account_id integer,
    inbox_id integer,
    url text,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    webhook_type integer DEFAULT 0,
    subscriptions jsonb DEFAULT '["conversation_status_changed", "conversation_updated", "conversation_created", "contact_created", "contact_updated", "message_created", "message_updated", "webwidget_triggered"]'::jsonb,
    name character varying,
    secret character varying
);


--
-- Name: webhooks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.webhooks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: webhooks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.webhooks_id_seq OWNED BY public.webhooks.id;


--
-- Name: working_hours; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.working_hours (
    id bigint NOT NULL,
    inbox_id bigint,
    account_id bigint,
    day_of_week integer NOT NULL,
    closed_all_day boolean DEFAULT false,
    open_hour integer,
    open_minutes integer,
    close_hour integer,
    close_minutes integer,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    open_all_day boolean DEFAULT false,
    has_lunch_break boolean DEFAULT false NOT NULL,
    lunch_start_hour integer,
    lunch_start_minutes integer,
    lunch_end_hour integer,
    lunch_end_minutes integer
);


--
-- Name: working_hours_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.working_hours_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: working_hours_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.working_hours_id_seq OWNED BY public.working_hours.id;


--
-- Name: working_periods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.working_periods (
    id bigint NOT NULL,
    inbox_id bigint NOT NULL,
    account_id bigint,
    day_of_week integer NOT NULL,
    start_hour integer NOT NULL,
    start_minutes integer DEFAULT 0 NOT NULL,
    end_hour integer NOT NULL,
    end_minutes integer DEFAULT 0 NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: working_periods_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.working_periods_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: working_periods_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.working_periods_id_seq OWNED BY public.working_periods.id;


--
-- Name: access_tokens id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.access_tokens ALTER COLUMN id SET DEFAULT nextval('public.access_tokens_id_seq'::regclass);


--
-- Name: account_saml_settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_saml_settings ALTER COLUMN id SET DEFAULT nextval('public.account_saml_settings_id_seq'::regclass);


--
-- Name: account_users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_users ALTER COLUMN id SET DEFAULT nextval('public.account_users_id_seq'::regclass);


--
-- Name: accounts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts ALTER COLUMN id SET DEFAULT nextval('public.accounts_id_seq'::regclass);


--
-- Name: action_mailbox_inbound_emails id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.action_mailbox_inbound_emails ALTER COLUMN id SET DEFAULT nextval('public.action_mailbox_inbound_emails_id_seq'::regclass);


--
-- Name: active_storage_attachments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments ALTER COLUMN id SET DEFAULT nextval('public.active_storage_attachments_id_seq'::regclass);


--
-- Name: active_storage_blobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs ALTER COLUMN id SET DEFAULT nextval('public.active_storage_blobs_id_seq'::regclass);


--
-- Name: active_storage_variant_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records ALTER COLUMN id SET DEFAULT nextval('public.active_storage_variant_records_id_seq'::regclass);


--
-- Name: agent_bot_inboxes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_bot_inboxes ALTER COLUMN id SET DEFAULT nextval('public.agent_bot_inboxes_id_seq'::regclass);


--
-- Name: agent_bots id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_bots ALTER COLUMN id SET DEFAULT nextval('public.agent_bots_id_seq'::regclass);


--
-- Name: agent_capacity_policies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_capacity_policies ALTER COLUMN id SET DEFAULT nextval('public.agent_capacity_policies_id_seq'::regclass);


--
-- Name: agent_schedules id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_schedules ALTER COLUMN id SET DEFAULT nextval('public.agent_schedules_id_seq'::regclass);


--
-- Name: ai_agent_inboxes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agent_inboxes ALTER COLUMN id SET DEFAULT nextval('public.ai_agent_inboxes_id_seq'::regclass);


--
-- Name: ai_agent_memory id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agent_memory ALTER COLUMN id SET DEFAULT nextval('public.ai_agent_memory_id_seq'::regclass);


--
-- Name: ai_agent_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agent_versions ALTER COLUMN id SET DEFAULT nextval('public.ai_agent_versions_id_seq'::regclass);


--
-- Name: ai_agents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agents ALTER COLUMN id SET DEFAULT nextval('public.ai_agents_id_seq'::regclass);


--
-- Name: ai_capability_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_capability_executions ALTER COLUMN id SET DEFAULT nextval('public.ai_capability_executions_id_seq'::regclass);


--
-- Name: ai_department_inboxes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_department_inboxes ALTER COLUMN id SET DEFAULT nextval('public.ai_department_inboxes_id_seq'::regclass);


--
-- Name: ai_department_integrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_department_integrations ALTER COLUMN id SET DEFAULT nextval('public.ai_department_integrations_id_seq'::regclass);


--
-- Name: ai_departments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_departments ALTER COLUMN id SET DEFAULT nextval('public.ai_departments_id_seq'::regclass);


--
-- Name: ai_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_events ALTER COLUMN id SET DEFAULT nextval('public.ai_events_id_seq'::regclass);


--
-- Name: ai_integration_links id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_integration_links ALTER COLUMN id SET DEFAULT nextval('public.ai_integration_links_id_seq'::regclass);


--
-- Name: ai_knowledge_chunks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_knowledge_chunks ALTER COLUMN id SET DEFAULT nextval('public.ai_knowledge_chunks_id_seq'::regclass);


--
-- Name: ai_knowledge_sources id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_knowledge_sources ALTER COLUMN id SET DEFAULT nextval('public.ai_knowledge_sources_id_seq'::regclass);


--
-- Name: ai_lead_variables id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_lead_variables ALTER COLUMN id SET DEFAULT nextval('public.ai_lead_variables_id_seq'::regclass);


--
-- Name: ai_operation_profiles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_operation_profiles ALTER COLUMN id SET DEFAULT nextval('public.ai_operation_profiles_id_seq'::regclass);


--
-- Name: ai_playbook_versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_playbook_versions ALTER COLUMN id SET DEFAULT nextval('public.ai_playbook_versions_id_seq'::regclass);


--
-- Name: ai_playbooks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_playbooks ALTER COLUMN id SET DEFAULT nextval('public.ai_playbooks_id_seq'::regclass);


--
-- Name: ai_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_runs ALTER COLUMN id SET DEFAULT nextval('public.ai_runs_id_seq'::regclass);


--
-- Name: ai_shadow_inboxes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_shadow_inboxes ALTER COLUMN id SET DEFAULT nextval('public.ai_shadow_inboxes_id_seq'::regclass);


--
-- Name: ai_shadows id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_shadows ALTER COLUMN id SET DEFAULT nextval('public.ai_shadows_id_seq'::regclass);


--
-- Name: ai_tools id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_tools ALTER COLUMN id SET DEFAULT nextval('public.ai_tools_id_seq'::regclass);


--
-- Name: applied_slas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applied_slas ALTER COLUMN id SET DEFAULT nextval('public.applied_slas_id_seq'::regclass);


--
-- Name: article_embeddings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.article_embeddings ALTER COLUMN id SET DEFAULT nextval('public.article_embeddings_id_seq'::regclass);


--
-- Name: articles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.articles ALTER COLUMN id SET DEFAULT nextval('public.articles_id_seq'::regclass);


--
-- Name: assignment_policies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assignment_policies ALTER COLUMN id SET DEFAULT nextval('public.assignment_policies_id_seq'::regclass);


--
-- Name: attachments id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments ALTER COLUMN id SET DEFAULT nextval('public.attachments_id_seq'::regclass);


--
-- Name: audits id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audits ALTER COLUMN id SET DEFAULT nextval('public.audits_id_seq'::regclass);


--
-- Name: automation_rules id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rules ALTER COLUMN id SET DEFAULT nextval('public.automation_rules_id_seq'::regclass);


--
-- Name: calls id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calls ALTER COLUMN id SET DEFAULT nextval('public.calls_id_seq'::regclass);


--
-- Name: campaigns id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaigns ALTER COLUMN id SET DEFAULT nextval('public.campaigns_id_seq'::regclass);


--
-- Name: canned_responses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.canned_responses ALTER COLUMN id SET DEFAULT nextval('public.canned_responses_id_seq'::regclass);


--
-- Name: captain_assistant_responses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captain_assistant_responses ALTER COLUMN id SET DEFAULT nextval('public.captain_assistant_responses_id_seq'::regclass);


--
-- Name: captain_assistants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captain_assistants ALTER COLUMN id SET DEFAULT nextval('public.captain_assistants_id_seq'::regclass);


--
-- Name: captain_custom_tools id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captain_custom_tools ALTER COLUMN id SET DEFAULT nextval('public.captain_custom_tools_id_seq'::regclass);


--
-- Name: captain_documents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captain_documents ALTER COLUMN id SET DEFAULT nextval('public.captain_documents_id_seq'::regclass);


--
-- Name: captain_inboxes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captain_inboxes ALTER COLUMN id SET DEFAULT nextval('public.captain_inboxes_id_seq'::regclass);


--
-- Name: captain_scenarios id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captain_scenarios ALTER COLUMN id SET DEFAULT nextval('public.captain_scenarios_id_seq'::regclass);


--
-- Name: categories id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories ALTER COLUMN id SET DEFAULT nextval('public.categories_id_seq'::regclass);


--
-- Name: channel_api id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_api ALTER COLUMN id SET DEFAULT nextval('public.channel_api_id_seq'::regclass);


--
-- Name: channel_email id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_email ALTER COLUMN id SET DEFAULT nextval('public.channel_email_id_seq'::regclass);


--
-- Name: channel_facebook_pages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_facebook_pages ALTER COLUMN id SET DEFAULT nextval('public.channel_facebook_pages_id_seq'::regclass);


--
-- Name: channel_instagram id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_instagram ALTER COLUMN id SET DEFAULT nextval('public.channel_instagram_id_seq'::regclass);


--
-- Name: channel_line id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_line ALTER COLUMN id SET DEFAULT nextval('public.channel_line_id_seq'::regclass);


--
-- Name: channel_sms id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_sms ALTER COLUMN id SET DEFAULT nextval('public.channel_sms_id_seq'::regclass);


--
-- Name: channel_telegram id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_telegram ALTER COLUMN id SET DEFAULT nextval('public.channel_telegram_id_seq'::regclass);


--
-- Name: channel_tiktok id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_tiktok ALTER COLUMN id SET DEFAULT nextval('public.channel_tiktok_id_seq'::regclass);


--
-- Name: channel_twilio_sms id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_twilio_sms ALTER COLUMN id SET DEFAULT nextval('public.channel_twilio_sms_id_seq'::regclass);


--
-- Name: channel_twitter_profiles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_twitter_profiles ALTER COLUMN id SET DEFAULT nextval('public.channel_twitter_profiles_id_seq'::regclass);


--
-- Name: channel_voice id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_voice ALTER COLUMN id SET DEFAULT nextval('public.channel_voice_id_seq'::regclass);


--
-- Name: channel_web_widgets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_web_widgets ALTER COLUMN id SET DEFAULT nextval('public.channel_web_widgets_id_seq'::regclass);


--
-- Name: channel_whatsapp id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_whatsapp ALTER COLUMN id SET DEFAULT nextval('public.channel_whatsapp_id_seq'::regclass);


--
-- Name: closing_requirements id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.closing_requirements ALTER COLUMN id SET DEFAULT nextval('public.closing_requirements_id_seq'::regclass);


--
-- Name: companies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.companies ALTER COLUMN id SET DEFAULT nextval('public.companies_id_seq'::regclass);


--
-- Name: contact_inboxes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_inboxes ALTER COLUMN id SET DEFAULT nextval('public.contact_inboxes_id_seq'::regclass);


--
-- Name: contacts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contacts ALTER COLUMN id SET DEFAULT nextval('public.contacts_id_seq'::regclass);


--
-- Name: conversation_participants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_participants ALTER COLUMN id SET DEFAULT nextval('public.conversation_participants_id_seq'::regclass);


--
-- Name: conversation_result_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_result_events ALTER COLUMN id SET DEFAULT nextval('public.conversation_result_events_id_seq'::regclass);


--
-- Name: conversations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations ALTER COLUMN id SET DEFAULT nextval('public.conversations_id_seq'::regclass);


--
-- Name: copilot_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copilot_messages ALTER COLUMN id SET DEFAULT nextval('public.copilot_messages_id_seq'::regclass);


--
-- Name: copilot_threads id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copilot_threads ALTER COLUMN id SET DEFAULT nextval('public.copilot_threads_id_seq'::regclass);


--
-- Name: csat_survey_responses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.csat_survey_responses ALTER COLUMN id SET DEFAULT nextval('public.csat_survey_responses_id_seq'::regclass);


--
-- Name: custom_attribute_definitions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.custom_attribute_definitions ALTER COLUMN id SET DEFAULT nextval('public.custom_attribute_definitions_id_seq'::regclass);


--
-- Name: custom_filters id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.custom_filters ALTER COLUMN id SET DEFAULT nextval('public.custom_filters_id_seq'::regclass);


--
-- Name: custom_roles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.custom_roles ALTER COLUMN id SET DEFAULT nextval('public.custom_roles_id_seq'::regclass);


--
-- Name: dashboard_apps id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dashboard_apps ALTER COLUMN id SET DEFAULT nextval('public.dashboard_apps_id_seq'::regclass);


--
-- Name: data_imports id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.data_imports ALTER COLUMN id SET DEFAULT nextval('public.data_imports_id_seq'::regclass);


--
-- Name: email_templates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_templates ALTER COLUMN id SET DEFAULT nextval('public.email_templates_id_seq'::regclass);


--
-- Name: folders id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.folders ALTER COLUMN id SET DEFAULT nextval('public.folders_id_seq'::regclass);


--
-- Name: inbox_assignment_policies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_assignment_policies ALTER COLUMN id SET DEFAULT nextval('public.inbox_assignment_policies_id_seq'::regclass);


--
-- Name: inbox_capacity_limits id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_capacity_limits ALTER COLUMN id SET DEFAULT nextval('public.inbox_capacity_limits_id_seq'::regclass);


--
-- Name: inbox_exceptions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_exceptions ALTER COLUMN id SET DEFAULT nextval('public.inbox_exceptions_id_seq'::regclass);


--
-- Name: inbox_holidays id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_holidays ALTER COLUMN id SET DEFAULT nextval('public.inbox_holidays_id_seq'::regclass);


--
-- Name: inbox_members id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_members ALTER COLUMN id SET DEFAULT nextval('public.inbox_members_id_seq'::regclass);


--
-- Name: inboxes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inboxes ALTER COLUMN id SET DEFAULT nextval('public.inboxes_id_seq'::regclass);


--
-- Name: installation_configs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.installation_configs ALTER COLUMN id SET DEFAULT nextval('public.installation_configs_id_seq'::regclass);


--
-- Name: integration_settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_settings ALTER COLUMN id SET DEFAULT nextval('public.integration_settings_id_seq'::regclass);


--
-- Name: integrations_hooks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integrations_hooks ALTER COLUMN id SET DEFAULT nextval('public.integrations_hooks_id_seq'::regclass);


--
-- Name: labels id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.labels ALTER COLUMN id SET DEFAULT nextval('public.labels_id_seq'::regclass);


--
-- Name: leaves id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leaves ALTER COLUMN id SET DEFAULT nextval('public.leaves_id_seq'::regclass);


--
-- Name: macros id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.macros ALTER COLUMN id SET DEFAULT nextval('public.macros_id_seq'::regclass);


--
-- Name: mentions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mentions ALTER COLUMN id SET DEFAULT nextval('public.mentions_id_seq'::regclass);


--
-- Name: messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages ALTER COLUMN id SET DEFAULT nextval('public.messages_id_seq'::regclass);


--
-- Name: meta_conversion_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meta_conversion_events ALTER COLUMN id SET DEFAULT nextval('public.meta_conversion_events_id_seq'::regclass);


--
-- Name: notes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes ALTER COLUMN id SET DEFAULT nextval('public.notes_id_seq'::regclass);


--
-- Name: notification_settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_settings ALTER COLUMN id SET DEFAULT nextval('public.notification_settings_id_seq'::regclass);


--
-- Name: notification_subscriptions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_subscriptions ALTER COLUMN id SET DEFAULT nextval('public.notification_subscriptions_id_seq'::regclass);


--
-- Name: notifications id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications ALTER COLUMN id SET DEFAULT nextval('public.notifications_id_seq'::regclass);


--
-- Name: operational_flow_reasons id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_flow_reasons ALTER COLUMN id SET DEFAULT nextval('public.operational_flow_reasons_id_seq'::regclass);


--
-- Name: operational_flows id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_flows ALTER COLUMN id SET DEFAULT nextval('public.operational_flows_id_seq'::regclass);


--
-- Name: platform_app_permissibles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_app_permissibles ALTER COLUMN id SET DEFAULT nextval('public.platform_app_permissibles_id_seq'::regclass);


--
-- Name: platform_apps id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_apps ALTER COLUMN id SET DEFAULT nextval('public.platform_apps_id_seq'::regclass);


--
-- Name: portals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.portals ALTER COLUMN id SET DEFAULT nextval('public.portals_id_seq'::regclass);


--
-- Name: provider_instances id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_instances ALTER COLUMN id SET DEFAULT nextval('public.provider_instances_id_seq'::regclass);


--
-- Name: related_categories id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.related_categories ALTER COLUMN id SET DEFAULT nextval('public.related_categories_id_seq'::regclass);


--
-- Name: reporting_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reporting_events ALTER COLUMN id SET DEFAULT nextval('public.reporting_events_id_seq'::regclass);


--
-- Name: reporting_events_rollups id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reporting_events_rollups ALTER COLUMN id SET DEFAULT nextval('public.reporting_events_rollups_id_seq'::regclass);


--
-- Name: resolution_states id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resolution_states ALTER COLUMN id SET DEFAULT nextval('public.resolution_states_id_seq'::regclass);


--
-- Name: sla_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_events ALTER COLUMN id SET DEFAULT nextval('public.sla_events_id_seq'::regclass);


--
-- Name: sla_policies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_policies ALTER COLUMN id SET DEFAULT nextval('public.sla_policies_id_seq'::regclass);


--
-- Name: stickers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stickers ALTER COLUMN id SET DEFAULT nextval('public.stickers_id_seq'::regclass);


--
-- Name: taggings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.taggings ALTER COLUMN id SET DEFAULT nextval('public.taggings_id_seq'::regclass);


--
-- Name: tags id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tags ALTER COLUMN id SET DEFAULT nextval('public.tags_id_seq'::regclass);


--
-- Name: team_inboxes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_inboxes ALTER COLUMN id SET DEFAULT nextval('public.team_inboxes_id_seq'::regclass);


--
-- Name: team_members id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_members ALTER COLUMN id SET DEFAULT nextval('public.team_members_id_seq'::regclass);


--
-- Name: teams id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams ALTER COLUMN id SET DEFAULT nextval('public.teams_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: webhooks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhooks ALTER COLUMN id SET DEFAULT nextval('public.webhooks_id_seq'::regclass);


--
-- Name: working_hours id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.working_hours ALTER COLUMN id SET DEFAULT nextval('public.working_hours_id_seq'::regclass);


--
-- Name: working_periods id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.working_periods ALTER COLUMN id SET DEFAULT nextval('public.working_periods_id_seq'::regclass);


--
-- Name: access_tokens access_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.access_tokens
    ADD CONSTRAINT access_tokens_pkey PRIMARY KEY (id);


--
-- Name: account_saml_settings account_saml_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_saml_settings
    ADD CONSTRAINT account_saml_settings_pkey PRIMARY KEY (id);


--
-- Name: account_users account_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_users
    ADD CONSTRAINT account_users_pkey PRIMARY KEY (id);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);


--
-- Name: action_mailbox_inbound_emails action_mailbox_inbound_emails_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.action_mailbox_inbound_emails
    ADD CONSTRAINT action_mailbox_inbound_emails_pkey PRIMARY KEY (id);


--
-- Name: active_storage_attachments active_storage_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT active_storage_attachments_pkey PRIMARY KEY (id);


--
-- Name: active_storage_blobs active_storage_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_blobs
    ADD CONSTRAINT active_storage_blobs_pkey PRIMARY KEY (id);


--
-- Name: active_storage_variant_records active_storage_variant_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT active_storage_variant_records_pkey PRIMARY KEY (id);


--
-- Name: agent_bot_inboxes agent_bot_inboxes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_bot_inboxes
    ADD CONSTRAINT agent_bot_inboxes_pkey PRIMARY KEY (id);


--
-- Name: agent_bots agent_bots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_bots
    ADD CONSTRAINT agent_bots_pkey PRIMARY KEY (id);


--
-- Name: agent_capacity_policies agent_capacity_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_capacity_policies
    ADD CONSTRAINT agent_capacity_policies_pkey PRIMARY KEY (id);


--
-- Name: agent_schedules agent_schedules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_schedules
    ADD CONSTRAINT agent_schedules_pkey PRIMARY KEY (id);


--
-- Name: ai_agent_inboxes ai_agent_inboxes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agent_inboxes
    ADD CONSTRAINT ai_agent_inboxes_pkey PRIMARY KEY (id);


--
-- Name: ai_agent_memory ai_agent_memory_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agent_memory
    ADD CONSTRAINT ai_agent_memory_pkey PRIMARY KEY (id);


--
-- Name: ai_agent_versions ai_agent_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agent_versions
    ADD CONSTRAINT ai_agent_versions_pkey PRIMARY KEY (id);


--
-- Name: ai_agents ai_agents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_agents
    ADD CONSTRAINT ai_agents_pkey PRIMARY KEY (id);


--
-- Name: ai_capability_executions ai_capability_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_capability_executions
    ADD CONSTRAINT ai_capability_executions_pkey PRIMARY KEY (id);


--
-- Name: ai_department_inboxes ai_department_inboxes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_department_inboxes
    ADD CONSTRAINT ai_department_inboxes_pkey PRIMARY KEY (id);


--
-- Name: ai_department_integrations ai_department_integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_department_integrations
    ADD CONSTRAINT ai_department_integrations_pkey PRIMARY KEY (id);


--
-- Name: ai_departments ai_departments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_departments
    ADD CONSTRAINT ai_departments_pkey PRIMARY KEY (id);


--
-- Name: ai_events ai_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_events
    ADD CONSTRAINT ai_events_pkey PRIMARY KEY (id);


--
-- Name: ai_integration_links ai_integration_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_integration_links
    ADD CONSTRAINT ai_integration_links_pkey PRIMARY KEY (id);


--
-- Name: ai_knowledge_chunks ai_knowledge_chunks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_knowledge_chunks
    ADD CONSTRAINT ai_knowledge_chunks_pkey PRIMARY KEY (id);


--
-- Name: ai_knowledge_sources ai_knowledge_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_knowledge_sources
    ADD CONSTRAINT ai_knowledge_sources_pkey PRIMARY KEY (id);


--
-- Name: ai_lead_variables ai_lead_variables_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_lead_variables
    ADD CONSTRAINT ai_lead_variables_pkey PRIMARY KEY (id);


--
-- Name: ai_operation_profiles ai_operation_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_operation_profiles
    ADD CONSTRAINT ai_operation_profiles_pkey PRIMARY KEY (id);


--
-- Name: ai_playbook_versions ai_playbook_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_playbook_versions
    ADD CONSTRAINT ai_playbook_versions_pkey PRIMARY KEY (id);


--
-- Name: ai_playbooks ai_playbooks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_playbooks
    ADD CONSTRAINT ai_playbooks_pkey PRIMARY KEY (id);


--
-- Name: ai_runs ai_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_runs
    ADD CONSTRAINT ai_runs_pkey PRIMARY KEY (id);


--
-- Name: ai_shadow_inboxes ai_shadow_inboxes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_shadow_inboxes
    ADD CONSTRAINT ai_shadow_inboxes_pkey PRIMARY KEY (id);


--
-- Name: ai_shadows ai_shadows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_shadows
    ADD CONSTRAINT ai_shadows_pkey PRIMARY KEY (id);


--
-- Name: ai_tools ai_tools_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_tools
    ADD CONSTRAINT ai_tools_pkey PRIMARY KEY (id);


--
-- Name: applied_slas applied_slas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applied_slas
    ADD CONSTRAINT applied_slas_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: article_embeddings article_embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.article_embeddings
    ADD CONSTRAINT article_embeddings_pkey PRIMARY KEY (id);


--
-- Name: articles articles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.articles
    ADD CONSTRAINT articles_pkey PRIMARY KEY (id);


--
-- Name: assignment_policies assignment_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assignment_policies
    ADD CONSTRAINT assignment_policies_pkey PRIMARY KEY (id);


--
-- Name: attachments attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_pkey PRIMARY KEY (id);


--
-- Name: audits audits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audits
    ADD CONSTRAINT audits_pkey PRIMARY KEY (id);


--
-- Name: automation_rules automation_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automation_rules
    ADD CONSTRAINT automation_rules_pkey PRIMARY KEY (id);


--
-- Name: calls calls_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.calls
    ADD CONSTRAINT calls_pkey PRIMARY KEY (id);


--
-- Name: campaigns campaigns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaigns
    ADD CONSTRAINT campaigns_pkey PRIMARY KEY (id);


--
-- Name: canned_responses canned_responses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.canned_responses
    ADD CONSTRAINT canned_responses_pkey PRIMARY KEY (id);


--
-- Name: captain_assistant_responses captain_assistant_responses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captain_assistant_responses
    ADD CONSTRAINT captain_assistant_responses_pkey PRIMARY KEY (id);


--
-- Name: captain_assistants captain_assistants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captain_assistants
    ADD CONSTRAINT captain_assistants_pkey PRIMARY KEY (id);


--
-- Name: captain_custom_tools captain_custom_tools_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captain_custom_tools
    ADD CONSTRAINT captain_custom_tools_pkey PRIMARY KEY (id);


--
-- Name: captain_documents captain_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captain_documents
    ADD CONSTRAINT captain_documents_pkey PRIMARY KEY (id);


--
-- Name: captain_inboxes captain_inboxes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captain_inboxes
    ADD CONSTRAINT captain_inboxes_pkey PRIMARY KEY (id);


--
-- Name: captain_scenarios captain_scenarios_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.captain_scenarios
    ADD CONSTRAINT captain_scenarios_pkey PRIMARY KEY (id);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id);


--
-- Name: channel_api channel_api_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_api
    ADD CONSTRAINT channel_api_pkey PRIMARY KEY (id);


--
-- Name: channel_email channel_email_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_email
    ADD CONSTRAINT channel_email_pkey PRIMARY KEY (id);


--
-- Name: channel_facebook_pages channel_facebook_pages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_facebook_pages
    ADD CONSTRAINT channel_facebook_pages_pkey PRIMARY KEY (id);


--
-- Name: channel_instagram channel_instagram_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_instagram
    ADD CONSTRAINT channel_instagram_pkey PRIMARY KEY (id);


--
-- Name: channel_line channel_line_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_line
    ADD CONSTRAINT channel_line_pkey PRIMARY KEY (id);


--
-- Name: channel_sms channel_sms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_sms
    ADD CONSTRAINT channel_sms_pkey PRIMARY KEY (id);


--
-- Name: channel_telegram channel_telegram_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_telegram
    ADD CONSTRAINT channel_telegram_pkey PRIMARY KEY (id);


--
-- Name: channel_tiktok channel_tiktok_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_tiktok
    ADD CONSTRAINT channel_tiktok_pkey PRIMARY KEY (id);


--
-- Name: channel_twilio_sms channel_twilio_sms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_twilio_sms
    ADD CONSTRAINT channel_twilio_sms_pkey PRIMARY KEY (id);


--
-- Name: channel_twitter_profiles channel_twitter_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_twitter_profiles
    ADD CONSTRAINT channel_twitter_profiles_pkey PRIMARY KEY (id);


--
-- Name: channel_voice channel_voice_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_voice
    ADD CONSTRAINT channel_voice_pkey PRIMARY KEY (id);


--
-- Name: channel_web_widgets channel_web_widgets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_web_widgets
    ADD CONSTRAINT channel_web_widgets_pkey PRIMARY KEY (id);


--
-- Name: channel_whatsapp channel_whatsapp_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_whatsapp
    ADD CONSTRAINT channel_whatsapp_pkey PRIMARY KEY (id);


--
-- Name: closing_requirements closing_requirements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.closing_requirements
    ADD CONSTRAINT closing_requirements_pkey PRIMARY KEY (id);


--
-- Name: companies companies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT companies_pkey PRIMARY KEY (id);


--
-- Name: contact_inboxes contact_inboxes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_inboxes
    ADD CONSTRAINT contact_inboxes_pkey PRIMARY KEY (id);


--
-- Name: contacts contacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT contacts_pkey PRIMARY KEY (id);


--
-- Name: conversation_participants conversation_participants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_participants
    ADD CONSTRAINT conversation_participants_pkey PRIMARY KEY (id);


--
-- Name: conversation_result_events conversation_result_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_result_events
    ADD CONSTRAINT conversation_result_events_pkey PRIMARY KEY (id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: copilot_messages copilot_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copilot_messages
    ADD CONSTRAINT copilot_messages_pkey PRIMARY KEY (id);


--
-- Name: copilot_threads copilot_threads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.copilot_threads
    ADD CONSTRAINT copilot_threads_pkey PRIMARY KEY (id);


--
-- Name: csat_survey_responses csat_survey_responses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.csat_survey_responses
    ADD CONSTRAINT csat_survey_responses_pkey PRIMARY KEY (id);


--
-- Name: custom_attribute_definitions custom_attribute_definitions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.custom_attribute_definitions
    ADD CONSTRAINT custom_attribute_definitions_pkey PRIMARY KEY (id);


--
-- Name: custom_filters custom_filters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.custom_filters
    ADD CONSTRAINT custom_filters_pkey PRIMARY KEY (id);


--
-- Name: custom_roles custom_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.custom_roles
    ADD CONSTRAINT custom_roles_pkey PRIMARY KEY (id);


--
-- Name: dashboard_apps dashboard_apps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dashboard_apps
    ADD CONSTRAINT dashboard_apps_pkey PRIMARY KEY (id);


--
-- Name: data_imports data_imports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.data_imports
    ADD CONSTRAINT data_imports_pkey PRIMARY KEY (id);


--
-- Name: email_templates email_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_templates
    ADD CONSTRAINT email_templates_pkey PRIMARY KEY (id);


--
-- Name: folders folders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.folders
    ADD CONSTRAINT folders_pkey PRIMARY KEY (id);


--
-- Name: inbox_assignment_policies inbox_assignment_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_assignment_policies
    ADD CONSTRAINT inbox_assignment_policies_pkey PRIMARY KEY (id);


--
-- Name: inbox_capacity_limits inbox_capacity_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_capacity_limits
    ADD CONSTRAINT inbox_capacity_limits_pkey PRIMARY KEY (id);


--
-- Name: inbox_exceptions inbox_exceptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_exceptions
    ADD CONSTRAINT inbox_exceptions_pkey PRIMARY KEY (id);


--
-- Name: inbox_holidays inbox_holidays_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_holidays
    ADD CONSTRAINT inbox_holidays_pkey PRIMARY KEY (id);


--
-- Name: inbox_members inbox_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_members
    ADD CONSTRAINT inbox_members_pkey PRIMARY KEY (id);


--
-- Name: inboxes inboxes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inboxes
    ADD CONSTRAINT inboxes_pkey PRIMARY KEY (id);


--
-- Name: installation_configs installation_configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.installation_configs
    ADD CONSTRAINT installation_configs_pkey PRIMARY KEY (id);


--
-- Name: integration_settings integration_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_settings
    ADD CONSTRAINT integration_settings_pkey PRIMARY KEY (id);


--
-- Name: integrations_hooks integrations_hooks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integrations_hooks
    ADD CONSTRAINT integrations_hooks_pkey PRIMARY KEY (id);


--
-- Name: labels labels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.labels
    ADD CONSTRAINT labels_pkey PRIMARY KEY (id);


--
-- Name: leaves leaves_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leaves
    ADD CONSTRAINT leaves_pkey PRIMARY KEY (id);


--
-- Name: macros macros_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.macros
    ADD CONSTRAINT macros_pkey PRIMARY KEY (id);


--
-- Name: mentions mentions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mentions
    ADD CONSTRAINT mentions_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: meta_conversion_events meta_conversion_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meta_conversion_events
    ADD CONSTRAINT meta_conversion_events_pkey PRIMARY KEY (id);


--
-- Name: notes notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notes
    ADD CONSTRAINT notes_pkey PRIMARY KEY (id);


--
-- Name: notification_settings notification_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_settings
    ADD CONSTRAINT notification_settings_pkey PRIMARY KEY (id);


--
-- Name: notification_subscriptions notification_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_subscriptions
    ADD CONSTRAINT notification_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: operational_flow_reasons operational_flow_reasons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_flow_reasons
    ADD CONSTRAINT operational_flow_reasons_pkey PRIMARY KEY (id);


--
-- Name: operational_flows operational_flows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_flows
    ADD CONSTRAINT operational_flows_pkey PRIMARY KEY (id);


--
-- Name: platform_app_permissibles platform_app_permissibles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_app_permissibles
    ADD CONSTRAINT platform_app_permissibles_pkey PRIMARY KEY (id);


--
-- Name: platform_apps platform_apps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_apps
    ADD CONSTRAINT platform_apps_pkey PRIMARY KEY (id);


--
-- Name: portals portals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.portals
    ADD CONSTRAINT portals_pkey PRIMARY KEY (id);


--
-- Name: provider_instances provider_instances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_instances
    ADD CONSTRAINT provider_instances_pkey PRIMARY KEY (id);


--
-- Name: related_categories related_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.related_categories
    ADD CONSTRAINT related_categories_pkey PRIMARY KEY (id);


--
-- Name: reporting_events reporting_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reporting_events
    ADD CONSTRAINT reporting_events_pkey PRIMARY KEY (id);


--
-- Name: reporting_events_rollups reporting_events_rollups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reporting_events_rollups
    ADD CONSTRAINT reporting_events_rollups_pkey PRIMARY KEY (id);


--
-- Name: resolution_states resolution_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resolution_states
    ADD CONSTRAINT resolution_states_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: sla_events sla_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_events
    ADD CONSTRAINT sla_events_pkey PRIMARY KEY (id);


--
-- Name: sla_policies sla_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sla_policies
    ADD CONSTRAINT sla_policies_pkey PRIMARY KEY (id);


--
-- Name: stickers stickers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stickers
    ADD CONSTRAINT stickers_pkey PRIMARY KEY (id);


--
-- Name: taggings taggings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.taggings
    ADD CONSTRAINT taggings_pkey PRIMARY KEY (id);


--
-- Name: tags tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tags
    ADD CONSTRAINT tags_pkey PRIMARY KEY (id);


--
-- Name: team_inboxes team_inboxes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_inboxes
    ADD CONSTRAINT team_inboxes_pkey PRIMARY KEY (id);


--
-- Name: team_members team_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_members
    ADD CONSTRAINT team_members_pkey PRIMARY KEY (id);


--
-- Name: teams teams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT teams_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: webhooks webhooks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhooks
    ADD CONSTRAINT webhooks_pkey PRIMARY KEY (id);


--
-- Name: working_hours working_hours_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.working_hours
    ADD CONSTRAINT working_hours_pkey PRIMARY KEY (id);


--
-- Name: working_periods working_periods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.working_periods
    ADD CONSTRAINT working_periods_pkey PRIMARY KEY (id);


--
-- Name: associated_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX associated_index ON public.audits USING btree (associated_type, associated_id);


--
-- Name: attribute_key_model_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX attribute_key_model_index ON public.custom_attribute_definitions USING btree (attribute_key, attribute_model, account_id);


--
-- Name: auditable_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX auditable_index ON public.audits USING btree (auditable_type, auditable_id, version);


--
-- Name: by_account_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX by_account_user ON public.notification_settings USING btree (account_id, user_id);


--
-- Name: conv_acid_inbid_stat_asgnid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conv_acid_inbid_stat_asgnid_idx ON public.conversations USING btree (account_id, inbox_id, status, assignee_id);


--
-- Name: idx_ai_department_inboxes_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ai_department_inboxes_unique ON public.ai_department_inboxes USING btree (ai_department_id, inbox_id);


--
-- Name: idx_ai_dept_integrations_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_ai_dept_integrations_unique ON public.ai_department_integrations USING btree (ai_department_id, ai_integration_link_id);


--
-- Name: idx_ai_knowledge_chunks_embedding; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ai_knowledge_chunks_embedding ON public.ai_knowledge_chunks USING ivfflat (embedding public.vector_cosine_ops);


--
-- Name: idx_cap_asst_resp_on_documentable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cap_asst_resp_on_documentable ON public.captain_assistant_responses USING btree (documentable_id, documentable_type);


--
-- Name: idx_closing_requirements_flow_attribute; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_closing_requirements_flow_attribute ON public.closing_requirements USING btree (operational_flow_id, attribute_key);


--
-- Name: idx_cre_account_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cre_account_created ON public.conversation_result_events USING btree (account_id, created_at);


--
-- Name: idx_cre_conversation_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cre_conversation_created ON public.conversation_result_events USING btree (conversation_id, created_at);


--
-- Name: idx_messages_account_content_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_messages_account_content_created ON public.messages USING btree (account_id, content_type, created_at);


--
-- Name: idx_notifications_performance; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notifications_performance ON public.notifications USING btree (user_id, account_id, snoozed_until, read_at);


--
-- Name: idx_ofr_flow_result_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ofr_flow_result_position ON public.operational_flow_reasons USING btree (operational_flow_id, result, "position");


--
-- Name: idx_on_agent_capacity_policy_id_inbox_id_71c7ec4caf; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_agent_capacity_policy_id_inbox_id_71c7ec4caf ON public.inbox_capacity_limits USING btree (agent_capacity_policy_id, inbox_id);


--
-- Name: idx_on_ai_department_id_version_number_5c61c735ff; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_on_ai_department_id_version_number_5c61c735ff ON public.ai_playbook_versions USING btree (ai_department_id, version_number);


--
-- Name: idx_provider_instances_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_provider_instances_unique ON public.provider_instances USING btree (account_id, provider, instance_name);


--
-- Name: idx_re_account_team_name_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_re_account_team_name_date ON public.reporting_events USING btree (account_id, team_id, name, created_at);


--
-- Name: idx_resolution_states_flow_canonical; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_resolution_states_flow_canonical ON public.resolution_states USING btree (operational_flow_id, canonical_key);


--
-- Name: index_access_tokens_on_owner_type_and_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_access_tokens_on_owner_type_and_owner_id ON public.access_tokens USING btree (owner_type, owner_id);


--
-- Name: index_access_tokens_on_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_access_tokens_on_token ON public.access_tokens USING btree (token);


--
-- Name: index_account_saml_settings_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_saml_settings_on_account_id ON public.account_saml_settings USING btree (account_id);


--
-- Name: index_account_users_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_users_on_account_id ON public.account_users USING btree (account_id);


--
-- Name: index_account_users_on_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_users_on_active ON public.account_users USING btree (active);


--
-- Name: index_account_users_on_agent_capacity_policy_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_users_on_agent_capacity_policy_id ON public.account_users USING btree (agent_capacity_policy_id);


--
-- Name: index_account_users_on_custom_role_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_users_on_custom_role_id ON public.account_users USING btree (custom_role_id);


--
-- Name: index_account_users_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_account_users_on_user_id ON public.account_users USING btree (user_id);


--
-- Name: index_accounts_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_accounts_on_status ON public.accounts USING btree (status);


--
-- Name: index_action_mailbox_inbound_emails_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_action_mailbox_inbound_emails_uniqueness ON public.action_mailbox_inbound_emails USING btree (message_id, message_checksum);


--
-- Name: index_active_storage_attachments_on_blob_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_active_storage_attachments_on_blob_id ON public.active_storage_attachments USING btree (blob_id);


--
-- Name: index_active_storage_attachments_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_attachments_uniqueness ON public.active_storage_attachments USING btree (record_type, record_id, name, blob_id);


--
-- Name: index_active_storage_blobs_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_blobs_on_key ON public.active_storage_blobs USING btree (key);


--
-- Name: index_active_storage_variant_records_uniqueness; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_active_storage_variant_records_uniqueness ON public.active_storage_variant_records USING btree (blob_id, variation_digest);


--
-- Name: index_agent_bots_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_bots_on_account_id ON public.agent_bots USING btree (account_id);


--
-- Name: index_agent_capacity_policies_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_capacity_policies_on_account_id ON public.agent_capacity_policies USING btree (account_id);


--
-- Name: index_agent_schedules_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_schedules_on_account_id ON public.agent_schedules USING btree (account_id);


--
-- Name: index_agent_schedules_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_agent_schedules_on_user_id ON public.agent_schedules USING btree (user_id);


--
-- Name: index_agent_schedules_on_user_id_and_day_of_week; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_agent_schedules_on_user_id_and_day_of_week ON public.agent_schedules USING btree (user_id, day_of_week);


--
-- Name: index_ai_agent_inboxes_on_ai_agent_id_and_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_agent_inboxes_on_ai_agent_id_and_inbox_id ON public.ai_agent_inboxes USING btree (ai_agent_id, inbox_id);


--
-- Name: index_ai_agent_inboxes_on_inbox_id_and_mode; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_agent_inboxes_on_inbox_id_and_mode ON public.ai_agent_inboxes USING btree (inbox_id, mode);


--
-- Name: index_ai_agent_memory_on_conversation_id_and_ai_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_agent_memory_on_conversation_id_and_ai_agent_id ON public.ai_agent_memory USING btree (conversation_id, ai_agent_id);


--
-- Name: index_ai_agent_versions_on_ai_agent_id_and_version_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_agent_versions_on_ai_agent_id_and_version_number ON public.ai_agent_versions USING btree (ai_agent_id, version_number);


--
-- Name: index_ai_agents_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_agents_on_account_id ON public.ai_agents USING btree (account_id);


--
-- Name: index_ai_agents_on_team_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_agents_on_team_id ON public.ai_agents USING btree (team_id);


--
-- Name: index_ai_capability_executions_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_capability_executions_on_account_id ON public.ai_capability_executions USING btree (account_id);


--
-- Name: index_ai_capability_executions_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_capability_executions_on_conversation_id ON public.ai_capability_executions USING btree (conversation_id);


--
-- Name: index_ai_capability_executions_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_capability_executions_on_status ON public.ai_capability_executions USING btree (status);


--
-- Name: index_ai_department_inboxes_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_department_inboxes_on_inbox_id ON public.ai_department_inboxes USING btree (inbox_id);


--
-- Name: index_ai_departments_on_ai_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_departments_on_ai_agent_id ON public.ai_departments USING btree (ai_agent_id);


--
-- Name: index_ai_events_on_ai_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_events_on_ai_run_id ON public.ai_events USING btree (ai_run_id);


--
-- Name: index_ai_events_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_events_on_conversation_id ON public.ai_events USING btree (conversation_id);


--
-- Name: index_ai_integration_links_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_integration_links_on_account_id ON public.ai_integration_links USING btree (account_id);


--
-- Name: index_ai_knowledge_chunks_on_ai_knowledge_source_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_knowledge_chunks_on_ai_knowledge_source_id ON public.ai_knowledge_chunks USING btree (ai_knowledge_source_id);


--
-- Name: index_ai_knowledge_sources_on_ai_department_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_knowledge_sources_on_ai_department_id ON public.ai_knowledge_sources USING btree (ai_department_id);


--
-- Name: index_ai_lead_variables_on_ai_department_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_lead_variables_on_ai_department_id ON public.ai_lead_variables USING btree (ai_department_id);


--
-- Name: index_ai_operation_profiles_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_operation_profiles_on_account_id ON public.ai_operation_profiles USING btree (account_id);


--
-- Name: index_ai_playbooks_on_ai_department_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_playbooks_on_ai_department_id ON public.ai_playbooks USING btree (ai_department_id);


--
-- Name: index_ai_runs_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_runs_on_account_id ON public.ai_runs USING btree (account_id);


--
-- Name: index_ai_runs_on_ai_department_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_runs_on_ai_department_id ON public.ai_runs USING btree (ai_department_id);


--
-- Name: index_ai_runs_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_runs_on_conversation_id ON public.ai_runs USING btree (conversation_id);


--
-- Name: index_ai_runs_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_runs_on_inbox_id ON public.ai_runs USING btree (inbox_id);


--
-- Name: index_ai_shadow_inboxes_on_ai_shadow_id_and_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_ai_shadow_inboxes_on_ai_shadow_id_and_inbox_id ON public.ai_shadow_inboxes USING btree (ai_shadow_id, inbox_id);


--
-- Name: index_ai_shadow_inboxes_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_shadow_inboxes_on_inbox_id ON public.ai_shadow_inboxes USING btree (inbox_id);


--
-- Name: index_ai_shadows_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_shadows_on_account_id ON public.ai_shadows USING btree (account_id);


--
-- Name: index_ai_tools_on_ai_department_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_ai_tools_on_ai_department_id ON public.ai_tools USING btree (ai_department_id);


--
-- Name: index_applied_slas_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_applied_slas_on_account_id ON public.applied_slas USING btree (account_id);


--
-- Name: index_applied_slas_on_account_sla_policy_conversation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_applied_slas_on_account_sla_policy_conversation ON public.applied_slas USING btree (account_id, sla_policy_id, conversation_id);


--
-- Name: index_applied_slas_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_applied_slas_on_conversation_id ON public.applied_slas USING btree (conversation_id);


--
-- Name: index_applied_slas_on_sla_policy_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_applied_slas_on_sla_policy_id ON public.applied_slas USING btree (sla_policy_id);


--
-- Name: index_article_embeddings_on_embedding; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_article_embeddings_on_embedding ON public.article_embeddings USING ivfflat (embedding);


--
-- Name: index_articles_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_articles_on_account_id ON public.articles USING btree (account_id);


--
-- Name: index_articles_on_associated_article_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_articles_on_associated_article_id ON public.articles USING btree (associated_article_id);


--
-- Name: index_articles_on_author_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_articles_on_author_id ON public.articles USING btree (author_id);


--
-- Name: index_articles_on_portal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_articles_on_portal_id ON public.articles USING btree (portal_id);


--
-- Name: index_articles_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_articles_on_slug ON public.articles USING btree (slug);


--
-- Name: index_articles_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_articles_on_status ON public.articles USING btree (status);


--
-- Name: index_articles_on_views; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_articles_on_views ON public.articles USING btree (views);


--
-- Name: index_assignment_policies_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_assignment_policies_on_account_id ON public.assignment_policies USING btree (account_id);


--
-- Name: index_assignment_policies_on_account_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_assignment_policies_on_account_id_and_name ON public.assignment_policies USING btree (account_id, name);


--
-- Name: index_assignment_policies_on_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_assignment_policies_on_enabled ON public.assignment_policies USING btree (enabled);


--
-- Name: index_attachments_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_attachments_on_account_id ON public.attachments USING btree (account_id);


--
-- Name: index_attachments_on_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_attachments_on_message_id ON public.attachments USING btree (message_id);


--
-- Name: index_audits_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audits_on_created_at ON public.audits USING btree (created_at);


--
-- Name: index_audits_on_request_uuid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audits_on_request_uuid ON public.audits USING btree (request_uuid);


--
-- Name: index_automation_rules_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_automation_rules_on_account_id ON public.automation_rules USING btree (account_id);


--
-- Name: index_calls_on_account_id_and_contact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_calls_on_account_id_and_contact_id ON public.calls USING btree (account_id, contact_id);


--
-- Name: index_calls_on_account_id_and_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_calls_on_account_id_and_conversation_id ON public.calls USING btree (account_id, conversation_id);


--
-- Name: index_calls_on_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_calls_on_message_id ON public.calls USING btree (message_id);


--
-- Name: index_calls_on_provider_and_provider_call_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_calls_on_provider_and_provider_call_id ON public.calls USING btree (provider, provider_call_id);


--
-- Name: index_campaigns_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_campaigns_on_account_id ON public.campaigns USING btree (account_id);


--
-- Name: index_campaigns_on_campaign_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_campaigns_on_campaign_status ON public.campaigns USING btree (campaign_status);


--
-- Name: index_campaigns_on_campaign_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_campaigns_on_campaign_type ON public.campaigns USING btree (campaign_type);


--
-- Name: index_campaigns_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_campaigns_on_inbox_id ON public.campaigns USING btree (inbox_id);


--
-- Name: index_campaigns_on_scheduled_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_campaigns_on_scheduled_at ON public.campaigns USING btree (scheduled_at);


--
-- Name: index_captain_assistant_responses_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captain_assistant_responses_on_account_id ON public.captain_assistant_responses USING btree (account_id);


--
-- Name: index_captain_assistant_responses_on_assistant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captain_assistant_responses_on_assistant_id ON public.captain_assistant_responses USING btree (assistant_id);


--
-- Name: index_captain_assistant_responses_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captain_assistant_responses_on_status ON public.captain_assistant_responses USING btree (status);


--
-- Name: index_captain_assistants_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captain_assistants_on_account_id ON public.captain_assistants USING btree (account_id);


--
-- Name: index_captain_custom_tools_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captain_custom_tools_on_account_id ON public.captain_custom_tools USING btree (account_id);


--
-- Name: index_captain_custom_tools_on_account_id_and_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_captain_custom_tools_on_account_id_and_slug ON public.captain_custom_tools USING btree (account_id, slug);


--
-- Name: index_captain_documents_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captain_documents_on_account_id ON public.captain_documents USING btree (account_id);


--
-- Name: index_captain_documents_on_account_id_and_sync_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captain_documents_on_account_id_and_sync_status ON public.captain_documents USING btree (account_id, sync_status);


--
-- Name: index_captain_documents_on_assistant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captain_documents_on_assistant_id ON public.captain_documents USING btree (assistant_id);


--
-- Name: index_captain_documents_on_assistant_id_and_external_link; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_captain_documents_on_assistant_id_and_external_link ON public.captain_documents USING btree (assistant_id, external_link);


--
-- Name: index_captain_documents_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captain_documents_on_status ON public.captain_documents USING btree (status);


--
-- Name: index_captain_inboxes_on_captain_assistant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captain_inboxes_on_captain_assistant_id ON public.captain_inboxes USING btree (captain_assistant_id);


--
-- Name: index_captain_inboxes_on_captain_assistant_id_and_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_captain_inboxes_on_captain_assistant_id_and_inbox_id ON public.captain_inboxes USING btree (captain_assistant_id, inbox_id);


--
-- Name: index_captain_inboxes_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captain_inboxes_on_inbox_id ON public.captain_inboxes USING btree (inbox_id);


--
-- Name: index_captain_scenarios_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captain_scenarios_on_account_id ON public.captain_scenarios USING btree (account_id);


--
-- Name: index_captain_scenarios_on_assistant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captain_scenarios_on_assistant_id ON public.captain_scenarios USING btree (assistant_id);


--
-- Name: index_captain_scenarios_on_assistant_id_and_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captain_scenarios_on_assistant_id_and_enabled ON public.captain_scenarios USING btree (assistant_id, enabled);


--
-- Name: index_captain_scenarios_on_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_captain_scenarios_on_enabled ON public.captain_scenarios USING btree (enabled);


--
-- Name: index_categories_on_associated_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_categories_on_associated_category_id ON public.categories USING btree (associated_category_id);


--
-- Name: index_categories_on_locale; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_categories_on_locale ON public.categories USING btree (locale);


--
-- Name: index_categories_on_locale_and_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_categories_on_locale_and_account_id ON public.categories USING btree (locale, account_id);


--
-- Name: index_categories_on_parent_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_categories_on_parent_category_id ON public.categories USING btree (parent_category_id);


--
-- Name: index_categories_on_slug_and_locale_and_portal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_categories_on_slug_and_locale_and_portal_id ON public.categories USING btree (slug, locale, portal_id);


--
-- Name: index_channel_api_on_hmac_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_api_on_hmac_token ON public.channel_api USING btree (hmac_token);


--
-- Name: index_channel_api_on_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_api_on_identifier ON public.channel_api USING btree (identifier);


--
-- Name: index_channel_email_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_email_on_email ON public.channel_email USING btree (email);


--
-- Name: index_channel_email_on_forward_to_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_email_on_forward_to_email ON public.channel_email USING btree (forward_to_email);


--
-- Name: index_channel_facebook_pages_on_page_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_channel_facebook_pages_on_page_id ON public.channel_facebook_pages USING btree (page_id);


--
-- Name: index_channel_facebook_pages_on_page_id_and_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_facebook_pages_on_page_id_and_account_id ON public.channel_facebook_pages USING btree (page_id, account_id);


--
-- Name: index_channel_instagram_on_instagram_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_instagram_on_instagram_id ON public.channel_instagram USING btree (instagram_id);


--
-- Name: index_channel_line_on_line_channel_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_line_on_line_channel_id ON public.channel_line USING btree (line_channel_id);


--
-- Name: index_channel_sms_on_phone_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_sms_on_phone_number ON public.channel_sms USING btree (phone_number);


--
-- Name: index_channel_telegram_on_bot_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_telegram_on_bot_token ON public.channel_telegram USING btree (bot_token);


--
-- Name: index_channel_tiktok_on_business_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_tiktok_on_business_id ON public.channel_tiktok USING btree (business_id);


--
-- Name: index_channel_twilio_sms_on_account_sid_and_phone_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_twilio_sms_on_account_sid_and_phone_number ON public.channel_twilio_sms USING btree (account_sid, phone_number);


--
-- Name: index_channel_twilio_sms_on_messaging_service_sid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_twilio_sms_on_messaging_service_sid ON public.channel_twilio_sms USING btree (messaging_service_sid);


--
-- Name: index_channel_twilio_sms_on_phone_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_twilio_sms_on_phone_number ON public.channel_twilio_sms USING btree (phone_number);


--
-- Name: index_channel_twitter_profiles_on_account_id_and_profile_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_twitter_profiles_on_account_id_and_profile_id ON public.channel_twitter_profiles USING btree (account_id, profile_id);


--
-- Name: index_channel_voice_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_channel_voice_on_account_id ON public.channel_voice USING btree (account_id);


--
-- Name: index_channel_voice_on_phone_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_voice_on_phone_number ON public.channel_voice USING btree (phone_number);


--
-- Name: index_channel_web_widgets_on_hmac_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_web_widgets_on_hmac_token ON public.channel_web_widgets USING btree (hmac_token);


--
-- Name: index_channel_web_widgets_on_website_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_web_widgets_on_website_token ON public.channel_web_widgets USING btree (website_token);


--
-- Name: index_channel_whatsapp_on_phone_number; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_channel_whatsapp_on_phone_number ON public.channel_whatsapp USING btree (phone_number);


--
-- Name: index_closing_requirements_on_operational_flow_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_closing_requirements_on_operational_flow_id ON public.closing_requirements USING btree (operational_flow_id);


--
-- Name: index_companies_on_account_and_domain; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_companies_on_account_and_domain ON public.companies USING btree (account_id, domain) WHERE (domain IS NOT NULL);


--
-- Name: index_companies_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_companies_on_account_id ON public.companies USING btree (account_id);


--
-- Name: index_companies_on_name_and_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_companies_on_name_and_account_id ON public.companies USING btree (name, account_id);


--
-- Name: index_contact_inboxes_on_contact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contact_inboxes_on_contact_id ON public.contact_inboxes USING btree (contact_id);


--
-- Name: index_contact_inboxes_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contact_inboxes_on_inbox_id ON public.contact_inboxes USING btree (inbox_id);


--
-- Name: index_contact_inboxes_on_inbox_id_and_source_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contact_inboxes_on_inbox_id_and_source_id ON public.contact_inboxes USING btree (inbox_id, source_id);


--
-- Name: index_contact_inboxes_on_pubsub_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contact_inboxes_on_pubsub_token ON public.contact_inboxes USING btree (pubsub_token);


--
-- Name: index_contact_inboxes_on_source_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contact_inboxes_on_source_id ON public.contact_inboxes USING btree (source_id);


--
-- Name: index_contacts_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contacts_on_account_id ON public.contacts USING btree (account_id);


--
-- Name: index_contacts_on_account_id_and_contact_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contacts_on_account_id_and_contact_type ON public.contacts USING btree (account_id, contact_type);


--
-- Name: index_contacts_on_account_id_and_last_activity_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contacts_on_account_id_and_last_activity_at ON public.contacts USING btree (account_id, last_activity_at DESC NULLS LAST);


--
-- Name: index_contacts_on_blocked; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contacts_on_blocked ON public.contacts USING btree (blocked);


--
-- Name: index_contacts_on_company_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contacts_on_company_id ON public.contacts USING btree (company_id);


--
-- Name: index_contacts_on_lower_email_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contacts_on_lower_email_account_id ON public.contacts USING btree (lower((email)::text), account_id);


--
-- Name: index_contacts_on_name_email_phone_number_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contacts_on_name_email_phone_number_identifier ON public.contacts USING gin (name public.gin_trgm_ops, email public.gin_trgm_ops, phone_number public.gin_trgm_ops, identifier public.gin_trgm_ops);


--
-- Name: index_contacts_on_nonempty_fields; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contacts_on_nonempty_fields ON public.contacts USING btree (account_id, email, phone_number, identifier) WHERE (((email)::text <> ''::text) OR ((phone_number)::text <> ''::text) OR ((identifier)::text <> ''::text));


--
-- Name: index_contacts_on_phone_number_and_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contacts_on_phone_number_and_account_id ON public.contacts USING btree (phone_number, account_id);


--
-- Name: index_conversation_participants_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversation_participants_on_account_id ON public.conversation_participants USING btree (account_id);


--
-- Name: index_conversation_participants_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversation_participants_on_conversation_id ON public.conversation_participants USING btree (conversation_id);


--
-- Name: index_conversation_participants_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversation_participants_on_user_id ON public.conversation_participants USING btree (user_id);


--
-- Name: index_conversation_participants_on_user_id_and_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_conversation_participants_on_user_id_and_conversation_id ON public.conversation_participants USING btree (user_id, conversation_id);


--
-- Name: index_conversation_result_events_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversation_result_events_on_conversation_id ON public.conversation_result_events USING btree (conversation_id);


--
-- Name: index_conversations_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_account_id ON public.conversations USING btree (account_id);


--
-- Name: index_conversations_on_account_id_and_display_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_conversations_on_account_id_and_display_id ON public.conversations USING btree (account_id, display_id);


--
-- Name: index_conversations_on_account_id_and_result; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_account_id_and_result ON public.conversations USING btree (account_id, result);


--
-- Name: index_conversations_on_assignee_id_and_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_assignee_id_and_account_id ON public.conversations USING btree (assignee_id, account_id);


--
-- Name: index_conversations_on_campaign_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_campaign_id ON public.conversations USING btree (campaign_id);


--
-- Name: index_conversations_on_contact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_contact_id ON public.conversations USING btree (contact_id);


--
-- Name: index_conversations_on_contact_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_contact_inbox_id ON public.conversations USING btree (contact_inbox_id);


--
-- Name: index_conversations_on_first_reply_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_first_reply_created_at ON public.conversations USING btree (first_reply_created_at);


--
-- Name: index_conversations_on_id_and_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_id_and_account_id ON public.conversations USING btree (account_id, id);


--
-- Name: index_conversations_on_identifier_and_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_identifier_and_account_id ON public.conversations USING btree (identifier, account_id);


--
-- Name: index_conversations_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_inbox_id ON public.conversations USING btree (inbox_id);


--
-- Name: index_conversations_on_priority; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_priority ON public.conversations USING btree (priority);


--
-- Name: index_conversations_on_status_and_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_status_and_account_id ON public.conversations USING btree (status, account_id);


--
-- Name: index_conversations_on_status_and_priority; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_status_and_priority ON public.conversations USING btree (status, priority);


--
-- Name: index_conversations_on_team_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_team_id ON public.conversations USING btree (team_id);


--
-- Name: index_conversations_on_uuid; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_conversations_on_uuid ON public.conversations USING btree (uuid);


--
-- Name: index_conversations_on_waiting_since; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_waiting_since ON public.conversations USING btree (waiting_since);


--
-- Name: index_copilot_messages_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_copilot_messages_on_account_id ON public.copilot_messages USING btree (account_id);


--
-- Name: index_copilot_messages_on_copilot_thread_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_copilot_messages_on_copilot_thread_id ON public.copilot_messages USING btree (copilot_thread_id);


--
-- Name: index_copilot_threads_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_copilot_threads_on_account_id ON public.copilot_threads USING btree (account_id);


--
-- Name: index_copilot_threads_on_assistant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_copilot_threads_on_assistant_id ON public.copilot_threads USING btree (assistant_id);


--
-- Name: index_copilot_threads_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_copilot_threads_on_user_id ON public.copilot_threads USING btree (user_id);


--
-- Name: index_csat_survey_responses_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_csat_survey_responses_on_account_id ON public.csat_survey_responses USING btree (account_id);


--
-- Name: index_csat_survey_responses_on_assigned_agent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_csat_survey_responses_on_assigned_agent_id ON public.csat_survey_responses USING btree (assigned_agent_id);


--
-- Name: index_csat_survey_responses_on_contact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_csat_survey_responses_on_contact_id ON public.csat_survey_responses USING btree (contact_id);


--
-- Name: index_csat_survey_responses_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_csat_survey_responses_on_conversation_id ON public.csat_survey_responses USING btree (conversation_id);


--
-- Name: index_csat_survey_responses_on_message_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_csat_survey_responses_on_message_id ON public.csat_survey_responses USING btree (message_id);


--
-- Name: index_csat_survey_responses_on_review_notes_updated_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_csat_survey_responses_on_review_notes_updated_by_id ON public.csat_survey_responses USING btree (review_notes_updated_by_id);


--
-- Name: index_custom_attribute_definitions_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_custom_attribute_definitions_on_account_id ON public.custom_attribute_definitions USING btree (account_id);


--
-- Name: index_custom_filters_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_custom_filters_on_account_id ON public.custom_filters USING btree (account_id);


--
-- Name: index_custom_filters_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_custom_filters_on_user_id ON public.custom_filters USING btree (user_id);


--
-- Name: index_custom_roles_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_custom_roles_on_account_id ON public.custom_roles USING btree (account_id);


--
-- Name: index_dashboard_apps_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_dashboard_apps_on_account_id ON public.dashboard_apps USING btree (account_id);


--
-- Name: index_dashboard_apps_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_dashboard_apps_on_user_id ON public.dashboard_apps USING btree (user_id);


--
-- Name: index_data_imports_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_data_imports_on_account_id ON public.data_imports USING btree (account_id);


--
-- Name: index_email_templates_on_name_and_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_email_templates_on_name_and_account_id ON public.email_templates USING btree (name, account_id);


--
-- Name: index_inbox_assignment_policies_on_assignment_policy_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inbox_assignment_policies_on_assignment_policy_id ON public.inbox_assignment_policies USING btree (assignment_policy_id);


--
-- Name: index_inbox_assignment_policies_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_inbox_assignment_policies_on_inbox_id ON public.inbox_assignment_policies USING btree (inbox_id);


--
-- Name: index_inbox_capacity_limits_on_agent_capacity_policy_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inbox_capacity_limits_on_agent_capacity_policy_id ON public.inbox_capacity_limits USING btree (agent_capacity_policy_id);


--
-- Name: index_inbox_capacity_limits_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inbox_capacity_limits_on_inbox_id ON public.inbox_capacity_limits USING btree (inbox_id);


--
-- Name: index_inbox_exceptions_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inbox_exceptions_on_account_id ON public.inbox_exceptions USING btree (account_id);


--
-- Name: index_inbox_exceptions_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inbox_exceptions_on_inbox_id ON public.inbox_exceptions USING btree (inbox_id);


--
-- Name: index_inbox_holidays_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inbox_holidays_on_account_id ON public.inbox_holidays USING btree (account_id);


--
-- Name: index_inbox_holidays_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inbox_holidays_on_inbox_id ON public.inbox_holidays USING btree (inbox_id);


--
-- Name: index_inbox_members_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inbox_members_on_inbox_id ON public.inbox_members USING btree (inbox_id);


--
-- Name: index_inbox_members_on_inbox_id_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_inbox_members_on_inbox_id_and_user_id ON public.inbox_members USING btree (inbox_id, user_id);


--
-- Name: index_inboxes_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inboxes_on_account_id ON public.inboxes USING btree (account_id);


--
-- Name: index_inboxes_on_channel_id_and_channel_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inboxes_on_channel_id_and_channel_type ON public.inboxes USING btree (channel_id, channel_type);


--
-- Name: index_inboxes_on_operational_flow_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inboxes_on_operational_flow_id ON public.inboxes USING btree (operational_flow_id);


--
-- Name: index_inboxes_on_portal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_inboxes_on_portal_id ON public.inboxes USING btree (portal_id);


--
-- Name: index_installation_configs_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_installation_configs_on_name ON public.installation_configs USING btree (name);


--
-- Name: index_installation_configs_on_name_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_installation_configs_on_name_and_created_at ON public.installation_configs USING btree (name, created_at);


--
-- Name: index_integration_settings_global_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_integration_settings_global_provider ON public.integration_settings USING btree (provider) WHERE (account_id IS NULL);


--
-- Name: index_integration_settings_on_account_id_and_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_integration_settings_on_account_id_and_provider ON public.integration_settings USING btree (account_id, provider) WHERE (account_id IS NOT NULL);


--
-- Name: index_labels_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_labels_on_account_id ON public.labels USING btree (account_id);


--
-- Name: index_labels_on_title_and_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_labels_on_title_and_account_id ON public.labels USING btree (title, account_id);


--
-- Name: index_leaves_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_leaves_on_account_id ON public.leaves USING btree (account_id);


--
-- Name: index_leaves_on_account_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_leaves_on_account_id_and_status ON public.leaves USING btree (account_id, status);


--
-- Name: index_leaves_on_approved_by_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_leaves_on_approved_by_id ON public.leaves USING btree (approved_by_id);


--
-- Name: index_leaves_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_leaves_on_user_id ON public.leaves USING btree (user_id);


--
-- Name: index_macros_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_macros_on_account_id ON public.macros USING btree (account_id);


--
-- Name: index_mentions_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mentions_on_account_id ON public.mentions USING btree (account_id);


--
-- Name: index_mentions_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mentions_on_conversation_id ON public.mentions USING btree (conversation_id);


--
-- Name: index_mentions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_mentions_on_user_id ON public.mentions USING btree (user_id);


--
-- Name: index_mentions_on_user_id_and_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_mentions_on_user_id_and_conversation_id ON public.mentions USING btree (user_id, conversation_id);


--
-- Name: index_messages_on_account_created_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_account_created_type ON public.messages USING btree (account_id, created_at, message_type);


--
-- Name: index_messages_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_account_id ON public.messages USING btree (account_id);


--
-- Name: index_messages_on_account_id_and_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_account_id_and_inbox_id ON public.messages USING btree (account_id, inbox_id);


--
-- Name: index_messages_on_additional_attributes_campaign_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_additional_attributes_campaign_id ON public.messages USING gin (((additional_attributes -> 'campaign_id'::text)));


--
-- Name: index_messages_on_content; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_content ON public.messages USING gin (content public.gin_trgm_ops);


--
-- Name: index_messages_on_conversation_account_type_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_conversation_account_type_created ON public.messages USING btree (conversation_id, account_id, message_type, created_at);


--
-- Name: index_messages_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_conversation_id ON public.messages USING btree (conversation_id);


--
-- Name: index_messages_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_created_at ON public.messages USING btree (created_at);


--
-- Name: index_messages_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_inbox_id ON public.messages USING btree (inbox_id);


--
-- Name: index_messages_on_sender_type_and_sender_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_sender_type_and_sender_id ON public.messages USING btree (sender_type, sender_id);


--
-- Name: index_messages_on_source_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_source_id ON public.messages USING btree (source_id);


--
-- Name: index_meta_conversion_events_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_meta_conversion_events_on_account_id ON public.meta_conversion_events USING btree (account_id);


--
-- Name: index_meta_conversion_events_on_account_id_and_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_meta_conversion_events_on_account_id_and_created_at ON public.meta_conversion_events USING btree (account_id, created_at);


--
-- Name: index_meta_conversion_events_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_meta_conversion_events_on_conversation_id ON public.meta_conversion_events USING btree (conversation_id);


--
-- Name: index_notes_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notes_on_account_id ON public.notes USING btree (account_id);


--
-- Name: index_notes_on_contact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notes_on_contact_id ON public.notes USING btree (contact_id);


--
-- Name: index_notes_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notes_on_user_id ON public.notes USING btree (user_id);


--
-- Name: index_notification_subscriptions_on_identifier; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_notification_subscriptions_on_identifier ON public.notification_subscriptions USING btree (identifier);


--
-- Name: index_notification_subscriptions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notification_subscriptions_on_user_id ON public.notification_subscriptions USING btree (user_id);


--
-- Name: index_notifications_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_account_id ON public.notifications USING btree (account_id);


--
-- Name: index_notifications_on_last_activity_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_last_activity_at ON public.notifications USING btree (last_activity_at);


--
-- Name: index_notifications_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_notifications_on_user_id ON public.notifications USING btree (user_id);


--
-- Name: index_operational_flow_reasons_on_operational_flow_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_operational_flow_reasons_on_operational_flow_id ON public.operational_flow_reasons USING btree (operational_flow_id);


--
-- Name: index_operational_flow_reasons_on_resolution_state_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_operational_flow_reasons_on_resolution_state_id ON public.operational_flow_reasons USING btree (resolution_state_id);


--
-- Name: index_operational_flows_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_operational_flows_on_account_id ON public.operational_flows USING btree (account_id);


--
-- Name: index_operational_flows_on_account_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_operational_flows_on_account_id_and_name ON public.operational_flows USING btree (account_id, name);


--
-- Name: index_platform_app_permissibles_on_permissibles; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_platform_app_permissibles_on_permissibles ON public.platform_app_permissibles USING btree (permissible_type, permissible_id);


--
-- Name: index_platform_app_permissibles_on_platform_app_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_platform_app_permissibles_on_platform_app_id ON public.platform_app_permissibles USING btree (platform_app_id);


--
-- Name: index_portals_members_on_portal_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_portals_members_on_portal_id ON public.portals_members USING btree (portal_id);


--
-- Name: index_portals_members_on_portal_id_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_portals_members_on_portal_id_and_user_id ON public.portals_members USING btree (portal_id, user_id);


--
-- Name: index_portals_members_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_portals_members_on_user_id ON public.portals_members USING btree (user_id);


--
-- Name: index_portals_on_channel_web_widget_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_portals_on_channel_web_widget_id ON public.portals USING btree (channel_web_widget_id);


--
-- Name: index_portals_on_custom_domain; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_portals_on_custom_domain ON public.portals USING btree (custom_domain);


--
-- Name: index_portals_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_portals_on_slug ON public.portals USING btree (slug);


--
-- Name: index_provider_instances_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_provider_instances_on_account_id ON public.provider_instances USING btree (account_id);


--
-- Name: index_provider_instances_on_account_id_and_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_provider_instances_on_account_id_and_provider ON public.provider_instances USING btree (account_id, provider);


--
-- Name: index_related_categories_on_category_id_and_related_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_related_categories_on_category_id_and_related_category_id ON public.related_categories USING btree (category_id, related_category_id);


--
-- Name: index_related_categories_on_related_category_id_and_category_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_related_categories_on_related_category_id_and_category_id ON public.related_categories USING btree (related_category_id, category_id);


--
-- Name: index_reporting_events_for_response_distribution; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reporting_events_for_response_distribution ON public.reporting_events USING btree (account_id, name, inbox_id, created_at);


--
-- Name: index_reporting_events_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reporting_events_on_account_id ON public.reporting_events USING btree (account_id);


--
-- Name: index_reporting_events_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reporting_events_on_conversation_id ON public.reporting_events USING btree (conversation_id);


--
-- Name: index_reporting_events_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reporting_events_on_created_at ON public.reporting_events USING btree (created_at);


--
-- Name: index_reporting_events_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reporting_events_on_inbox_id ON public.reporting_events USING btree (inbox_id);


--
-- Name: index_reporting_events_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reporting_events_on_name ON public.reporting_events USING btree (name);


--
-- Name: index_reporting_events_on_team_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reporting_events_on_team_id ON public.reporting_events USING btree (team_id);


--
-- Name: index_reporting_events_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reporting_events_on_user_id ON public.reporting_events USING btree (user_id);


--
-- Name: index_resolution_states_on_operational_flow_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_resolution_states_on_operational_flow_id ON public.resolution_states USING btree (operational_flow_id);


--
-- Name: index_resolved_contact_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_resolved_contact_account_id ON public.contacts USING btree (account_id) WHERE (((email)::text <> ''::text) OR ((phone_number)::text <> ''::text) OR ((identifier)::text <> ''::text));


--
-- Name: index_rollup_summary; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rollup_summary ON public.reporting_events_rollups USING btree (account_id, dimension_type, date);


--
-- Name: index_rollup_timeseries; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_rollup_timeseries ON public.reporting_events_rollups USING btree (account_id, metric, date);


--
-- Name: index_rollup_unique_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_rollup_unique_key ON public.reporting_events_rollups USING btree (account_id, date, dimension_type, dimension_id, metric);


--
-- Name: index_sla_events_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sla_events_on_account_id ON public.sla_events USING btree (account_id);


--
-- Name: index_sla_events_on_applied_sla_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sla_events_on_applied_sla_id ON public.sla_events USING btree (applied_sla_id);


--
-- Name: index_sla_events_on_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sla_events_on_conversation_id ON public.sla_events USING btree (conversation_id);


--
-- Name: index_sla_events_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sla_events_on_inbox_id ON public.sla_events USING btree (inbox_id);


--
-- Name: index_sla_events_on_sla_policy_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sla_events_on_sla_policy_id ON public.sla_events USING btree (sla_policy_id);


--
-- Name: index_sla_policies_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sla_policies_on_account_id ON public.sla_policies USING btree (account_id);


--
-- Name: index_stickers_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_stickers_on_account_id ON public.stickers USING btree (account_id);


--
-- Name: index_taggings_on_context; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_taggings_on_context ON public.taggings USING btree (context);


--
-- Name: index_taggings_on_tag_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_taggings_on_tag_id ON public.taggings USING btree (tag_id);


--
-- Name: index_taggings_on_taggable_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_taggings_on_taggable_id ON public.taggings USING btree (taggable_id);


--
-- Name: index_taggings_on_taggable_id_and_taggable_type_and_context; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_taggings_on_taggable_id_and_taggable_type_and_context ON public.taggings USING btree (taggable_id, taggable_type, context);


--
-- Name: index_taggings_on_taggable_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_taggings_on_taggable_type ON public.taggings USING btree (taggable_type);


--
-- Name: index_taggings_on_tagger_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_taggings_on_tagger_id ON public.taggings USING btree (tagger_id);


--
-- Name: index_taggings_on_tagger_id_and_tagger_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_taggings_on_tagger_id_and_tagger_type ON public.taggings USING btree (tagger_id, tagger_type);


--
-- Name: index_tags_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_tags_on_name ON public.tags USING btree (name);


--
-- Name: index_team_inboxes_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_team_inboxes_on_inbox_id ON public.team_inboxes USING btree (inbox_id);


--
-- Name: index_team_inboxes_on_team_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_team_inboxes_on_team_id ON public.team_inboxes USING btree (team_id);


--
-- Name: index_team_inboxes_on_team_id_and_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_team_inboxes_on_team_id_and_inbox_id ON public.team_inboxes USING btree (team_id, inbox_id);


--
-- Name: index_team_members_on_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_team_members_on_role ON public.team_members USING btree (role);


--
-- Name: index_team_members_on_team_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_team_members_on_team_id ON public.team_members USING btree (team_id);


--
-- Name: index_team_members_on_team_id_and_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_team_members_on_team_id_and_user_id ON public.team_members USING btree (team_id, user_id);


--
-- Name: index_team_members_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_team_members_on_user_id ON public.team_members USING btree (user_id);


--
-- Name: index_teams_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_teams_on_account_id ON public.teams USING btree (account_id);


--
-- Name: index_teams_on_name_and_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_teams_on_name_and_account_id ON public.teams USING btree (name, account_id);


--
-- Name: index_teams_on_operational_flow_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_teams_on_operational_flow_id ON public.teams USING btree (operational_flow_id);


--
-- Name: index_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_email ON public.users USING btree (email);


--
-- Name: index_users_on_otp_required_for_login; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_otp_required_for_login ON public.users USING btree (otp_required_for_login);


--
-- Name: index_users_on_otp_secret; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_otp_secret ON public.users USING btree (otp_secret);


--
-- Name: index_users_on_pubsub_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_pubsub_token ON public.users USING btree (pubsub_token);


--
-- Name: index_users_on_reset_password_token; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_reset_password_token ON public.users USING btree (reset_password_token);


--
-- Name: index_users_on_uid_and_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_uid_and_provider ON public.users USING btree (uid, provider);


--
-- Name: index_webhooks_on_account_id_and_url; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_webhooks_on_account_id_and_url ON public.webhooks USING btree (account_id, url);


--
-- Name: index_working_hours_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_working_hours_on_account_id ON public.working_hours USING btree (account_id);


--
-- Name: index_working_hours_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_working_hours_on_inbox_id ON public.working_hours USING btree (inbox_id);


--
-- Name: index_working_periods_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_working_periods_on_account_id ON public.working_periods USING btree (account_id);


--
-- Name: index_working_periods_on_inbox_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_working_periods_on_inbox_id ON public.working_periods USING btree (inbox_id);


--
-- Name: index_working_periods_on_inbox_id_and_day_of_week; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_working_periods_on_inbox_id_and_day_of_week ON public.working_periods USING btree (inbox_id, day_of_week);


--
-- Name: reporting_events__account_id__name__created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reporting_events__account_id__name__created_at ON public.reporting_events USING btree (account_id, name, created_at);


--
-- Name: taggings_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX taggings_idx ON public.taggings USING btree (tag_id, taggable_id, taggable_type, context, tagger_id, tagger_type);


--
-- Name: taggings_idy; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX taggings_idy ON public.taggings USING btree (taggable_id, taggable_type, tagger_id, context);


--
-- Name: tags_name_trgm_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tags_name_trgm_idx ON public.tags USING gin (lower((name)::text) public.gin_trgm_ops);


--
-- Name: uniq_email_per_account_contact; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_email_per_account_contact ON public.contacts USING btree (email, account_id);


--
-- Name: uniq_identifier_per_account_contact; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_identifier_per_account_contact ON public.contacts USING btree (identifier, account_id);


--
-- Name: uniq_primary_actor_per_account_notifications; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX uniq_primary_actor_per_account_notifications ON public.notifications USING btree (primary_actor_type, primary_actor_id);


--
-- Name: uniq_secondary_actor_per_account_notifications; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX uniq_secondary_actor_per_account_notifications ON public.notifications USING btree (secondary_actor_type, secondary_actor_id);


--
-- Name: uniq_user_id_per_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uniq_user_id_per_account_id ON public.account_users USING btree (account_id, user_id);


--
-- Name: unique_permissibles_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX unique_permissibles_index ON public.platform_app_permissibles USING btree (platform_app_id, permissible_id, permissible_type);


--
-- Name: user_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_index ON public.audits USING btree (user_id, user_type);


--
-- Name: vector_idx_knowledge_entries_embedding; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vector_idx_knowledge_entries_embedding ON public.captain_assistant_responses USING ivfflat (embedding);


--
-- Name: accounts accounts_after_insert_row_tr; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER accounts_after_insert_row_tr AFTER INSERT ON public.accounts FOR EACH ROW EXECUTE FUNCTION public.accounts_after_insert_row_tr();


--
-- Name: accounts camp_dpid_before_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER camp_dpid_before_insert AFTER INSERT ON public.accounts FOR EACH ROW EXECUTE FUNCTION public.camp_dpid_before_insert();


--
-- Name: campaigns campaigns_before_insert_row_tr; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER campaigns_before_insert_row_tr BEFORE INSERT ON public.campaigns FOR EACH ROW EXECUTE FUNCTION public.campaigns_before_insert_row_tr();


--
-- Name: conversations conversations_before_insert_row_tr; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER conversations_before_insert_row_tr BEFORE INSERT ON public.conversations FOR EACH ROW EXECUTE FUNCTION public.conversations_before_insert_row_tr();


--
-- Name: working_periods fk_rails_1206a1c65d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.working_periods
    ADD CONSTRAINT fk_rails_1206a1c65d FOREIGN KEY (inbox_id) REFERENCES public.inboxes(id);


--
-- Name: operational_flow_reasons fk_rails_1359821d16; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_flow_reasons
    ADD CONSTRAINT fk_rails_1359821d16 FOREIGN KEY (resolution_state_id) REFERENCES public.resolution_states(id);


--
-- Name: operational_flows fk_rails_1b1a9ccaa8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_flows
    ADD CONSTRAINT fk_rails_1b1a9ccaa8 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: agent_schedules fk_rails_1df0c6ac44; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_schedules
    ADD CONSTRAINT fk_rails_1df0c6ac44 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: inbox_exceptions fk_rails_38c5e693b5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_exceptions
    ADD CONSTRAINT fk_rails_38c5e693b5 FOREIGN KEY (inbox_id) REFERENCES public.inboxes(id);


--
-- Name: integration_settings fk_rails_403cbc3abb; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_settings
    ADD CONSTRAINT fk_rails_403cbc3abb FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: inbox_holidays fk_rails_4d59a722a4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inbox_holidays
    ADD CONSTRAINT fk_rails_4d59a722a4 FOREIGN KEY (inbox_id) REFERENCES public.inboxes(id);


--
-- Name: resolution_states fk_rails_50eb07eef8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.resolution_states
    ADD CONSTRAINT fk_rails_50eb07eef8 FOREIGN KEY (operational_flow_id) REFERENCES public.operational_flows(id);


--
-- Name: team_inboxes fk_rails_7f2a0b2bdc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_inboxes
    ADD CONSTRAINT fk_rails_7f2a0b2bdc FOREIGN KEY (team_id) REFERENCES public.teams(id);


--
-- Name: provider_instances fk_rails_854bec9570; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_instances
    ADD CONSTRAINT fk_rails_854bec9570 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- Name: active_storage_variant_records fk_rails_993965df05; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_variant_records
    ADD CONSTRAINT fk_rails_993965df05 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: inboxes fk_rails_a1f654bf2d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inboxes
    ADD CONSTRAINT fk_rails_a1f654bf2d FOREIGN KEY (portal_id) REFERENCES public.portals(id);


--
-- Name: operational_flow_reasons fk_rails_b5440aaf33; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_flow_reasons
    ADD CONSTRAINT fk_rails_b5440aaf33 FOREIGN KEY (operational_flow_id) REFERENCES public.operational_flows(id);


--
-- Name: conversation_result_events fk_rails_bad36e204f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_result_events
    ADD CONSTRAINT fk_rails_bad36e204f FOREIGN KEY (conversation_id) REFERENCES public.conversations(id);


--
-- Name: meta_conversion_events fk_rails_bdf03069c7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meta_conversion_events
    ADD CONSTRAINT fk_rails_bdf03069c7 FOREIGN KEY (conversation_id) REFERENCES public.conversations(id);


--
-- Name: active_storage_attachments fk_rails_c3b3935057; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.active_storage_attachments
    ADD CONSTRAINT fk_rails_c3b3935057 FOREIGN KEY (blob_id) REFERENCES public.active_storage_blobs(id);


--
-- Name: agent_schedules fk_rails_c5b4ced45e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agent_schedules
    ADD CONSTRAINT fk_rails_c5b4ced45e FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: closing_requirements fk_rails_d02c128f41; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.closing_requirements
    ADD CONSTRAINT fk_rails_d02c128f41 FOREIGN KEY (operational_flow_id) REFERENCES public.operational_flows(id);


--
-- Name: team_inboxes fk_rails_d4c6a1cf0e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_inboxes
    ADD CONSTRAINT fk_rails_d4c6a1cf0e FOREIGN KEY (inbox_id) REFERENCES public.inboxes(id);


--
-- Name: meta_conversion_events fk_rails_e181862f01; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meta_conversion_events
    ADD CONSTRAINT fk_rails_e181862f01 FOREIGN KEY (account_id) REFERENCES public.accounts(id);


--
-- PostgreSQL database dump complete
--

\unrestrict 9dhfWf7YRuBXEDAKE0g31EKQsqVoCpUZwQFYveXhGzem0oF3FRbwfj8JAVKE0CY

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260630120000'),
('20260627130000'),
('20260627120000'),
('20260626140000'),
('20260626120000'),
('20260625120000'),
('20260624120000'),
('20260623130000'),
('20260623120000'),
('20260622150000'),
('20260622140000'),
('20260622130200'),
('20260622130100'),
('20260622130000'),
('20260622120000'),
('20260620130000'),
('20260620120000'),
('20260620100000'),
('20260619170000'),
('20260619160000'),
('20260619150000'),
('20260619140000'),
('20260619130000'),
('20260618120000'),
('20260611000002'),
('20260611000001'),
('20260607000002'),
('20260607000001'),
('20260606000016'),
('20260606000015'),
('20260606000014'),
('20260606000013'),
('20260606000012'),
('20260606000011'),
('20260606000010'),
('20260606000007'),
('20260606000006'),
('20260606000005'),
('20260606000004'),
('20260606000003'),
('20260606000002'),
('20260606000001'),
('20260605240000'),
('20260605230000'),
('20260605220000'),
('20260605210000'),
('20260605200000'),
('20260605100002'),
('20260605100001'),
('20260605100000'),
('20260604210000'),
('20260604200000'),
('20260604120001'),
('20260604120000'),
('20260603200000'),
('20260603100000'),
('20260602120000'),
('20260410092753'),
('20260410092752'),
('20260410092751'),
('20260409091202'),
('20260408170902'),
('20260324102005'),
('20260324070835'),
('20260324070828'),
('20260324070820'),
('20260320074636'),
('20260226153427'),
('20260226084618'),
('20260218075101'),
('20260211145813'),
('20260130061021'),
('20260120121402'),
('20260114201315'),
('20260114192518'),
('20260112092041'),
('20251229081141'),
('20251209225603'),
('20251119161025'),
('20251114173609'),
('20251111094402'),
('20251027091242'),
('20251022162159'),
('20251022152158'),
('20251021082242'),
('20251010143218'),
('20251003091242'),
('20250929132305'),
('20250929105219'),
('20250917012759'),
('20250916024703'),
('20250826000000'),
('20250825070005'),
('20250822061042'),
('20250820130619'),
('20250808123008'),
('20250806140005'),
('20250806140004'),
('20250806140003'),
('20250806140002'),
('20250806140001'),
('20250806140000'),
('20250805160307'),
('20250805082345'),
('20250722152516'),
('20250722083820'),
('20250714104358'),
('20250710145708'),
('20250709102213'),
('20250627195529'),
('20250620120000'),
('20250523031839'),
('20250523024826'),
('20250523024825'),
('20250514045638'),
('20250512231037'),
('20250512231036'),
('20250421085134'),
('20250421082927'),
('20250416182131'),
('20250410061725'),
('20250402233933'),
('20250326034635'),
('20250315202035'),
('20250228185548'),
('20250207040150'),
('20250116061033'),
('20250116000103'),
('20250108211541'),
('20250108031358'),
('20250107030743'),
('20250105005821'),
('20250105001414'),
('20250104210328'),
('20250104200055'),
('20241217041352'),
('20240923215335'),
('20240726220747'),
('20240516003531'),
('20240515201632'),
('20240415210313'),
('20240322071629'),
('20240319062553'),
('20240306201954'),
('20240216055809'),
('20240215065844'),
('20240213131252'),
('20240207103014'),
('20240131040316'),
('20240129080827'),
('20240124084032'),
('20240124054340'),
('20231223040257'),
('20231223033019'),
('20231219073832'),
('20231219000743'),
('20231211010807'),
('20231201014644'),
('20231129091149'),
('20231114111614'),
('20231013072802'),
('20231011041615'),
('20230905060223'),
('20230801180936'),
('20230727065605'),
('20230714054138'),
('20230706090122'),
('20230620212340'),
('20230620132319'),
('20230614044633'),
('20230612103936'),
('20230608040738'),
('20230525085402'),
('20230523104139'),
('20230515051424'),
('20230510113208'),
('20230510060828'),
('20230509101256'),
('20230503101201'),
('20230426130150');

